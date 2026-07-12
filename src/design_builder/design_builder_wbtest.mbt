///|
fn test_design(authority? : String = "digital-only") -> Json {
  {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "test-rover",
    "revision": "r1",
    "mission": {
      "name": "Test Rover",
      "authority": authority,
      "robot_class": "excavation-haul-rover",
    },
    "task_loop": ["dig", "load", "haul", "dump"],
    "mechanisms": [
      { "id": "excavator", "kind": "scoop" },
      { "id": "payload-bed", "kind": "tipping-bed" },
      { "id": "mobility", "kind": "wheeled" },
    ],
    "validation": {
      "scenarios": [
        { "id": "nominal-cycle", "expected": "delivery succeeds" },
        { "id": "hazard-stop", "expected": "motion stops" },
        { "id": "low-energy-return", "expected": "reserve is preserved" },
      ],
    },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": 0.1 } },
  }
}

///|
test "design builder derives a simulation-only profile from mechanisms" {
  guard profile_from_design(test_design()) is Ok(profile) else {
    fail("expected valid profile")
  }
  assert_true(profile.kind is MobileBase)
  assert_true(profile.bridge.kind is Sim)
  assert_eq(profile.joints.length(), 3)
  assert_eq(profile.limits.high_control_max_x_abs, 0.1)
  assert_eq(profile.limits.default_mode, "simulation-only")
  let urdf = system_urdf(profile.id, profile.joints.map(joint => joint.name))
  assert_true(urdf.contains("excavator_joint"))
  assert_true(urdf.contains("payload-bed_joint"))
  assert_true(urdf.contains("mobility_joint"))
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
  guard build_robobook(
      design.stringify(),
      "/tmp/design.json",
      root,
      "2026-07-11T03:00:00Z",
      source_artifact_ref="outputs/moontown/robot-design.json",
    )
    is Ok(_) else {
    fail("expected build success")
  }
  guard validate_robobook(root, "2026-07-11T03:01:00Z") is Ok(result) else {
    fail("expected validation success")
  }
  let text = result.stringify()
  assert_true(text.contains("\"accepted\":true"))
  assert_true(text.contains("\"bridge_kind\":\"Sim\""))
  assert_true(text.contains("\"joint_count\":3"))
  assert_true(text.contains("\"profile_matches_design\":true"))
  assert_true(text.contains("\"validation_scenarios\":3"))
  assert_true(text.contains("\"mission_semantics_preserved\":true"))
  assert_true(@fsx.path_exists(root + "/design/validation-receipt.json"))
  let build_receipt = @fsx.read_file_to_string(
    root + "/design/build-receipt.json",
  )
  assert_true(build_receipt.contains("2026-07-11T03:00:00Z"))
  assert_false(build_receipt.contains("\"started_at\": \"r1\""))
  let validation_receipt = @fsx.read_file_to_string(
    root + "/design/validation-receipt.json",
  )
  assert_true(validation_receipt.contains("2026-07-11T03:01:00Z"))
}

///|
test "design builder does not substitute an excavation rover for another concept" {
  let design : Json = {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "polar-inspector",
    "revision": "r1",
    "mission": {
      "name": "Polar Inspector",
      "authority": "digital-only",
      "robot_class": "tethered-polar-inspector",
    },
    "task_loop": ["descend", "inspect", "sample", "return"],
    "mechanisms": [
      { "id": "tether", "kind": "power-and-data" },
      { "id": "crawler", "kind": "tracked-mobility" },
      { "id": "spectrometer", "kind": "science-payload" },
    ],
    "validation": {
      "scenarios": [
        { "id": "nominal", "expected": "inspection completes" },
        { "id": "tether-fault", "expected": "robot enters safe hold" },
        { "id": "low-light", "expected": "limits are reported" },
      ],
    },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": 0.05 } },
  }
  guard profile_from_design(design) is Ok(profile) else {
    fail("expected a non-excavation concept to compile")
  }
  assert_true(
    profile.joints.map(joint => joint.name) ==
    ["tether_joint", "crawler_joint", "spectrometer_joint"],
  )
  let urdf = system_urdf(profile.id, profile.joints.map(joint => joint.name))
  assert_true(urdf.contains("spectrometer_joint"))
  assert_false(urdf.contains("excavator"))
}

///|
test "design builder rejects designs without testable mission semantics" {
  let incomplete : Json = {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "empty-rover",
    "revision": "r1",
    "mission": {
      "name": "Empty Rover",
      "authority": "digital-only",
      "robot_class": "excavation-haul-rover",
    },
    "constraints": { "commanded_speed_mps": { "max": 0.1 } },
  }
  guard profile_from_design(incomplete) is Err(issue) else {
    fail("expected missing mission evidence rejection")
  }
  assert_eq(issue.code, "missing-design-evidence")
  assert_eq(issue.field, "task_loop")
}

///|
test "design builder rejects non-temporal receipt provenance" {
  let design = test_design()
  guard build_robobook(
      design.stringify(),
      "/tmp/design.json",
      "/tmp/moonrobo-invalid-provenance",
      "r1",
      source_artifact_ref="outputs/design.json",
    )
    is Err(issue) else {
    fail("expected invalid timestamp rejection")
  }
  assert_eq(issue.code, "invalid-recorded-at")
}
