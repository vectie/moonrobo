///|
fn loaded_book() -> @runtime.LoadedRobotBook {
  @runtime.load_robotbook("examples/noetix-e1").unwrap()
}

///|
fn sidecar(
  book : @runtime.LoadedRobotBook,
  launchable : Bool,
) -> @bridge_sidecar.BridgeSidecarStatus {
  @bridge_sidecar.status_for_spec(
    @bridge_sidecar.spec_for_profile(book.profile, book.root),
    launchable,
  )
}

///|
fn waiting_receipt(book : @runtime.LoadedRobotBook) -> @core.RunReceipt {
  let intent = @core.command_intent(
    "intent-resident-walk",
    book.profile.id,
    "control.high.walk",
    @core.moontown_requester("mayor"),
  )
  let verdict = @core.evaluate_intent(
    {
      profile: book.profile,
      bridge_health: @core.bridge_ok(
        book.profile.bridge.id,
        book.profile.id,
        last_telemetry_age_ms=0,
      ),
      approval_id: None,
      dry_run_receipt_id: None,
      developer_gate: false,
    },
    intent,
  )
  @core.receipt_from_verdict(
    "receipt-resident-walk",
    book.profile.bridge.id,
    intent,
    verdict,
    100L,
  )
}

///|
fn active_session(book : @runtime.LoadedRobotBook) -> @core.ObservationSession {
  @core.observation_session(
    "observe-resident",
    book.profile,
    @core.moontown_requester("mayor"),
    "receipt-observe-resident",
    200L,
    telemetry_frame_count=3,
    latest_frame_id="frame-resident",
  )
}

///|
test "resident projection reports active observation and review state" {
  let book = loaded_book()
  let agent = @resident.project(
    book,
    sidecar(book, true),
    [waiting_receipt(book)],
    [active_session(book)],
  )
  assert_eq(agent.resident_id, "robot:noetix-e1-lab-01")
  assert_eq(agent.role, "physical-robot")
  assert_eq(agent.availability, "observing")
  assert_eq(agent.safety_state, "review-required")
  assert_eq(agent.bridge_state, "launchable")
  assert_eq(agent.active_observation.unwrap().session_id, "observe-resident")
  assert_eq(agent.latest_receipt.unwrap().receipt_id, "receipt-resident-walk")
  assert_eq(agent.review_count, 1)
  assert_eq(agent.capability_count, 3)
}

///|
test "resident projection reports missing bridge when no session is active" {
  let book = loaded_book()
  let agent = @resident.project(book, sidecar(book, false), [], [])
  assert_eq(agent.availability, "bridge-missing")
  assert_eq(agent.safety_state, "clear")
  assert_true(agent.active_observation is None)
  assert_true(agent.latest_receipt is None)
}
