///|
fn prepare_agent_process_root(root : String) -> Unit {
  ignore(@runtime.ensure_process_dirs(root).unwrap())
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/observations")
  clear_json_files(root + "/runs/reviews")
  clear_json_files(root + "/runs/runtime-health")
  clear_json_files(root + "/runs/runtime-validation")
  clear_json_files(root + "/runs/runtime-validation/sessions")
  clear_json_files(root + "/runs/runtime-calibration")
  clear_json_files(root + "/runs/runtime-calibration/resolutions")
  clear_json_files(root + "/runs/agent-process")
  clear_json_files(root + "/moonbook/memory")
  clear_json_files(root + "/agents")
  ignore(
    @runtime.write_robot_profile(
      root,
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
    ).unwrap(),
  )
}

///|
fn clear_json_files(path : String) -> Unit {
  if !@fsx.path_exists(path) {
    return
  }
  let names = @fsx.read_dir(path) catch { _ => return }
  for name in names {
    if name.has_suffix(".json") {
      @fsx.remove_file(path + "/\{name}") catch {
        _ => ()
      }
    }
  }
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
    resolved_at_ms: None,
    resolution_note: None,
  }
}

///|
fn write_healthy_runtime(root : String, recorded_at_ms : Int64) -> Unit {
  let frame = @core.empty_telemetry_frame(
    "frame-agent-process-runtime", "noetix-e1-lab-01", "sdk-e1", recorded_at_ms,
  )
  let telemetry_path = @runtime.write_telemetry_frame(
    root, "agent-process-runtime", frame,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        recorded_at_ms, "healthy", true, true, 42, "launch-agent-process-runtime",
        "runtime-noetix-e1-lab-01:sdk-e1", "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391",
        true, "ok", "telemetry healthy", telemetry_path, "frame-agent-process-runtime",
        recorded_at_ms,
      ),
    ).unwrap(),
  )
}

///|
fn write_pending_runtime_revalidation(root : String) -> Unit {
  ignore(
    @runtime.write_runtime_calibration_plan(
      root,
      "runtime-calibration-agent-process",
      (
        #|{
        #|  "plan_id": "runtime-calibration-agent-process",
        #|  "generated_at_ms": "8000",
        #|  "session_id": "runtime-validation-session-agent-process",
        #|  "runtime_id": "runtime-noetix-e1-lab-01:sdk-e1",
        #|  "robot_id": "noetix-e1-lab-01",
        #|  "bridge_id": "sdk-e1",
        #|  "status": "needs-calibration",
        #|  "action_count": 1,
        #|  "blocking_action_count": 1,
        #|  "actions": [
        #|    {
        #|      "action_id": "calibrate-runtime-agent-process",
        #|      "blocker_code": "runtime-active",
        #|      "severity": "blocker",
        #|      "owner": "runtime",
        #|      "evidence_path": "/api/runtime/validation",
        #|      "summary": "Physical runtime supervisor is not active",
        #|      "next_step": "Start the runtime supervisor and refresh validation before dispatching physical tasks"
        #|    }
        #|  ]
        #|}
      ),
    ),
  )
  ignore(
    @runtime.write_runtime_calibration_resolution(
      root,
      "runtime-calibration-resolution-agent-process",
      (
        #|{
        #|  "resolution_id": "runtime-calibration-resolution-agent-process",
        #|  "plan_id": "runtime-calibration-agent-process",
        #|  "action_id": "calibrate-runtime-agent-process",
        #|  "blocker_code": "runtime-active",
        #|  "owner": "runtime",
        #|  "resolved_by": "operator",
        #|  "resolved_at_ms": "8050",
        #|  "note": "runtime supervisor started",
        #|  "evidence_path": "/api/runtime/validation",
        #|  "next_validation_route": "/api/runtime/validation/session",
        #|  "status": "resolved-pending-validation"
        #|}
      ),
    ),
  )
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
  assert_true(result.memory_persisted)
  assert_true(@fsx.path_exists(result.memory_path))
  assert_true(result.planning.plan.action == Observe)
  assert_true(result.planning.context.memory.card_count > 0)
  assert_true(result.planning.context.tool_registry.capability_count >= 12)
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
  assert_true(record.result.memory_persisted)
  assert_true(@fsx.path_exists(record.result.memory_path))
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
  assert_true(result.memory_persisted)
  assert_true(@fsx.path_exists(result.memory_path))
  assert_true(result.planning.plan.action == ReviewEvidence)
  assert_true(
    result.planning.context.tool_registry.providers.any(fn(provider) {
      provider.provider_id == "moonrobo-host-api"
    }),
  )
  assert_true(result.observation_run is None)
  assert_eq(result.reviews.length(), 1)
  assert_eq(result.resident.review_count, 1)
}

///|
test "agent process remediates runtime validation through Moonrobo gateway" {
  let root = "/tmp/moonrobo-agent-process-revalidation-test"
  prepare_agent_process_root(root)
  write_healthy_runtime(root, 8200L)
  write_pending_runtime_revalidation(root)
  let result = @agent_process.run_next(root, {
    task_id: "agent-process-revalidation",
    goal: "agent process runtime validation",
    now_ms: 8300L,
    frame_count: 3,
    frame_interval_ms: 1L,
  }).unwrap()
  assert_true(result.outcome == RemediatedReadiness)
  assert_true(result.persisted)
  assert_true(result.memory_persisted)
  assert_true(@fsx.path_exists(result.memory_path))
  assert_true(result.planning.plan.action == RemediateReadiness)
  match result.gateway {
    Some(gateway) => {
      assert_eq(gateway.route, "/api/runtime/validation/session")
      assert_eq(gateway.status, 200)
      assert_true(@fsx.path_exists(gateway.evidence_path))
    }
    None => fail("expected gateway evidence")
  }
  let next = @agent_process.run_next(root, {
    task_id: "agent-process-revalidation-after",
    goal: "agent process runtime validation after remediation",
    now_ms: 8400L,
    frame_count: 1,
    frame_interval_ms: 1L,
  }).unwrap()
  assert_true(next.planning.plan.action == Observe)
}
