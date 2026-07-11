///|
fn book() -> @runtime.LoadedRoboBook {
  @runtime.load_robobook("examples/noetix-e1").unwrap()
}

///|
fn sidecar(
  book : @runtime.LoadedRoboBook,
  command_available : Bool,
) -> @bridge_sidecar.BridgeSidecarStatus {
  @bridge_sidecar.status_for_spec(
    @bridge_sidecar.spec_for_profile(book.profile, book.root),
    command_available,
  )
}

///|
test "moongate status reports degraded ready robot without sidecar command" {
  let book = book()
  let sidecar = sidecar(book, false)
  let resident = @resident.project(book, sidecar, [], [], [])
  let status = @moongate.project(book, sidecar, resident, [], [], [], 8800L)
  assert_eq(status.service, "moonrobo")
  assert_eq(status.robot_id, "noetix-e1-lab-01")
  assert_true(status.ready)
  assert_eq(status.status, "degraded")
  assert_eq(status.bridge_state, "missing-command")
  assert_eq(status.pending_review_count, 0)
}

///|
test "moongate status reports attention when review pressure exists" {
  let book = book()
  let sidecar = sidecar(book, true)
  let result = @pipeline.evaluate_request(
    book.profile,
    @core.bridge_ok("sdk-e1", book.profile.id, last_telemetry_age_ms=10),
    @pipeline.high_walk_intent(
      "intent-moongate-review",
      book.profile.id,
      @core.operator_requester("moongate-test"),
      "0.10",
      "0.00",
      "1000",
    ),
    "receipt-moongate-review",
    9000L,
  )
  let receipt = { ..result.receipt, status: WaitingForApproval }
  let resident = @resident.project(book, sidecar, [receipt], [], [])
  let status = @moongate.project(
    book,
    sidecar,
    resident,
    [receipt],
    [],
    [],
    9001L,
  )
  assert_eq(status.status, "attention")
  assert_eq(status.pending_review_count, 1)
  assert_eq(status.receipt_count, 1)
}
