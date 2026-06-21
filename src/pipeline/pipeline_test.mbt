///|
test "pipeline lets observation execute immediately on healthy bridge" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @pipeline.observe_telemetry_intent(
    "intent-observe",
    profile.id,
    @core.moontown_requester("standing-goal"),
  )
  let result = @pipeline.evaluate_request(
    profile,
    @core.bridge_ok("sdk-e1", profile.id),
    intent,
    "receipt-1",
    1000L,
  )
  assert_true(result.next_action == Execute)
  assert_true(result.receipt.status == Executed)
}

///|
test "pipeline routes high control through dry run and approval" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @pipeline.high_walk_intent(
    "intent-walk",
    profile.id,
    @core.operator_requester("local"),
    "0.1",
    "0.0",
    "500",
  )
  let first = @pipeline.evaluate_request(
    profile,
    @core.bridge_ok("sdk-e1", profile.id, last_telemetry_age_ms=10),
    intent,
    "receipt-2",
    1000L,
  )
  assert_true(first.next_action == CollectDryRun)
  assert_true(first.receipt.status == WaitingForDryRun)
  let second = @pipeline.evaluate_request(
    profile,
    @core.bridge_ok("sdk-e1", profile.id, last_telemetry_age_ms=10),
    intent,
    "receipt-3",
    1100L,
    dry_run_receipt_id="receipt-dry-run",
  )
  assert_true(second.next_action == RequestApproval)
  assert_true(second.receipt.status == WaitingForApproval)
  let approved = @pipeline.evaluate_request(
    profile,
    @core.bridge_ok("sdk-e1", profile.id, last_telemetry_age_ms=10),
    intent,
    "receipt-4",
    1200L,
    dry_run_receipt_id="receipt-dry-run",
    approval_id="approval-1",
  )
  assert_true(approved.next_action == Execute)
  assert_true(approved.receipt.status == Executed)
}
