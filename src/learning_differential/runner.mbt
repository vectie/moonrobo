///|
pub(all) struct CandidateManifest {
  format : String
  fixture_sha256 : String
  input_sha256 : String
  candidate_sources : Map[String, FileIdentity]
  output : FileIdentity
  implementation_backend : String
} derive(ToJson, FromJson, Debug)

///|
fn merge(
  output : Map[String, @artifacts.NumericArray],
  other : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  for name, value in other {
    guard !output.contains(name) else {
      fail("duplicate differential output key " + name)
    }
    output[name] = value
  }
}

///|
fn native_operation(id : String) -> String raise {
  match id {
    "data.real_clips" => "motion"
    "data.reset_mixture" => "reset_sampling"
    "data.terminal_fix" => "terminal_fix"
    "data.catalog40" => "catalog40"
    "mdp.heads" => "mdp_heads"
    "mdp.observation_modes" => "observation_modes"
    "mdp.fk" => "fk"
    "mdp.quaternion" => "quaternion"
    "mdp.rotation_fixes" => "rotation_fixes"
    "learning.architecture" => "architecture"
    "learning.world8" => "world8"
    "learning.policy32" => "policy_update"
    "learning.replay" => "replay"
    _ =>
      fail(
        "this original CPU/Isaac protocol method uses its translated package tests or a source-bound external capture; it has no implicit simulator/oracle fallback",
      )
  }
}

///|
pub fn contract_inventory() -> Json {
  contracts()
  .map(item => {
    (
      {
        "case_id": item.id,
        "original_method": item.original_method,
        "required_outputs": item.required,
        "native_fixed_runner": try {
          ignore(native_operation(item.id))
          true
        } catch {
          _ => false
        },
        "execution_status": "not-run",
        "upstream_fixture_status": "not-generated",
      } : Json)
  })
  .to_json()
}

///|
fn checked_rng(
  input : Map[String, @artifacts.NumericArray],
  oracle : Oracle,
  id : String,
) -> @artifacts.NumericArray raise {
  let before = get(input, "rng.before")
  if before.values.is_empty() {
    guard !["learning.policy32", "mdp.heads", "learning.replay"].contains(id) else {
      fail(
        "stochastic original method requires actual upstream generator state and call evidence",
      )
    }
    return before
  }
  if !input.contains("rng.calls") {
    guard !["learning.policy32", "mdp.heads", "learning.replay"].contains(id) else {
      fail("upstream random call transcript missing")
    }
    return before
  }
  let result = oracle.evaluate("rng", input)
  if id == "learning.policy32" {
    guard get(input, "rng.calls").shape == [2, 3] &&
      get(input, "rng.calls").values == [2.0, 64.0, 0.0, 2.0, 64.0, 0.0] else {
      fail(
        "original policy critic shuffle call law must be two randperm(64) calls",
      )
    }
    let permutation = get(input, "inputs.critic_permutations").values
    for i in 0..<2 {
      guard permutation[i * 64:(i + 1) * 64].to_owned() ==
        result["rng.draw." + i.to_string()].values else {
        fail(
          "critic permutation differs from original ATen generator transcript",
        )
      }
    }
  } else if id == "mdp.heads" {
    let uniform = get(input, "inputs.observation_uniform")
    guard get(input, "rng.calls").shape == [1, 3] &&
      get(input, "rng.calls").values ==
      [
        if uniform.dtype == "<f8" {
          4.0
        } else {
          1.0
        },
        uniform.values.length().to_double(),
        0.0,
      ] else {
      fail("MDP rand_like call shape/dtype transcript mismatch")
    }
    guard uniform.values == result["rng.draw.0"].values else {
      fail("observation noise input is not the actual upstream generator draw")
    }
  } else if id == "learning.replay" {
    let expected = [
      0.0, 4.0, 1.0, 0.0, 4.0, 1.0, 0.0, 20.0, 8.0, 0.0, 20.0, 1.0,
    ]
    guard get(input, "rng.calls").shape == [4, 3] &&
      get(input, "rng.calls").values == expected else {
      fail("original replay randint transcript differs")
    }
    for
      (key, index) in [
        ("inputs.window_ages", 0),
        ("inputs.window_environments", 1),
        ("inputs.restore_ages", 2),
      ] {
      guard get(input, key).values ==
        result["rng.draw." + index.to_string()].values else {
        fail("fixed replay samples differ from actual upstream randint")
      }
    }
  }
  result["rng.after"]
}

