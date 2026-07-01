///|
fn resident() -> @resident.ResidentRobotAgent {
  {
    resident_id: "robot:noetix-e1-lab-01",
    robot_id: "noetix-e1-lab-01",
    label: "Noetix E1",
    platform: "noetix-e1",
    role: "physical-robot",
    availability: "ready",
    safety_state: "clear",
    bridge_state: "launchable",
    active_observation: None,
    latest_observation: Some({
      session_id: "session-memory",
      status: "stopped",
      telemetry_frame_count: 3,
      latest_frame_id: Some("frame-memory"),
      latest_artifact_path: Some(
        "/runs/telemetry/session-memory/frame-memory.json",
      ),
      started_at_ms: 1L,
      stopped_at_ms: Some(2L),
    }),
    latest_receipt: None,
    latest_execution: None,
    latest_proof_session: None,
    execution_count: 0,
    verified_execution_count: 0,
    proof_session_count: 0,
    capability_count: 3,
    review_count: 1,
    command_path: "/tmp/sdk-e1",
    town_route: "/town/residents/robot:noetix-e1-lab-01",
  }
}

///|
fn unverified_execution() -> @resident.ResidentExecutionSummary {
  {
    snapshot_id: "task-execution-memory",
    task_id: "message-memory",
    status: "bridge-accepted",
    verified: false,
    message: "runtime proof missing",
    receipt_id: "receipt-memory-executed",
    command_capability: "control.high.walk",
    bridge_status: "Accepted",
    runtime_status: "",
    runtime_health_persisted: false,
    telemetry_frame_id: "",
    physical_feedback_path: "",
    physical_feedback_status: "missing",
    physical_feedback_verified: false,
    command_outcome_status: "unconfirmed",
    command_outcome_verified: false,
    captured_at_ms: 11L,
  }
}

///|
fn review() -> @review.ProcessReview {
  {
    review_id: "review-memory",
    task_id: "task-memory",
    session_id: "session-memory",
    robot_id: "noetix-e1-lab-01",
    receipt_id: "receipt-memory",
    disposition: NeedsHumanReview,
    severity: Attention,
    summary: "operator should inspect replay evidence",
    findings: ["review before next task"],
    artifact_paths: ["/tmp/review-memory.json"],
    created_at_ms: 3L,
    resolved_at_ms: None,
    resolution_note: None,
  }
}

///|
fn queue() -> @platform_queue.RobotPlatformQueue {
  let item : @platform_queue.RobotPlatformWorkItem = {
    work_id: "work-memory-review",
    kind: "review-evidence",
    priority: 95,
    title: "Review evidence",
    summary: "Review queued evidence",
    target_id: "review-memory",
    target_path: "/api/reviews/review-memory",
    reason: "human review is pending",
  }
  {
    queue_id: "queue-memory",
    robot_id: "noetix-e1-lab-01",
    resident_id: "robot:noetix-e1-lab-01",
    generated_at_ms: 4L,
    item_count: 1,
    high_priority_count: 1,
    items: [item],
  }
}

///|
test "MoonBook memory pack includes latest task execution proof" {
  let pack = @moonbook.project(
    {
      ..resident(),
      latest_execution: Some(unverified_execution()),
      execution_count: 1,
      verified_execution_count: 0,
    },
    [review()],
    queue(),
    30L,
  )
  assert_eq(pack.card_count, 5)
  assert_true(pack.cards.any(card => card.kind == "latest-execution"))
  assert_true(pack.highest_priority >= 89)
  let text = @moonbook.memory_pack_json(pack)
  assert_true(
    text.contains("\"next_route\": \"/api/moonrobo/executions/feedback\""),
  )
  assert_true(text.contains("bridge-accepted task message-memory"))
}

///|
test "MoonBook memory pack keeps resident observation and work pressure" {
  let pack = @moonbook.project(resident(), [review()], queue(), 10L)
  assert_eq(pack.pack_id, "moonbook-memory-noetix-e1-lab-01-10")
  assert_eq(pack.card_count, 4)
  assert_eq(pack.highest_priority, 95)
  assert_true(pack.cards.any(card => card.kind == "resident-state"))
  assert_true(pack.cards.any(card => card.kind == "latest-observation"))
  assert_true(pack.cards.any(card => card.kind == "latest-review"))
  assert_true(pack.cards.any(card => card.kind == "work-pressure"))
  let text = @moonbook.memory_pack_json(pack)
  assert_true(text.contains("\"next_route\": \"/api/moonrobo/platform-queue\""))
}

///|
test "MoonBook memory pack accepts robot decorator proof cards" {
  let proof = @moonbook.memory_card(
    "noetix-e1-lab-01", "robot:noetix-e1-lab-01", "closed-loop-proof", 94, "Closed-loop proof",
    "Moonrobo prove-loop advanced to 5/6", "/tmp/robobook/.moonsuite/products/moonrobo/prove-loop/prove-loop.json",
    "/api/runtime/supervisor/start", 40L,
  )
  let pack = @moonbook.project(resident(), [review()], queue(), 40L, extra_cards=[
    proof,
  ])
  assert_eq(pack.card_count, 5)
  assert_true(pack.cards.any(card => card.kind == "closed-loop-proof"))
  assert_eq(pack.highest_priority, 95)
  let text = @moonbook.memory_pack_json(pack)
  assert_true(text.contains("\"kind\": \"closed-loop-proof\""))
  assert_true(text.contains("/api/runtime/supervisor/start"))
}

///|
test "MoonBook memory pack remembers latest proof session" {
  let session = @resident.proof_session_summary(
    "proof-session-memory", "blocked", false, 2, 3, "stalled", "/.moonsuite/products/moonrobo/proof-sessions/proof-session-memory.json",
    "/.moonsuite/products/moonrobo/prove-loop/prove-loop-memory.json", "/api/runtime/supervisor/start",
    2, 1, true, 200, "Physical feedback verified.", "proof session blocked",
  )
  let pack = @moonbook.project(
    {
      ..resident(),
      latest_proof_session: Some(session),
      proof_session_count: 1,
    },
    [review()],
    queue(),
    42L,
  )
  assert_true(pack.cards.any(card => card.kind == "latest-proof-session"))
  assert_true(pack.highest_priority >= 86)
  let text = @moonbook.memory_pack_json(pack)
  assert_true(text.contains("\"kind\": \"latest-proof-session\""))
  assert_true(
    text.contains(
      "/.moonsuite/products/moonrobo/proof-sessions/proof-session-memory.json",
    ),
  )
  assert_true(text.contains("feedback 1/2"))
  assert_true(text.contains("feedback_closed true"))
  assert_true(text.contains("/api/runtime/supervisor/start"))
}

///|
test "MoonBook memory pack includes latest runtime health" {
  let health = @runtime_health.record(
    12L, "bridge-unhealthy", true, true, 99, "launch-memory", "runtime-memory", "noetix-e1-lab-01",
    "sdk-e1", "http://127.0.0.1:5391", false, "bridge-connect-failed", "failed to connect",
    "/telemetry/latest", "", 0L,
  )
  let pack = @moonbook.project(
    resident(),
    [review()],
    queue(),
    20L,
    latest_runtime_health=Some(health),
  )
  assert_eq(pack.card_count, 5)
  assert_true(pack.highest_priority >= 94)
  assert_true(pack.cards.any(card => card.kind == "runtime-health"))
  let text = @moonbook.memory_pack_json(pack)
  assert_true(text.contains("\"next_route\": \"/api/runtime/health\""))
  assert_true(text.contains("bridge telemetry failed"))
}
