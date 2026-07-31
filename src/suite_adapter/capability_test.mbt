///|
test "MoonRobo adapter cannot claim physical readiness" {
  guard @suite_adapter.moonflow_adapter_capability_json() is Object(capability) else {
    fail("expected MoonRobo adapter capability")
  }
  assert_true(capability["protocol"] == Json::string("moonflow.adapter.v2"))
  assert_true(capability["product_id"] == Json::string("moonrobo"))
  assert_true(capability["supports_cancel"] == Json::boolean(false))
  assert_true(capability["supports_reconcile"] == Json::boolean(true))
  assert_true(capability["healthy"] == Json::boolean(true))
  assert_true(capability["claim_ceiling"] == Json::string("digital-artifact"))
  guard capability["authority_classes"] is Array(authorities) else {
    fail("expected MoonRobo authorities")
  }
  assert_true(authorities.contains(Json::string("workspace-mutation")))
  assert_false(authorities.contains(Json::string("external-effect")))
  assert_false(authorities.contains(Json::string("physical-effect")))
  guard capability["operations"] is Array(operations) else {
    fail("expected MoonRobo operations")
  }
  assert_true(
    operations.contains(Json::string("robot.integrate-digital-model")),
  )
  assert_true(
    operations.contains(Json::string("robot.command.submit-governed")),
  )
}

///|
test "MoonRobo declaration binds manifest operations to adapter v2" {
  let declaration = @suite_adapter.adapter_declaration_json()
  guard declaration
    is {
      "contract_id": String(contract_id),
      "adapter_id": String(adapter_id),
      "pack_version": String(pack_version),
      "protocol": String(protocol),
      "operations": Array(operations),
      ..
    } else {
    fail("expected adapter declaration")
  }
  assert_eq(contract_id, "moonflow.adapter-declaration.v1")
  assert_eq(adapter_id, "moonrobo-local-v1")
  assert_eq(pack_version, "0.2.0")
  assert_eq(protocol, "moonflow.adapter.v2")
  assert_eq(operations.length(), 3)
  assert_true(
    @suite_adapter.operation_refs().contains(
      "moonrobo/robot.integrate-digital-model@0.2.0",
    ),
  )
}

///|
test "MoonFlow request validation fails closed on authority drift" {
  let request : @suite_adapter.MoonflowAdapterRequest = {
    request_id: "request-integrate",
    run_id: "run-integrate",
    book_id: "robot-a",
    work_item_id: "work-integrate",
    declaration_id: "declaration-integrate",
    attempt_id: "attempt-integrate",
    idempotency_key: "run/work/1/sha256:input",
    product_id: "moonrobo",
    operation: "robot.integrate-digital-model",
    requested_authority: "physical-effect",
    acceptance_criteria: [],
    input_contracts: ["moonsuite.robot-design.v1"],
    output_contracts: ["moonrobo.digital-model-integration-receipt.v1"],
    required_claim: "digital-artifact",
    input_digest: "sha256:input",
    input_artifacts: ["inputs/robot-design.json"],
    timeout_ms: 1000,
    created_at: "2026-07-31T00:00:00Z",
  }
  assert_true(
    request
    .quality_issues()
    .contains("requested_authority does not match the operation contract"),
  )
}