///|
async fn evaluate_case(
  manifest : FixtureManifest,
  input : Map[String, @artifacts.NumericArray],
  library : String,
  source_root : String,
  oracle_mode : Bool,
) -> Map[String, @artifacts.NumericArray] {
  let operation = native_operation(manifest.case_id)
  guard manifest.oracle_adapter is Some(adapter) else {
    fail(
      "native fixed execution requires a SHA-bound oracle adapter; source-only or Python fixtures may instead use verify-capture",
    )
  }
  ignore(verify_file(source_root, adapter))
  guard @fs.realpath(library) == @fs.realpath(path(source_root, adapter.path)) else {
    fail(
      "loaded oracle shared library differs from the sealed producer artifact",
    )
  }
  let oracle = Oracle::open(library)
  guard oracle.version() == manifest.torch_version else {
    fail("oracle ATen version differs from source-bound fixture")
  }
  let after_rng = if operation == "reset_sampling" {
    None
  } else {
    Some(checked_rng(input, oracle, manifest.case_id))
  }
  let result = if operation == "architecture" {
    if oracle_mode {
      architecture_mathematical_oracle()
    } else {
      candidate_architecture()
    }
  } else if operation == "replay" {
    if oracle_mode {
      replay_mathematical_oracle(input)
    } else {
      candidate_replay(input)
    }
  } else if operation == "world8" {
    let output = if oracle_mode {
      oracle.evaluate("network", input)
    } else {
      candidate_learning("network", input)
    }
    merge(
      output,
      if oracle_mode {
        oracle.evaluate("world_update", input)
      } else {
        candidate_learning("world_update", input)
      },
    )
    output
  } else if operation == "policy_update" {
    if oracle_mode {
      oracle.evaluate(operation, input)
    } else {
      candidate_learning(operation, input)
    }
  } else if operation == "reset_sampling" {
    if oracle_mode {
      oracle.evaluate(operation, input)
    } else {
      candidate_reset_mixture(input, oracle)
    }
  } else if operation == "motion" {
    if oracle_mode {
      oracle.evaluate(operation, input)
    } else {
      candidate_motion_fields(input)
    }
  } else if operation == "catalog40" {
    let catalog : FileIdentity = @json.from_json(
      field(manifest.config, "catalog"),
    )
    let file = path(source_root, catalog.path)
    let suffix = "/motion-manifest.json"
    guard file.has_suffix(suffix) else {
      fail("catalog path must name motion-manifest.json")
    }
    let folder = file[:file.length() - suffix.length()].to_owned()
    if oracle_mode {
      catalog_mathematical_oracle(folder, catalog.sha256)
    } else {
      verify_catalog40(folder, catalog.sha256)
    }
  } else if operation == "terminal_fix" {
    terminal_bin_contract(input, oracle, oracle_mode)
  } else if oracle_mode {
    oracle.evaluate(operation, input)
  } else {
    let output = candidate_mdp(operation, input)
    if operation == "rotation_fixes" {
      let baseline = oracle.evaluate(operation, input)
      for
        name in [
          "upstream_angle_sq", "upstream_gradient", "upstream_vertical_determinant",
        ] {
        output[name] = baseline[name]
      }
    }
    output
  }
  if !result.contains("rng.after") {
    result["rng.after"] = after_rng.unwrap()
  }
  result
}

