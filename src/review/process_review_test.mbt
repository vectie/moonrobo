///|
fn review_plan() -> @task.ObservationTaskPlan {
  {
    task_id: "review-task",
    status: Accepted,
    capability: "observe.telemetry",
    session_id: "task-review-observe",
    receipt_id: "receipt-review-observe",
    requester: @core.moontown_requester("standing-goal"),
    goal: "review observation",
    planned_at_ms: 1000L,
  }
}

///|
fn review_receipt(status : @core.RunStatus) -> @core.RunReceipt {
  let profile = @core.noetix_e1_profile("review-robot", "Review Robot")
  let intent = @core.command_intent(
    "intent-review",
    profile.id,
    "observe.telemetry",
    @core.moontown_requester("standing-goal"),
  )
  let verdict = @core.evaluate_intent(
    {
      profile,
      bridge_health: @core.bridge_ok(profile.bridge.id, profile.id),
      approval_id: None,
      dry_run_receipt_id: None,
      developer_gate: false,
    },
    intent,
  )
  {
    ..@core.receipt_from_verdict(
      "receipt-review-stop",
      profile.bridge.id,
      intent,
      verdict,
      1000L,
    ),
    status,
  }
}

///|
fn review_replay(error_count : Int) -> @replay.ReplayTimeline {
  {
    session_id: "task-review-observe",
    robot_id: "review-robot",
    bridge_id: "sdk-e1",
    status: "stopped",
    started_at_ms: 1000L,
    stopped_at_ms: Some(1002L),
    telemetry_frame_count: 1,
    latest_frame_id: Some("frame-review"),
    frames: [
      {
        frame_id: "frame-review",
        artifact_path: "/tmp/frame-review.json",
        captured_at_ms: 1000L,
        mode: "high",
        joint_count: 24,
        error_count,
      },
    ],
  }
}

///|
test "review accepts clean observation run" {
  let review = @review.diagnose_observation_run(
    review_plan(),
    review_replay(0),
    review_receipt(Executed),
    "/tmp/receipt-review-stop.json",
    "/tmp/task-review-observe.json",
    1002L,
  )
  assert_true(review.disposition == Accepted)
  assert_true(review.severity == Info)
  assert_true(review.resolved_at_ms is None)
  assert_eq(review.findings.length(), 0)
  assert_true(review.artifact_paths.contains("/tmp/frame-review.json"))
  assert_true(review.artifact_paths.contains("/tmp/receipt-review-stop.json"))
}

///|
test "review flags telemetry errors" {
  let review = @review.diagnose_observation_run(
    review_plan(),
    review_replay(2),
    review_receipt(Executed),
    "/tmp/receipt-review-stop.json",
    "/tmp/task-review-observe.json",
    1002L,
  )
  assert_true(review.disposition == NeedsHumanReview)
  assert_true(review.severity == Attention)
  assert_eq(review.findings.length(), 1)
  assert_true(review.summary.contains("needs review"))
}

///|
test "review resolution accepts review and records operator note" {
  let review = @review.diagnose_observation_run(
    review_plan(),
    review_replay(2),
    review_receipt(Executed),
    "/tmp/receipt-review-stop.json",
    "/tmp/task-review-observe.json",
    1002L,
  )
  let resolved = @review.resolve_review(
    review, "checked telemetry warning", 1100L,
  )
  assert_true(resolved.disposition == Accepted)
  assert_true(resolved.severity == Info)
  assert_true(resolved.resolved_at_ms is Some(1100L))
  assert_true(resolved.resolution_note is Some("checked telemetry warning"))
  assert_eq(resolved.findings.length(), 1)
}
