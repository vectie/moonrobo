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
        {
          "id": "nominal",
          "kind": "nominal",
          "expected": "requested motion remains enabled",
          "initial_state": {
            "localization_fresh": true,
            "constraints_satisfied": true,
            "requested_speed_mps": 0.04,
            "stopped_speed_mps": 0.0,
          },
          "steps": [
            {
              "step_id": "authorize-motion",
              "operation": "boolean_and",
              "inputs": [
                { "state": "localization_fresh" },
                { "state": "constraints_satisfied" },
              ],
              "output": "motion_allowed",
              "expected": true,
            },
            {
              "step_id": "issue-command",
              "operation": "select",
              "inputs": [
                { "state": "motion_allowed" },
                { "state": "requested_speed_mps" },
                { "state": "stopped_speed_mps" },
              ],
              "output": "commanded_speed_mps",
              "expected": 0.04,
            },
          ],
        },
        {
          "id": "tether-fault",
          "kind": "negative",
          "expected": "motion is inhibited",
          "initial_state": {
            "localization_fresh": true,
            "constraints_satisfied": false,
            "requested_speed_mps": 0.04,
            "stopped_speed_mps": 0.0,
          },
          "steps": [
            {
              "step_id": "deny-motion",
              "operation": "boolean_and",
              "inputs": [
                { "state": "localization_fresh" },
                { "state": "constraints_satisfied" },
              ],
              "output": "motion_allowed",
              "expected": false,
            },
            {
              "step_id": "issue-stop",
              "operation": "select",
              "inputs": [
                { "state": "motion_allowed" },
                { "state": "requested_speed_mps" },
                { "state": "stopped_speed_mps" },
              ],
              "output": "commanded_speed_mps",
              "expected": 0.0,
            },
          ],
        },
        {
          "id": "low-light",
          "kind": "degraded",
          "expected": "stale localization inhibits traverse",
          "initial_state": {
            "localization_fresh": false,
            "constraints_satisfied": true,
          },
          "steps": [
            {
              "step_id": "inhibit-traverse",
              "operation": "boolean_and",
              "inputs": [
                { "state": "localization_fresh" },
                { "state": "constraints_satisfied" },
              ],
              "output": "motion_allowed",
              "expected": false,
            },
          ],
        },
      ],
    },
    "requirement_traceability": [
      {
        "requirement_id": "req-inspect",
        "requirement": "Inspect the bounded digital site.",
        "components": ["crawler", "spectrometer"],
        "verification": ["nominal"],
      },
    ],
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
  assert_true(built.stringify().contains("req-inspect"))

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
  assert_true(
    validated
    .stringify()
    .contains("\"contract_id\":\"moonrobo.scenario-execution.v1\""),
  )
  assert_true(validated.stringify().contains("\"commanded_speed_mps\":0"))
}