///|
pub async fn export_oracle_fixture(
  template : FixtureManifest,
  source_root : String,
  library : String,
  output_folder : String,
) -> String {
  guard ["independent-aten-cpp", "independent-mathematics"].contains(
    template.oracle_kind,
  ) else {
    fail(
      "native export cannot label a transcribed oracle as executed upstream Python",
    )
  }
  guard template.upstream_revision == "a1508d42c9d1699a52e8233ab16d08c488441ab9" else {
    fail("upstream revision is not pinned")
  }
  for _, identity in template.upstream_sources {
    ignore(verify_file(source_root, identity))
  }
  for _, identity in template.candidate_sources {
    ignore(verify_file(source_root, identity))
  }
  ignore(verify_file(source_root, template.original_test))
  ignore(verify_file(source_root, template.producer))
  let input = @artifacts.decode_npz(verify_file(source_root, template.input))
  for name, tensor in input {
    tensor_valid(name, tensor)
  }
  validate_case_inputs(template.case_id, input)
  let expected = evaluate_case(template, input, library, source_root, true)
  validate_required(template.case_id, expected)
  validate_learning_evidence(template.case_id, input, expected)
  @fs.mkdir(output_folder, recursive=true)
  guard !@fs.exists(output_folder + "/fixture.json") else {
    fail("fixture bundle is immutable; choose a fresh output folder")
  }
  let input_sha = @artifacts.save_npz(output_folder + "/input.npz", input)
  let expected_sha = @artifacts.save_npz(
    output_folder + "/expected.npz",
    expected,
  )
  let before = get(input, "rng.before")
  let after = get(expected, "rng.after")
  let manifest = {
    ..template,
    input: { path: "input.npz", sha256: input_sha, },
    expected: { path: "expected.npz", sha256: expected_sha, },
    rng_before_sha256: @artifacts.sha256(
      Bytes::from_array(before.values.map(x => x.to_int().to_byte())),
    ),
    rng_after_sha256: @artifacts.sha256(
      Bytes::from_array(after.values.map(x => x.to_int().to_byte())),
    ),
    input_keys: input.keys().collect(),
    expected_keys: expected.keys().collect(),
  }
  @artifacts.save_json(output_folder + "/fixture.json", manifest.to_json())
}

///|
pub async fn run_fixture(
  folder : String,
  source_root : String,
  fixture_sha256 : String,
  library : String,
  output_folder : String,
) -> Verification {
  let fixture = load_fixture(folder, source_root, fixture_sha256)
  let output = evaluate_case(
    fixture.manifest,
    fixture.input,
    library,
    source_root,
    false,
  )
  @fs.mkdir(output_folder, recursive=true)
  let sha = @artifacts.save_npz(output_folder + "/candidate.npz", output)
  let capture : CandidateManifest = {
    format: "moonrobo.smc-differential.candidate.v1",
    fixture_sha256,
    input_sha256: fixture.manifest.input.sha256,
    candidate_sources: fixture.manifest.candidate_sources,
    output: { path: "candidate.npz", sha256: sha, },
    implementation_backend: "moonbit-float64",
  }
  ignore(
    @artifacts.save_json(output_folder + "/capture.json", capture.to_json()),
  )
  let result = compare_fixture(fixture, output, sha)
  ignore(
    @artifacts.save_json(output_folder + "/verification.json", result.to_json()),
  )
  result
}

///|
pub async fn verify_capture(
  folder : String,
  source_root : String,
  fixture_sha256 : String,
  capture_folder : String,
  output_path : String,
) -> Verification {
  let fixture = load_fixture(folder, source_root, fixture_sha256)
  let capture : CandidateManifest = @json.from_json(
    @artifacts.load_json(capture_folder + "/capture.json"),
  )
  guard capture.format == "moonrobo.smc-differential.candidate.v1" &&
    capture.fixture_sha256 == fixture_sha256 &&
    capture.input_sha256 == fixture.manifest.input.sha256 &&
    capture.candidate_sources.to_json() ==
    fixture.manifest.candidate_sources.to_json() else {
    fail("candidate is not bound to the complete fixture/source/input identity")
  }
  guard [
    "moonbit-float64", "cpu-batch-adapter-contract-fixture", "actual-isaaclab3-newton",
  ].contains(capture.implementation_backend) else {
    fail("candidate backend must be explicit and recognized")
  }
  if !fixture.manifest.case_id.has_prefix("isaac.") {
    guard capture.implementation_backend == "moonbit-float64" else {
      fail(
        "non-Isaac contract cannot be satisfied by simulator/protocol capture",
      )
    }
  }
  for _, identity in capture.candidate_sources {
    ignore(verify_file(source_root, identity))
  }
  let actual = @artifacts.decode_npz(
    verify_file(capture_folder, capture.output),
  )
  let result = compare_fixture(fixture, actual, capture.output.sha256)
  ignore(@artifacts.save_json(output_path, result.to_json()))
  result
}
