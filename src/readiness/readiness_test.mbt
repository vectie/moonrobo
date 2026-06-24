///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create test directory")
    }
  }
}

///|
fn clear_json_files(path : String) -> Unit {
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path) catch { _ => [] }
    for name in names {
      if name.has_suffix(".json") {
        @fsx.remove_file(path + "/\{name}") catch {
          _ => ()
        }
      }
    }
  }
}

///|
fn prepare_root(
  root : String,
  complete_required_paths : Bool,
) -> @core.RobotProfile raise {
  ensure_dir(root)
  ignore(@runtime.ensure_process_dirs(root))
  ensure_dir(root + "/safety")
  ensure_dir(root + "/bridge")
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/bridge-dispatches")
  clear_json_files(root + "/runs/bridge-contracts")
  clear_json_files(root + "/runs/task-executions")
  clear_json_files(root + "/runs/runtime-health")
  clear_json_files(root + "/runs/runtime-validation")
  clear_json_files(root + "/runs/runtime-validation/sessions")
  clear_json_files(root + "/runs/runtime-calibration")
  clear_json_files(root + "/runs/runtime-calibration/resolutions")
  clear_json_files(root + "/moonbook/memory")
  clear_json_files(root + "/moonbook/task-messages")
  clear_json_files(root + "/agents")
  if complete_required_paths {
    @fsx.write_string_to_file(root + "/safety/policy.json", "{}") catch {
      _ => fail("failed to write test safety policy")
    }
    @fsx.write_string_to_file(root + "/bridge/bridge.json", "{}") catch {
      _ => fail("failed to write test bridge config")
    }
  } else {
    @fsx.remove_file(root + "/safety/policy.json") catch {
      _ => ()
    }
    @fsx.remove_file(root + "/bridge/bridge.json") catch {
      _ => ()
    }
  }
  let profile = @core.noetix_e1_profile(
    "readiness-test-robot", "Readiness Test Robot",
  )
  ignore(@runtime.write_robot_profile(root, profile))
  profile
}

///|
fn receipt_fixture(profile : @core.RobotProfile) -> @core.RunReceipt {
  let intent = @core.command_intent(
    "intent-readiness-test",
    profile.id,
    "observe.telemetry",
    @core.operator_requester("readiness-test"),
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
  @core.receipt_from_verdict(
    "receipt-readiness-test",
    profile.bridge.id,
    intent,
    verdict,
    100L,
  )
}

///|
fn memory_pack(profile : @core.RobotProfile) -> @moonbook.MoonBookMemoryPack {
  {
    pack_id: "moonbook-memory-readiness-test",
    robot_id: profile.id,
    resident_id: "robot:\{profile.id}",
    generated_at_ms: 200L,
    card_count: 1,
    highest_priority: 80,
    cards: [
      {
        memory_id: "memory-readiness-next",
        robot_id: profile.id,
        resident_id: "robot:\{profile.id}",
        kind: "next-work",
        priority: 80,
        title: "Execute mapped task",
        summary: "Operator task messages are persisted before execution.",
        evidence_path: "/api/moonbook/task-messages",
        next_route: "/api/moonbook/conversation",
        created_at_ms: 200L,
      },
    ],
  }
}

///|
fn persist_ready_evidence(root : String, profile : @core.RobotProfile) -> Unit {
  ignore(
    @runtime.write_moonbook_task_message_json(
      root,
      "message-readiness-test",
      (
        #|{
        #|  "task": {
        #|    "task_id": "message-readiness-test"
        #|  },
        #|  "classification": "command-intent-review"
        #|}
      ),
    ),
  )
  let pack = memory_pack(profile)
  let memory_path = @runtime.write_moonbook_memory_json(
    root,
    pack.pack_id,
    @moonbook.memory_pack_json(pack),
  ).unwrap()
  ignore(
    @runtime.write_tool_registry(
      root,
      @tool_registry.default_registry(profile.id, 200L),
    ),
  )
  ignore(
    @runtime.write_bridge_contract(
      root,
      "bridge-contract-readiness-test",
      @bridge_protocol.bridge_contract(profile, false, operations=[
        Contract,
        LatestTelemetry,
        ExecuteIntent,
        EmergencyStop,
      ])
      .to_json()
      .stringify(indent=2),
    ),
  )
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        200L,
        "healthy",
        true,
        true,
        4242,
        "launch-readiness-test",
        "runtime-readiness-test",
        profile.id,
        profile.bridge.id,
        "http://127.0.0.1:5391",
        true,
        "telemetry-ok",
        "ok",
        "/telemetry/latest",
        "frame-readiness-test",
        200L,
      ),
    ),
  )
  let receipt = receipt_fixture(profile)
  let receipt_path = @runtime.write_run_receipt(root, receipt).unwrap()
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-readiness-test",
    "request-readiness-test",
    profile.bridge.id,
    profile.id,
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    receipt.intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    201L,
    runtime_log_path=root + "/runs/runtime-supervisor/readiness.log",
  )
  let dispatch_path = @runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap()
  ignore(
    @runtime.write_task_execution_snapshot(
      root,
      @core.task_execution_snapshot(
        "task-execution-readiness-test",
        "message-readiness-test",
        root + "/moonbook/task-messages/message-readiness-test.json",
        receipt_path,
        dispatch_path,
        memory_path,
        receipt,
        dispatch,
        202L,
        runtime_health_path=root +
          "/runs/runtime-health/runtime-health-200.json",
        runtime_status="healthy",
        runtime_health_persisted=true,
        runtime_log_path=root + "/runs/runtime-supervisor/readiness.log",
        telemetry_frame_id="frame-readiness-execution",
        telemetry_captured_at_ms=202L,
      ),
    ),
  )
}

