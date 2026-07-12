///|
async test "MoonRobo owns build and validation final artifacts" {
  let workspace = "/tmp/moonrobo-flow-attestor-test"
  let build_request_ref = "runtime/build-request.json"
  let build_result_ref = "runtime/build-result.json"
  let build_draft_ref = "drafts/build.json"
  let build_final_ref = "outputs/build.json"
  write_json(scoped_path(workspace, build_request_ref), {
    "request_id": "request-build",
    "run_id": "native-product-run",
    "work_item_id": "work-build",
    "operation": "build-digital-robot",
    "created_at": "2026-07-12T10:00:00Z",
    "input_artifacts": [],
  })
  write_json(scoped_path(workspace, build_result_ref), {
    "result_id": "result-build",
    "output_digest": "sha256:draft-build",
  })
  write_json(scoped_path(workspace, build_draft_ref), {
    "contract_id": "moonrobo.digital-design.v1",
    "product_id": "moonrobo",
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
        { "id": "tether-fault", "expected": "safe hold" },
        { "id": "low-light", "expected": "limits reported" },
      ],
    },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": 0.05 } },
  })
  attest(
    workspace, build_request_ref, build_result_ref, "runtime/build-attestation.json",
    "moonrobo-native-attestor-v1", build_draft_ref, build_final_ref,
  )
  let built = read_json(scoped_path(workspace, build_final_ref))
  guard built is Object(built_fields) else { fail("expected final design") }
  assert_eq(
    built_fields.get("contract_id"),
    Some(Json::string("moonrobo.digital-design.v1")),
  )
  let robobook_ref = string_field(built_fields, "robobook_root")
  assert_true(@fsx.exists(scoped_path(workspace, robobook_ref) + "/robot.json"))

  let validate_request_ref = "runtime/validate-request.json"
  let validate_result_ref = "runtime/validate-result.json"
  let validate_draft_ref = "drafts/validate.json"
  let validate_final_ref = "outputs/validate.json"
  write_json(scoped_path(workspace, validate_request_ref), {
    "request_id": "request-validate",
    "run_id": "native-product-run",
    "work_item_id": "work-validate",
    "operation": "validate-requirements",
    "created_at": "2026-07-12T10:01:00Z",
    "input_artifacts": [build_final_ref],
  })
  write_json(scoped_path(workspace, validate_result_ref), {
    "result_id": "result-validate",
    "output_digest": "sha256:draft-validate",
  })
  write_json(scoped_path(workspace, validate_draft_ref), {
    "contract_id": "moonrobo.validation-evidence.v1",
    "product_id": "moonrobo",
    "constraint_results": [{ "id": "speed", "status": "satisfied" }],
    "negative_cases": [{ "id": "tether-fault", "status": "safe-hold" }],
    "failure_traces": [{ "id": "low-light", "visible": true }],
  })
  attest(
    workspace, validate_request_ref, validate_result_ref, "runtime/validate-attestation.json",
    "moonrobo-native-attestor-v1", validate_draft_ref, validate_final_ref,
  )
  let validated = read_json(scoped_path(workspace, validate_final_ref))
  guard validated is Object(validated_fields) else {
    fail("expected final validation")
  }
  assert_eq(
    validated_fields.get("physical_readiness"),
    Some(Json::boolean(false)),
  )
  assert_true(validated.stringify().contains("\"robobook_ready\":true"))
}
