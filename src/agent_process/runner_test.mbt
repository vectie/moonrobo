///|
fn prepare_agent_process_root(root : String) -> Unit {
  ignore(
    @runtime.write_robot_profile(
      root,
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
    ).unwrap(),
  )
}

///|
fn process_review(
  disposition : @review.ReviewDisposition,
) -> @review.ProcessReview {
  {
    review_id: "review-agent-process-test",
    task_id: "task-agent-process-test",
    session_id: "session-agent-process-test",
    robot_id: "noetix-e1-lab-01",
    receipt_id: "receipt-agent-process-test",
    disposition,
    severity: if disposition == NeedsHumanReview {
      Attention
    } else {
      Info
    },
    summary: "operator review required",
    findings: if disposition == NeedsHumanReview {
      ["review the evidence queue"]
    } else {
      []
    },
    artifact_paths: ["/tmp/agent-process-review.json"],
    created_at_ms: 9000L,
  }
}

///|
test "agent process runs bounded observation when MoonClaw is clear" {
  let root = "/tmp/moonrobo-agent-process-observe-test"
  prepare_agent_process_root(root)
  let result = @agent_process.run_next(root, {
    task_id: "agent-process-observe",
    goal: "agent process observation test",
    now_ms: 8000L,
    frame_count: 3,
    frame_interval_ms: 2L,
  }).unwrap()
  assert_true(result.outcome == Observed)
  assert_true(result.persisted)
  assert_true(result.planning.plan.action == Observe)
  assert_true(result.observation_run is Some(_))
  assert_eq(result.reviews.length(), 1)
  assert_eq(result.resident.review_count, 0)
  let session = @runtime.read_observation_session(
    root, "task-agent-process-observe-observe",
  ).unwrap()
  assert_true(session.status == Stopped)
  assert_eq(session.telemetry_frame_count, 3)
}

///|
test "agent process records run ledger entries" {
  let root = "/tmp/moonrobo-agent-process-ledger-test"
  prepare_agent_process_root(root)
  let request = @agent_process.default_run_request(
    task_id="agent-process-ledger",
    goal="agent process ledger test",
    now_ms=8100L,
    frame_count=2,
    frame_interval_ms=1L,
  )
  let record = @agent_process.run_next_recorded(root, request).unwrap()
  assert_eq(record.run_id, "agent-process-agent-process-ledger-8100")
  assert_true(record.record_path.contains("/runs/agent-process/"))
  assert_true(record.result.outcome == Observed)
  let loaded = @agent_process.read_agent_process_record(root, record.run_id).unwrap()
  assert_eq(loaded.run_id, record.run_id)
  let records = @agent_process.list_agent_process_records(root).unwrap()
  assert_eq(records.length(), 1)
  assert_eq(records[0].run_id, record.run_id)
}

///|
test "agent process returns review queue without running new observation" {
  let root = "/tmp/moonrobo-agent-process-review-test"
  prepare_agent_process_root(root)
  ignore(@runtime.write_process_review(root, process_review(NeedsHumanReview)))
  let result = @agent_process.run_next(
    root,
    @agent_process.default_run_request(),
  ).unwrap()
  assert_true(result.outcome == ReviewRequired)
  assert_true(!result.persisted)
  assert_true(result.planning.plan.action == ReviewEvidence)
  assert_true(result.observation_run is None)
  assert_eq(result.reviews.length(), 1)
  assert_eq(result.resident.review_count, 1)
}
