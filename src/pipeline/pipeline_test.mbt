///|
test "pipeline marks allowed observation ready on healthy bridge" {
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
  assert_true(result.receipt.status == ReadyForExecution)
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
  assert_true(approved.receipt.status == ReadyForExecution)
}

///|
fn prepare_pipeline_root(root : String) -> Unit {
  ignore(
    @runtime.write_robot_profile(
      root,
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
    ).unwrap(),
  )
}

///|
test "pipeline runs bounded observation process" {
  let root = "/tmp/moonrobo-pipeline-observe-run-test"
  prepare_pipeline_root(root)
  let result = @pipeline.run_bounded_observation(root, {
    task_id: "pipeline-standing-goal",
    robot_id: "",
    requester: @core.moontown_requester("standing-goal"),
    goal: "pipeline direct observation",
    now_ms: 6000L,
    frame_count: 4,
    frame_interval_ms: 5L,
  }).unwrap()
  assert_true(result.persisted)
  assert_eq(result.plan.session_id, "task-pipeline-standing-goal-observe")
  assert_eq(result.frame_submissions.length(), 3)
  assert_true(result.stop.session.status == Stopped)
  assert_eq(result.replay.telemetry_frame_count, 4)
  assert_eq(result.replay.frames.length(), 4)
  let session = @runtime.read_observation_session(
    root, "task-pipeline-standing-goal-observe",
  ).unwrap()
  assert_true(session.status == Stopped)
  assert_eq(session.telemetry_frame_count, 4)
  let paths = @runtime.list_telemetry_frame_paths(
    root, "task-pipeline-standing-goal-observe",
  ).unwrap()
  assert_eq(paths.length(), 4)
}

///|
test "pipeline rejects duplicate observation frame" {
  let root = "/tmp/moonrobo-pipeline-duplicate-frame-test"
  prepare_pipeline_root(root)
  let started = @pipeline.start_observation(root, {
    session_id: "pipeline-duplicate-session",
    receipt_id: "receipt-pipeline-duplicate-start",
    requester: @core.operator_requester("pipeline-test"),
    now_ms: 7000L,
  }).unwrap()
  let frames = @runtime.list_telemetry_frames(
    root, "pipeline-duplicate-session",
  ).unwrap()
  assert_eq(frames.length(), 1)
  let duplicate = @pipeline.ingest_observation_frame(
    root,
    "pipeline-duplicate-session",
    frames[0],
  )
  ignore(started)
  assert_true(duplicate is Err(_))
}
