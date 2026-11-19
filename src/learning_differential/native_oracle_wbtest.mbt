///|
// This suite exercises the scalar production backend in its declared Float64
// precision. The sealed upstream Float32 verifier and its exact tolerances are
// a separate profile; neither expected dtype nor upstream evidence is relabeled.
fn native_compare(
  label : String,
  actual : Map[String, @artifacts.NumericArray],
  expected : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  assert_eq(actual.length(), expected.length(), msg=label + " output key count")
  for name, reference in expected {
    guard actual.get(name) is Some(value) else {
      fail(label + " missing " + name)
    }
    tensor_valid(name, value)
    tensor_valid(name, reference)
    assert_eq(value.shape, reference.shape, msg=label + " " + name + " shape")
    assert_eq(value.dtype, reference.dtype, msg=label + " " + name + " dtype")
    let floating = reference.dtype == "<f8"
    for i, wanted in reference.values {
      let error = (value.values[i] - wanted).abs()
      // Double reductions/AD use different summation orders. Integer, Boolean
      // and source-identity outputs remain exact. These bounds never apply to
      // compare_fixture or to the upstream Float32 qualification profile.
      let bound = if floating { 2.0e-10 + 2.0e-9 * wanted.abs() } else { 0.0 }
      guard error <= bound else {
        fail(
          "native64 \{label} \{name}[\{i}]: actual=\{value.values[i]}, expected=\{wanted}, error=\{error}, bound=\{bound}",
        )
      }
    }
  }
}

///|
fn native_oracle() -> Oracle raise {
  guard @env.get_env_var("MOONROBO_SMC_DIFF_ADAPTER") is Some(library) else {
    fail(
      "native differential tests require the built independent ATen oracle; run scripts/test_native.mbtx with a dependency profile",
    )
  }
  Oracle::open(library)
}

///|
async fn native_contract(id : String) -> Unit {
  match id {
    "data.resampling"
    | "data.duplicates"
    | "data.bootstrap"
    | "data.manifest"
    | "data.reference_only" => native_data_contract(id)
    "isaac.solver" => protocol_solver()
    "isaac.joint_order" => protocol_joint_order()
    "isaac.transition" => protocol_transition()
    "isaac.evaluation" => protocol_evaluation()
    "isaac.resume" => protocol_resume()
    "isaac.context" => protocol_context()
    "isaac.raw_action" => protocol_raw_action()
    "isaac.episode_context" => protocol_episode_context()
    "isaac.missing" =>
      assert_true(
        (try? @gpu_native.load(
          "/nonexistent/native-test-adapter", "/nonexistent/native-test-bundle",
          "missing-asset",
        ))
        is Err(_),
      )
    "learning.architecture" =>
      native_compare(
        id,
        candidate_architecture(),
        architecture_mathematical_oracle(),
      )
    "learning.replay" => {
      let x = native_replay_input()
      native_compare(id, candidate_replay(x), replay_mathematical_oracle(x))
    }
    "learning.world8" | "learning.policy32" => {
      let x = native_learning_input()
      let oracle = native_oracle()
      if id == "learning.world8" {
        native_compare(
          "network",
          candidate_learning("network", x),
          oracle.evaluate("native64.learning.network", x),
        )
      }
      let operation = if id == "learning.world8" {
        "world_update"
      } else {
        "policy_update"
      }
      let expected = oracle.evaluate("native64.learning." + operation, x)
      validate_learning_evidence(id, x, expected)
      let actual = candidate_learning(operation, x)
      validate_learning_evidence(id, x, actual)
      native_compare(id, actual, expected)
    }
    "mdp.quaternion" => {
      let x : Map[String, @artifacts.NumericArray] = {
        "inputs.vectors": array([5, 3], [
          0.4, -0.3, 0.8, 2.8, 0.2, -0.1, 0.01, 0.03, -0.02, -0.2, 0.3, -0.5, 0.6,
          1.2, -0.7,
        ]),
        "inputs.quaternion_weights": array([4], [0.13, -0.27, 0.8, -0.51]),
      }
      native_compare(
        id,
        candidate_mdp("quaternion", x),
        native_oracle().evaluate("quaternion", x),
      )
    }
    "mdp.rotation_fixes" => {
      let x : Map[String, @artifacts.NumericArray] = Map([])
      let expected = native_oracle().evaluate("rotation_fixes", x)
      let actual = candidate_mdp("rotation_fixes", x)
      // Upstream bug measurements describe the reference, not candidate outputs.
      // Compare independently computed corrected values on the SUT side.
      let corrected = expected.copy()
      for
        key in [
          "upstream_angle_sq", "upstream_gradient", "upstream_vertical_determinant",
        ] {
        actual.remove(key)
        corrected.remove(key)
      }
      native_compare(id, actual, corrected)
      assert_true(expected["upstream_angle_sq"].values[0] > 1.0e-7)
      assert_eq(expected["upstream_vertical_determinant"].values[0], 0.0)
    }
    "mdp.heads" | "mdp.observation_modes" | "mdp.fk" => {
      let x = native_mdp_input()
      let op = if id == "mdp.heads" {
        "mdp_heads"
      } else if id == "mdp.fk" {
        "fk"
      } else {
        "observation_modes"
      }
      native_compare(
        id,
        candidate_mdp(op, x),
        native_oracle().evaluate("native64." + op, x),
      )
    }
    "data.catalog40" => {
      let folder = @env.get_env_var("MOONROBO_ALIGNED_DATA").unwrap_or(
        "target/learning/g1-aligned-data",
      )
      let sha = @artifacts.sha256(
        @fs.read_file(folder + "/motion-manifest.json").binary(),
      )
      native_compare(
        id,
        verify_catalog40(folder, sha),
        catalog_mathematical_oracle(folder, sha),
      )
    }
    "data.real_clips" => {
      let folder = @env.get_env_var("MOONROBO_ALIGNED_DATA").unwrap_or(
        "target/learning/g1-aligned-data",
      )
      for
        name in ["dance1_subject1", "fallAndGetUp3_subject1", "walk4_subject1"] {
        let raw = @aligned.parse_motion_csv(
          @fs.read_file(folder + "/lafan1_g1/" + name + ".csv").text(),
        )
        let x : Map[String, @artifacts.NumericArray] = {
          "motion.raw": array([raw.length(), 36], flatten(raw)),
          "config.source_fps": scalar(30.0),
        }
        native_compare(
          id + " " + name,
          candidate_motion_fields(x),
          native_oracle().evaluate("native64.motion", x),
        )
      }
    }
    "data.reset_mixture" | "data.terminal_fix" => native_sampling_contract(id)
    _ => fail("unimplemented native conformance case: " + id)
  }
}

