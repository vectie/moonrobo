///|
fn test_design(authority? : String = "digital-only") -> Json {
  {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "test-rover",
    "revision": "r1",
    "mission": { "name": "Test Rover", "authority": authority },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": 0.1 } },
  }
}

///|
test "design builder creates a simulation-only four-wheel profile" {
  guard profile_from_design(test_design()) is Ok(profile) else {
    fail("expected valid profile")
  }
  assert_true(profile.kind is MobileBase)
  assert_true(profile.bridge.kind is Sim)
  assert_eq(profile.joints.length(), 4)
  assert_eq(profile.limits.high_control_max_x_abs, 0.1)
  assert_eq(profile.limits.default_mode, "simulation-only")
  assert_true(rover_urdf(profile.id).contains("rear_right_wheel_joint"))
}

///|
test "design builder rejects physical authority and wrong contracts" {
  guard profile_from_design(test_design(authority="physical")) is Err(issue) else {
    fail("expected physical authority rejection")
  }
  assert_eq(issue.code, "unsafe-authority")
  let wrong : Json = {
    "contract_id": "other.v1",
    "design_id": "test-rover",
    "revision": "r1",
    "mission": { "authority": "digital-only" },
    "constraints": { "commanded_speed_mps": { "max": 0.1 } },
  }
  guard profile_from_design(wrong) is Err(contract_issue) else {
    fail("expected contract rejection")
  }
  assert_eq(contract_issue.code, "unsupported-contract")
}

///|
test "design builder persists and validates a fresh RoboBook" {
  let root = "/tmp/moonrobo-design-builder-validation"
  let design = test_design()
  guard build_robobook(design.stringify(), "/tmp/design.json", root) is Ok(_) else {
    fail("expected build success")
  }
  guard validate_robobook(root) is Ok(result) else {
    fail("expected validation success")
  }
  let text = result.stringify()
  assert_true(text.contains("\"accepted\":true"))
  assert_true(text.contains("\"bridge_kind\":\"Sim\""))
  assert_true(text.contains("\"joint_count\":4"))
  assert_true(text.contains("\"profile_matches_design\":true"))
  assert_true(@fsx.path_exists(root + "/design/validation-receipt.json"))
}