///|
fn write_runtime_calibration_plan(
  root : String,
  generated_at_ms : Int64,
) -> Unit {
  ignore(
    @runtime.write_runtime_calibration_plan(
      root,
      "runtime-calibration-readiness",
      (
        $|{
        $|  "plan_id": "runtime-calibration-readiness",
        $|  "generated_at_ms": "\{generated_at_ms}",
        $|  "session_id": "runtime-validation-session-readiness",
        $|  "runtime_id": "runtime-readiness-test:sdk-e1",
        $|  "robot_id": "readiness-test-robot",
        $|  "bridge_id": "sdk-e1",
        $|  "status": "needs-calibration",
        $|  "action_count": 1,
        $|  "blocking_action_count": 1,
        $|  "actions": [
        $|    {
        $|      "action_id": "calibrate-runtime-readiness",
        $|      "blocker_code": "runtime-active",
        $|      "severity": "blocker",
        $|      "owner": "runtime",
        $|      "evidence_path": "/api/runtime/validation",
        $|      "summary": "Physical runtime supervisor is not active",
        $|      "next_step": "Start the runtime supervisor and refresh validation before dispatching physical tasks"
        $|    }
        $|  ]
        $|}
      ),
    ),
  )
}

///|
fn write_runtime_calibration_resolution(
  root : String,
  resolved_at_ms : Int64,
) -> Unit {
  ignore(
    @runtime.write_runtime_calibration_resolution(
      root,
      "runtime-calibration-resolution-readiness",
      (
        $|{
        $|  "resolution_id": "runtime-calibration-resolution-readiness",
        $|  "plan_id": "runtime-calibration-readiness",
        $|  "action_id": "calibrate-runtime-readiness",
        $|  "blocker_code": "runtime-active",
        $|  "owner": "runtime",
        $|  "resolved_by": "operator",
        $|  "resolved_at_ms": "\{resolved_at_ms}",
        $|  "note": "runtime supervisor started",
        $|  "evidence_path": "/api/runtime/validation",
        $|  "next_validation_route": "/api/runtime/validation/session",
        $|  "status": "resolved-pending-validation"
        $|}
      ),
    ),
  )
}

///|
fn write_ready_runtime_validation_session(
  root : String,
  generated_at_ms : Int64,
) -> Unit {
  ignore(
    @runtime.write_runtime_validation_session(
      root,
      "runtime-validation-session-readiness-ready",
      (
        $|{
        $|  "session_id": "runtime-validation-session-readiness-ready",
        $|  "generated_at_ms": "\{generated_at_ms}",
        $|  "runtime_id": "runtime-readiness-test:sdk-e1",
        $|  "robot_id": "readiness-test-robot",
        $|  "bridge_id": "sdk-e1",
        $|  "status": "ready",
        $|  "ready_for_live_sdk": true,
        $|  "required_sample_count": 1,
        $|  "sample_count": 1,
        $|  "ready_sample_count": 1,
        $|  "blocked_sample_count": 0,
        $|  "first_blocker_code": "",
        $|  "report_ids": [],
        $|  "reports": []
        $|}
      ),
    ),
  )
}

