///|
priv struct SuiteCase {
  case_id : String
  folder : String
  manifest_sha256 : String
  capture : String?
  variant : String?
} derive(FromJson)

///|
priv struct Suite {
  format : String
  source_root : String
  oracle_library : String
  cases : Array[SuiteCase]
} derive(FromJson)

///|
async fn required_case(id : String) -> Unit {
  let suite_folder = @env.get_env_var("MOONROBO_SMC_DIFF_FIXTURES").unwrap_or(
    "",
  )
  guard !suite_folder.is_empty() else {
    fail(
      "differential execution remains deferred: set MOONROBO_SMC_DIFF_FIXTURES to real source-bound exported fixtures; no fixture is fabricated or skipped",
    )
  }
  let suite : Suite = @json.from_json(
    @artifacts.load_json(suite_folder + "/suite.json"),
  )
  guard suite.format == "moonrobo.smc-differential.suite.v1" else {
    fail("unknown differential fixture suite")
  }
  let cases = suite.cases.filter(c => c.case_id == id)
  guard cases.length() == (if id == "data.real_clips" { 3 } else { 1 }) else {
    fail("missing/duplicate original method fixture cases: " + id)
  }
  if id == "data.real_clips" {
    for name in ["dance1_subject1", "fallAndGetUp3_subject1", "walk4_subject1"] {
      guard cases.filter(c => c.variant == Some(name)).length() == 1 else {
        fail("original acquired-clip subtest missing: " + name)
      }
    }
  }
  for case in cases {
    let folder = path(suite_folder, case.folder)
    let fixture = load_fixture(folder, suite.source_root, case.manifest_sha256)
    guard fixture.manifest.case_id == id else {
      fail("suite case points to another method")
    }
    let actual_upstream = [
      "data.real_clips", "data.reset_mixture", "data.terminal_fix", "mdp.heads",
      "mdp.observation_modes", "mdp.fk", "mdp.quaternion", "mdp.rotation_fixes",
      "learning.architecture", "learning.world8", "learning.policy32", "learning.replay",
    ].contains(id)
    if actual_upstream {
      guard fixture.manifest.oracle_kind == "executed-upstream-python" else {
        fail(
          "the original upstream differential test requires an executed preserved Python oracle fixture; an independent C++ translation is not substituted",
        )
      }
    }
    let temporary = @fs.tmpdir(prefix="moonrobo-source-differential-")
    match case.capture {
      Some(capture) =>
        ignore(
          verify_capture(
            folder,
            suite.source_root,
            case.manifest_sha256,
            path(suite_folder, capture),
            temporary + "/verification.json",
          ),
        )
      None =>
        ignore(
          run_fixture(
            folder,
            suite.source_root,
            case.manifest_sha256,
            suite.oracle_library,
            temporary,
          ),
        )
    }
    @fs.rmdir(temporary, recursive=true)
  }
}

///|
async test "original data resampling velocity goals and end bins" {
  required_case("data.resampling")
}

///|
async test "original data duplicate bin update order and exact checkpoint" {
  required_case("data.duplicates")
}

///|
async test "original data timeout bootstrap and terminal" {
  required_case("data.bootstrap")
}

///|
async test "original data manifest source SHA and split identity" {
  required_case("data.manifest")
}

///|
async test "original data reference-only export does not invoke FK" {
  required_case("data.reference_only")
}

///|
async test "original acquired 40 sources frozen catalog" {
  required_case("data.catalog40")
}

///|
async test "original three acquired clips versus executed smc" {
  required_case("data.real_clips")
}

///|
async test "original reset mixture and updates versus executed smc" {
  required_case("data.reset_mixture")
}

///|
async test "original terminal-only-bin documented upstream bug" {
  required_case("data.terminal_fix")
}

///|
async test "original MDP heads and pullbacks versus executed smc" {
  required_case("mdp.heads")
}

///|
async test "original observation mode exact upstream prefix" {
  required_case("mdp.observation_modes")
}

