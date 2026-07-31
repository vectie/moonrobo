///|
fn test_design() -> Json {
  {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "adapter-test-rover",
    "revision": "r1",
    "mission": {
      "name": "Adapter Test Rover",
      "authority": "digital-only",
      "robot_class": "inspection-rover",
    },
    "task_loop": ["depart", "inspect", "record", "return"],
    "mechanisms": [
      { "id": "mobility", "kind": "wheeled" },
      { "id": "camera", "kind": "inspection" },
      { "id": "mast", "kind": "positioning" },
    ],
    "validation": {
      "scenarios": [
        { "id": "nominal", "expected": "inspection completes" },
        { "id": "hazard", "expected": "motion stops" },
        { "id": "low-power", "expected": "robot returns" },
      ],
    },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": 0.1 } },
  }
}

///|
fn ensure_test_dir(path : String) -> Unit {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn integration_request(
  attempt_id : String,
) -> @suite_adapter.MoonflowAdapterRequest {
  {
    request_id: "request-\{attempt_id}",
    run_id: "run-adapter-test",
    book_id: "adapter-test-rover",
    work_item_id: "work-\{attempt_id}",
    declaration_id: "declaration-integrate",
    attempt_id,
    idempotency_key: "run-adapter-test/\{attempt_id}/sha256:design",
    product_id: "moonrobo",
    operation: "robot.integrate-digital-model",
    requested_authority: "workspace-mutation",
    acceptance_criteria: ["digital model validates independently"],
    input_contracts: ["moonsuite.robot-design.v1"],
    output_contracts: ["moonrobo.digital-model-integration-receipt.v1"],
    required_claim: "digital-artifact",
    input_digest: "sha256:design",
    input_artifacts: ["inputs/robot-design.json"],
    timeout_ms: 5000,
    created_at: "2026-07-31T00:00:00Z",
  }
}

///|
fn readiness_request(
  attempt_id : String,
) -> @suite_adapter.MoonflowAdapterRequest {
  {
    request_id: "request-\{attempt_id}",
    run_id: "run-adapter-test",
    book_id: "adapter-test-rover",
    work_item_id: "work-\{attempt_id}",
    declaration_id: "declaration-readiness",
    attempt_id,
    idempotency_key: "run-adapter-test/\{attempt_id}/sha256:ref",
    product_id: "moonrobo",
    operation: "robot.readiness.inspect",
    requested_authority: "observe",
    acceptance_criteria: ["record readiness without claiming readiness"],
    input_contracts: ["moonrobo.robobook-ref.v1"],
    output_contracts: ["moonrobo.readiness-observation.v1"],
    required_claim: "observation",
    input_digest: "sha256:ref",
    input_artifacts: ["inputs/robobook-ref.json"],
    timeout_ms: 5000,
    created_at: "2026-07-31T00:01:00Z",
  }
}

///|
test "adapter integrates a digital model idempotently and inspects readiness" {
  let workspace = "/tmp/moonrobo-pack-adapter-integration-v1"
  ensure_test_dir(workspace)
  ensure_test_dir(workspace + "/inputs")
  ensure_test_dir(workspace + "/books")
  @fsx.write_string_to_file(
    workspace + "/inputs/robot-design.json",
    test_design().stringify(indent=2),
  ) catch {
    _ => fail("failed to write adapter design input")
  }
  let robobook_ref : Json = {
    "contract_id": "moonrobo.robobook-ref.v1",
    "robobook_ref": "books/adapter-test-rover",
  }
  @fsx.write_string_to_file(
    workspace + "/inputs/robobook-ref.json",
    robobook_ref.stringify(indent=2),
  ) catch {
    _ => fail("failed to write RoboBook ref")
  }
  let request = integration_request("attempt-integrate-v1")
  guard @adapter_runtime.invoke(workspace, "books/adapter-test-rover", request)
    is Ok(result) else {
    fail("expected digital-model integration")
  }
  assert_eq(result.status, "succeeded")
  assert_true(
    result.output_artifacts.contains(
      "books/adapter-test-rover/design/validation-receipt.json",
    ),
  )
  assert_true(
    @fsx.path_exists(workspace + "/books/adapter-test-rover/model/robot.urdf"),
  )
  guard @adapter_runtime.invoke(workspace, "books/adapter-test-rover", request)
    is Ok(repeated) else {
    fail("expected idempotent result replay")
  }
  assert_eq(repeated, result)
  guard @adapter_runtime.invoke(
      workspace,
      "books/adapter-test-rover",
      readiness_request("attempt-readiness-v1"),
    )
    is Ok(readiness_result) else {
    fail("expected readiness observation")
  }
  assert_eq(readiness_result.status, "succeeded")
  let receipt_path = workspace +
    "/.moonsuite/products/moonrobo/adapter-attempts/attempt-readiness-v1/operation-receipt.json"
  let receipt_json = @json.parse(@fsx.read_file_to_string(receipt_path))
  let receipt : @suite_adapter.AdapterOperationReceipt = @json.from_json(
    receipt_json,
  )
  assert_false(receipt.physical_execution_performed)
  assert_eq(receipt.output_contract, "moonrobo.readiness-observation.v1")
}

///|
test "adapter reconciliation distinguishes not-applied from partial unknown" {
  let workspace = "/tmp/moonrobo-pack-adapter-reconciliation-v1"
  ensure_test_dir(workspace)
  ensure_test_dir(workspace + "/inputs")
  ensure_test_dir(workspace + "/books")
  @fsx.write_string_to_file(
    workspace + "/inputs/robot-design.json",
    test_design().stringify(indent=2),
  ) catch {
    _ => fail("failed to write reconciliation design input")
  }
  let not_applied_request = integration_request("attempt-not-applied-v1")
  let not_applied = match
    @adapter_runtime.reconcile(
      workspace, "books/not-applied", not_applied_request,
    ) {
    Ok(value) => value
    Err(error) =>
      fail(
        "expected not-applied reconciliation: \{error.code} at \{error.path}: \{error.message}",
      )
  }
  match not_applied.decision {
    "not-applied" => assert_true(not_applied.retry_allowed)
    "terminal-recorded" => assert_false(not_applied.retry_allowed)
    decision =>
      fail("unexpected not-applied reconciliation decision: \{decision}")
  }
  assert_eq(not_applied.result.status, "failed")
  ensure_test_dir(workspace + "/books/partial")
  @fsx.write_string_to_file(workspace + "/books/partial/robot.json", "{}") catch {
    _ => fail("failed to write partial artifact")
  }
  let partial_request = integration_request("attempt-partial-v1")
  guard @adapter_runtime.reconcile(workspace, "books/partial", partial_request)
    is Ok(partial) else {
    fail("expected partial reconciliation result")
  }
  assert_eq(partial.decision, "unknown")
  assert_false(partial.retry_allowed)
  assert_eq(partial.result.status, "unknown")
}

///|
test "adapter emits version-bound health and source bundle evidence" {
  let workspace = "/tmp/moonrobo-pack-adapter-health-v1"
  ensure_test_dir(workspace)
  ensure_test_dir(workspace + "/inputs")
  ensure_test_dir(workspace + "/books")
  @fsx.write_string_to_file(
    workspace + "/inputs/robot-design.json",
    test_design().stringify(indent=2),
  ) catch {
    _ => fail("failed to write health design input")
  }
  guard @adapter_runtime.invoke(
      workspace,
      "books/adapter-test-rover",
      integration_request("attempt-health-integrate-v1"),
    )
    is Ok(_) else {
    fail("expected health fixture integration")
  }
  guard @adapter_runtime.health_attestation(
      workspace, "books/adapter-test-rover", "2026-07-31T00:02:00Z", "2026-08-01T00:02:00Z",
    )
    is Ok(health) else {
    fail("expected adapter health attestation")
  }
  assert_eq(health.contract_id, "moonflow.adapter-health.v1")
  assert_eq(health.protocol, "moonflow.adapter.v2")
  assert_true(
    health.operation_refs.contains(
      "moonrobo/robot.integrate-digital-model@0.2.0",
    ),
  )
  assert_true(health.evidence_digest.has_prefix("sha256:"))
  assert_true(@fsx.path_exists(workspace + "/" + health.evidence_ref))
}