///|
test "readiness report blocks incomplete first milestone evidence" {
  let root = "/tmp/moonrobo-readiness-blocked-test"
  ignore(prepare_root(root, false))
  let book = @runtime.load_robobook(root).unwrap()
  let report = @readiness.report(root, book)
  assert_true(!report.ready)
  assert_eq(report.status, "blocked")
  assert_true(report.fail_count > 0)
  assert_eq(report.conversation_turn_count, 0)
  assert_eq(report.memory_card_count, 0)
  assert_eq(report.task_execution_count, 0)
  assert_true(report.checks.any(item => item.code == "robobook-ready"))
  assert_true(report.checks.any(item => item.code == "tool-registry-ready"))
  let plan = @readiness.plan(report)
  assert_eq(plan.status, "needs-action")
  assert_eq(plan.blocking_action_count, plan.action_count)
  assert_true(plan.action_count > 0)
  assert_true(
    plan.next_action
    is Some(
      {
        action_id: "repair-robobook-required-files",
        physical_execution_allowed: false,
        ..,
      }
    ),
  )
  assert_true(
    plan.actions.any(item => {
      item.check_code == "tool-registry-ready" &&
      item.route == "/api/tools/registry"
    }),
  )
}

///|
test "readiness report passes when task, memory, registry, health, and execution evidence exist" {
  let root = "/tmp/moonrobo-readiness-ready-test"
  let profile = prepare_root(root, true)
  persist_ready_evidence(root, profile)
  let book = @runtime.load_robobook(root).unwrap()
  let report = @readiness.report(root, book)
  assert_true(report.ready)
  assert_eq(report.status, "ready")
  assert_eq(report.pass_count, report.check_count)
  assert_eq(report.fail_count, 0)
  assert_eq(report.conversation_turn_count, 1)
  assert_eq(report.memory_card_count, 1)
  assert_true(report.registered_capability_count >= 14)
  assert_eq(report.task_execution_count, 1)
  assert_eq(report.latest_runtime_status, "healthy")
  assert_true(@readiness.report_json(report).contains("\"status\": \"ready\""))
  let plan = @readiness.plan(report)
  assert_eq(plan.status, "ready")
  assert_eq(plan.action_count, 0)
  assert_true(plan.next_action is None)
}

///|
test "readiness report blocks unresolved runtime calibration" {
  let root = "/tmp/moonrobo-readiness-calibration-blocked-test"
  let profile = prepare_root(root, true)
  persist_ready_evidence(root, profile)
  write_runtime_calibration_plan(root, 1000L)
  let book = @runtime.load_robobook(root).unwrap()
  let report = @readiness.report(root, book)
  assert_true(!report.ready)
  assert_true(
    report.checks.any(item => {
      item.code == "runtime-calibration-clear" && item.status == "fail"
    }),
  )
  let plan = @readiness.plan(report)
  assert_true(
    plan.next_action
    is Some(
      {
        action_id: "resolve-runtime-calibration-blockers",
        route: "/api/agent/runtime-calibration/latest",
        ..,
      }
    ),
  )
}

///|
test "readiness report blocks read only bridge contract evidence" {
  let root = "/tmp/moonrobo-readiness-bridge-contract-blocked-test"
  let profile = prepare_root(root, true)
  persist_ready_evidence(root, profile)
  ignore(
    @runtime.write_bridge_contract(
      root,
      "bridge-contract-readiness-read-only",
      @bridge_protocol.bridge_contract(profile, true, operations=[
        Contract,
        LatestTelemetry,
        ExecuteIntent,
        EmergencyStop,
      ])
      .to_json()
      .stringify(indent=2),
    ),
  )
  let book = @runtime.load_robobook(root).unwrap()
  let report = @readiness.report(root, book)
  assert_true(!report.ready)
  assert_true(
    report.checks.any(item => {
      item.code == "bridge-contract-ready" && item.status == "fail"
    }),
  )
  let plan = @readiness.plan(report)
  assert_true(
    plan.actions.any(item => {
      item.action_id == "persist-live-bridge-contract" &&
      item.http_method == "POST" &&
      item.route == "/api/runtime/validation/session"
    }),
  )
}

///|
test "readiness report requires validation after calibration resolution" {
  let root = "/tmp/moonrobo-readiness-validation-blocked-test"
  let profile = prepare_root(root, true)
  persist_ready_evidence(root, profile)
  write_runtime_calibration_plan(root, 1000L)
  write_runtime_calibration_resolution(root, 1100L)
  let book = @runtime.load_robobook(root).unwrap()
  let report = @readiness.report(root, book)
  assert_true(!report.ready)
  assert_true(
    report.checks.any(item => {
      item.code == "runtime-calibration-clear" && item.status == "pass"
    }),
  )
  assert_true(
    report.checks.any(item => {
      item.code == "runtime-validation-current" && item.status == "fail"
    }),
  )
  let plan = @readiness.plan(report)
  assert_true(
    plan.next_action
    is Some(
      {
        action_id: "rerun-runtime-validation-session",
        route: "/api/runtime/validation/session",
        ..,
      }
    ),
  )
  write_ready_runtime_validation_session(root, 1200L)
  let ready_report = @readiness.report(root, book)
  assert_true(ready_report.ready)
}