///|
async test "original all tracked FK versus executed smc" {
  required_case("mdp.fk")
}

///|
async test "original quaternion values and pullback versus executed smc" {
  required_case("mdp.quaternion")
}

///|
async test "original rotation floor and vertical-collapse bug fixes" {
  required_case("mdp.rotation_fixes")
}

///|
async test "original default architecture versus executed smc" {
  required_case("learning.architecture")
}

///|
async test "original networks and eight-step Adam versus executed smc" {
  required_case("learning.world8")
}

///|
async test "original 32-step actor and GAE critic versus executed smc" {
  required_case("learning.policy32")
}

///|
async test "original replay windows histories and ring restore versus executed smc" {
  required_case("learning.replay")
}

///|
async test "original Isaac pinned solver protocol" {
  required_case("isaac.solver")
}

///|
async test "original Isaac joint order before state access" {
  required_case("isaac.joint_order")
}

///|
async test "original Isaac missing optional runtime" {
  required_case("isaac.missing")
}

///|
async test "original Isaac pre-reset transition and timeout" {
  required_case("isaac.transition")
}

///|
async test "original Isaac evaluation view and replica accounting" {
  required_case("isaac.evaluation")
}

///|
async test "original Isaac warm resume refill and collision identity" {
  required_case("isaac.resume")
}

///|
async test "original Isaac context COM friction and offset resampling" {
  required_case("isaac.context")
}

///|
async test "original Isaac raw evaluation action" {
  required_case("isaac.raw_action")
}

///|
async test "original Isaac episode context indexed reset" {
  required_case("isaac.episode_context")
}

///|
test "fixture tensors reject narrowing overflow fractions and false dtype labels" {
  tensor_valid("rng.calls", array([1, 3], [2.0, 64.0, 0.0], dtype="<i8"))
  for
    invalid in [
      array([1], [-1.0], dtype="|u1"),
      array([1], [256.0], dtype="|u1"),
      array([1], [0.5], dtype="<i4"),
      array([1], [2147483648.0], dtype="<i4"),
      array([1], [2.0], dtype="|b1"),
      array([1], [9007199254740992.0], dtype="<i8"),
      array([1], [0.1], dtype="<f4"),
    ] {
    assert_true((try? tensor_valid("fixed", invalid)) is Err(_))
  }
}

///|
test "native oracle cannot inherit missing input tensors from the previous evaluation" {
  let library = @env.get_env_var("MOONROBO_SMC_DIFF_ADAPTER").unwrap_or("")
  guard !library.is_empty() else {
    fail(
      "deferred native oracle regression requires a real MOONROBO_SMC_DIFF_ADAPTER",
    )
  }
  let oracle = Oracle::open(library)
  let input : Map[String, @artifacts.NumericArray] = {
    "inputs.vectors": array([1, 3], [0.4, -0.3, 0.8]),
    "inputs.quaternion_weights": array([4], [0.13, -0.27, 0.8, -0.51]),
  }
  ignore(oracle.evaluate("quaternion", input))
  let incomplete : Map[String, @artifacts.NumericArray] = {}
  assert_true((try? oracle.evaluate("quaternion", incomplete)) is Err(_))
}

///|
test "original thresholds remain exact for weights and restore original allclose for Isaac" {
  assert_eq(
    tolerance("learning.world8", "weights_after.wm.net.0.weight"),
    (0.0, 0.0),
  )
  assert_eq(
    tolerance("learning.policy32", "optimizer_after.pi.enc.0.weight.exp_avg"),
    (0.0, 0.0),
  )
  assert_eq(tolerance("isaac.transition", "target"), (1.0e-8, 1.0e-5))
  assert_eq(tolerance("isaac.transition", "out.xi"), (1.0e-8, 1.0e-5))
  assert_eq(tolerance("isaac.raw_action", "target"), (1.0e-8, 1.0e-5))
}