///|
fn native_sampling_contract(id : String) -> Unit raise {
  let oracle = native_oracle()
  let seeded = oracle.evaluate("rng_seed", { "config.seed": scalar(22.0) })["rng.before"]
  let x : Map[String, @artifacts.NumericArray] = {
    "rng.before": seeded,
    "sampler.rng_before": seeded,
    "sampler.bin_G": array([3], [0.0, 5.0, 10.0]),
    "sampler.bin_w_avg": array([3], [1.0 / 3, 1.0 / 3, 1.0 / 3]),
    "sampler.bin_start": array([3], [0.0, 50, 100], dtype="<i8"),
    "sampler.bin_clip_end": array([3], [49.0, 99, 149], dtype="<i8"),
    "sampler.update_bins": array([2], [0.0, 2], dtype="<i8"),
    "sampler.update_returns": array([2], [3.0, 5]),
    "config.G_max": scalar(10.0),
    "config.sample_count": scalar(400.0),
    "motion.raw": array([31, 36], flatten(native_test_clips()[0].rows)),
    "config.source_fps": scalar(30.0),
  }
  if id == "data.reset_mixture" {
    native_compare(
      id,
      candidate_reset_mixture(x, oracle),
      oracle.evaluate("native64.reset_sampling", x),
    )
  } else {
    native_compare(
      id,
      terminal_bin_contract(x, oracle, false),
      terminal_bin_contract(x, oracle, true),
    )
  }
}

///|
test "native comparison rejects changed moments keys shapes and dtype" {
  let expected : Map[String, @artifacts.NumericArray] = {
    "optimizer_after.wm.parameter.exp_avg": array([2], [0.1, 0.2]),
  }
  for
    wrong in [
      array([2], [0.1, 0.20001]),
      array([1, 2], [0.1, 0.2]),
      array([2], [0.0, 0.0], dtype="<f4"),
    ] {
    assert_true(
      (try? native_compare(
        "mutation",
        { "optimizer_after.wm.parameter.exp_avg": wrong },
        expected,
      ))
      is Err(_),
    )
  }
  assert_true((try? native_compare("missing", {}, expected)) is Err(_))
  let extra = expected.copy()
  extra["unexpected"] = scalar(0.0)
  assert_true((try? native_compare("extra", extra, expected)) is Err(_))
}

///|
test "failed native64 calls cannot change preserved oracle semantics" {
  let oracle = native_oracle()
  let before = oracle.evaluate("rotation_fixes", {})
  assert_true((try? oracle.evaluate("native64.mdp_heads", {})) is Err(_))
  native_compare(
    "preserved rotation profile",
    oracle.evaluate("rotation_fixes", {}),
    before,
  )
  assert_true(before["upstream_angle_sq"].values[0] > 1.0e-7)
  let x = native_learning_input()
  let original = oracle.evaluate("world_update", x)
  let native = oracle.evaluate("native64.learning.world_update", x)
  let step = "optimizer_after.wm.net.0.weight.step"
  assert_eq(original[step].dtype, "<f4")
  assert_eq(native[step].dtype, "<f8")
  let bad = x.copy()
  bad["weights.wm.net.0.weight"] = array(
    x["weights.wm.net.0.weight"].shape,
    Array::make(x["weights.wm.net.0.weight"].values.length(), 0.0),
    dtype="<f4",
  )
  assert_true(
    (try? oracle.evaluate("native64.learning.world_update", bad)) is Err(_),
  )
  native_compare(
    "preserved learning profile",
    oracle.evaluate("world_update", x),
    original,
  )
}
