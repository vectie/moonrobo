///|
fn loaded_book() -> @runtime.LoadedRoboBook {
  @runtime.load_robobook("examples/noetix-e1").unwrap()
}

///|
fn sidecar(
  book : @runtime.LoadedRoboBook,
  launchable : Bool,
) -> @bridge_sidecar.BridgeSidecarStatus {
  @bridge_sidecar.status_for_spec(
    @bridge_sidecar.spec_for_profile(book.profile, book.root),
    launchable,
  )
}

///|
fn waiting_receipt(book : @runtime.LoadedRoboBook) -> @core.RunReceipt {
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
fn executed_receipt(book : @runtime.LoadedRoboBook) -> @core.RunReceipt {
  let intent = @core.command_intent(
    "intent-resident-executed",
    book.profile.id,
    "control.high.walk",
    @core.moontown_requester("mayor"),
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "resident test allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-resident-ready",
    book.profile.bridge.id,
    intent,
    verdict,
    300L,
  )
  @core.executed_receipt("receipt-resident-executed", ready, 301L)
}

///|
fn execution_snapshot(
  book : @runtime.LoadedRoboBook,
  verified : Bool,
) -> @core.TaskExecutionSnapshot {
  let receipt = executed_receipt(book)
  let dispatch = @core.bridge_dispatch_evidence(
    if verified {
      "dispatch-resident-verified"
    } else {
      "dispatch-resident-partial"
    },
    if verified {
      "request-resident-verified"
    } else {
      "request-resident-partial"
    },
    book.profile.bridge.id,
    book.profile.id,
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    receipt.intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge accepted",
    if verified {
      303L
    } else {
      302L
    },
  )
  @core.task_execution_snapshot(
    if verified {
      "task-execution-resident-verified"
    } else {
      "task-execution-resident-partial"
    },
    "message-resident",
    "/moonbook/task-messages/message-resident.json",
    "/runs/receipts/receipt-resident-executed.json",
    "/runs/bridge-dispatches/\{dispatch.dispatch_id}.json",
    "/moonbook/memory/memory-resident.json",
    receipt,
    dispatch,
    if verified {
      303L
    } else {
      302L
    },
    runtime_health_path=if verified {
      "/runs/runtime-health/latest.json"
    } else {
      ""
    },
    runtime_status=if verified { "healthy" } else { "" },
    runtime_health_persisted=verified,
    telemetry_frame_id=if verified { "frame-resident-verified" } else { "" },
    telemetry_captured_at_ms=if verified { 303L } else { 0L },
  )
}

///|
fn active_session(book : @runtime.LoadedRoboBook) -> @core.ObservationSession {
  @core.observation_session(
    "observe-resident",
    book.profile,
    @core.moontown_requester("mayor"),
    "receipt-observe-resident",
    200L,
    telemetry_frame_count=3,
    latest_frame_id="frame-resident",
    artifact_paths=["runs/telemetry/observe-resident/frame-resident.json"],
  )
}

///|
fn process_review(book : @runtime.LoadedRoboBook) -> @review.ProcessReview {
  {
    review_id: "review-resident",
    task_id: "task-resident",
    session_id: "observe-resident",
    robot_id: book.profile.id,
    receipt_id: "receipt-observe-resident",
    disposition: NeedsHumanReview,
    severity: Attention,
    summary: "needs review",
    findings: ["telemetry warning"],
    artifact_paths: ["runs/telemetry/observe-resident/frame-resident.json"],
    created_at_ms: 201L,
    resolved_at_ms: None,
    resolution_note: None,
  }
}

///|
test "resident projection summarizes latest task execution proof" {
  let book = loaded_book()
  let agent = @resident.project(book, sidecar(book, true), [], [], [], executions=[
    execution_snapshot(book, false),
    execution_snapshot(book, true),
  ])
  assert_eq(agent.execution_count, 2)
  assert_eq(agent.verified_execution_count, 1)
  assert_eq(
    agent.latest_execution.unwrap().snapshot_id,
    "task-execution-resident-verified",
  )
  assert_eq(agent.latest_execution.unwrap().status, "verified")
  assert_true(agent.latest_execution.unwrap().verified)
}

///|
test "resident mapping binds one profile to one town resident and bridge" {
  let book = loaded_book()
  let agent = @resident.project(book, sidecar(book, true), [], [], [], executions=[
    execution_snapshot(book, true),
  ])
  let mapping = @resident.digital_physical_mapping(
    book,
    agent,
    runtime_status="healthy",
    runtime_bridge_base_url="http://127.0.0.1:5391",
  )
  assert_eq(mapping.mapping_id, "mapping:noetix-e1-lab-01")
  assert_eq(mapping.resident_id, "robot:noetix-e1-lab-01")
  assert_eq(mapping.bridge_id, "sdk-e1")
  assert_true(mapping.mapped)
  assert_true(mapping.reachable)
  assert_eq(mapping.latest_task_id, "message-resident")
  assert_eq(mapping.latest_execution_status, "verified")
  assert_eq(mapping.latest_feedback_status, "matched")
  assert_eq(mapping.latest_command_outcome_status, "motion-feedback-observed")
}

///|
test "resident projection reports active observation and review state" {
  let book = loaded_book()
  let agent = @resident.project(
    book,
    sidecar(book, true),
    [waiting_receipt(book)],
    [active_session(book)],
    [],
  )
  assert_eq(agent.resident_id, "robot:noetix-e1-lab-01")
  assert_eq(agent.role, "physical-robot")
  assert_eq(agent.availability, "observing")
  assert_eq(agent.safety_state, "review-required")
  assert_eq(agent.bridge_state, "launchable")
  assert_eq(agent.active_observation.unwrap().session_id, "observe-resident")
  assert_eq(
    agent.active_observation.unwrap().latest_artifact_path.unwrap(),
    "runs/telemetry/observe-resident/frame-resident.json",
  )
  assert_eq(agent.latest_receipt.unwrap().receipt_id, "receipt-resident-walk")
  assert_eq(agent.review_count, 1)
  assert_eq(agent.capability_count, 4)
}

///|
test "resident projection reports missing bridge when no session is active" {
  let book = loaded_book()
  let agent = @resident.project(book, sidecar(book, false), [], [], [])
  assert_eq(agent.availability, "bridge-missing")
  assert_eq(agent.safety_state, "clear")
  assert_true(agent.active_observation is None)
  assert_true(agent.latest_receipt is None)
}

///|
test "resident projection counts process reviews" {
  let book = loaded_book()
  let agent = @resident.project(
    book,
    sidecar(book, true),
    [],
    [active_session(book)],
    [process_review(book)],
  )
  assert_eq(agent.safety_state, "review-required")
  assert_eq(agent.review_count, 1)
}
