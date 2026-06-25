///|
test "runtime loads example RoboBook from disk" {
  let loaded = @runtime.load_robobook("examples/noetix-e1").unwrap()
  assert_eq(loaded.profile.id, "noetix-e1-lab-01")
  assert_eq(loaded.profile.joints.length(), 24)
  assert_true(loaded.status.ready)
}

///|
test "runtime reports missing RoboBook profile" {
  let result = @runtime.load_robobook("examples/missing")
  assert_true(result is Err(_))
  match result {
    Err(issue) => assert_eq(issue.code, "read-profile")
    Ok(_) => fail("expected missing profile to fail")
  }
}

///|
test "runtime writes RoboBook profile JSON" {
  let root = "/tmp/moonrobo-runtime-profile-write-test"
  let profile = @core.noetix_e1_profile(
    "profile-write-test", "Profile Write Test",
  )
  let path = @runtime.write_robot_profile(root, profile).unwrap()
  assert_eq(path, root + "/robot.json")
  let loaded = @runtime.load_robot_profile(root).unwrap()
  assert_eq(loaded.id, "profile-write-test")
  assert_eq(loaded.label, "Profile Write Test")
}

///|
test "runtime persists and reloads tool registry" {
  let root = "/tmp/moonrobo-runtime-tool-registry-test"
  let registry = @tool_registry.default_registry("registry-test-robot", 0L)
  let path = @runtime.write_tool_registry(root, registry).unwrap()
  assert_eq(path, root + "/agents/tool-registry.json")
  let loaded = @runtime.read_tool_registry(root).unwrap()
  assert_eq(loaded.robot_id, "registry-test-robot")
  assert_eq(loaded.provider_count, 3)
  assert_eq(loaded.capability_count, 42)
}

///|
test "runtime registers bounded tool provider" {
  let root = "/tmp/moonrobo-runtime-tool-register-test"
  let provider = @tool_registry.moonclaw_process_provider(
    "registry-register-robot", 42L,
  )
  let registry = @runtime.register_tool_provider(
    root, "registry-register-robot", provider, 42L,
  ).unwrap()
  assert_eq(registry.provider_count, 3)
  assert_true(
    registry.providers.any(fn(item) {
      item.provider_id == "moonclaw-process-planner" &&
      item.registered_at_ms == 42L
    }),
  )
}

///|
test "runtime persists latest runtime health evidence" {
  let root = "/tmp/moonrobo-runtime-health-record-test"
  let record = @runtime_health.record(
    1200L, "bridge-unhealthy", true, true, 42, "launch-health", "runtime-health",
    "robot-health", "sdk-e1", "http://127.0.0.1:5391", false, "bridge-connect-failed",
    "failed to connect", "/telemetry/latest", "", 0L,
  )
  let path = @runtime.write_runtime_health(root, record).unwrap()
  assert_eq(path, root + "/runs/runtime-health/runtime-health-1200.json")
  assert_true(@fsx.path_exists(@runtime.latest_runtime_health_path(root)))
  let latest = @runtime.read_latest_runtime_health(root).unwrap().unwrap()
  assert_eq(latest.status, "bridge-unhealthy")
  assert_eq(latest.pid, 42)
  let paths = @runtime.list_runtime_health_paths(root).unwrap()
  assert_true(paths.contains(path))
  assert_true(!paths.contains(root + "/runs/runtime-health/latest.json"))
}

///|
test "runtime persists latest runtime validation report" {
  let root = "/tmp/moonrobo-runtime-validation-report-test"
  let report_json = "{ \"status\": \"blocked\", \"checks\": [{ \"code\": \"runtime-active\" }] }"
  let path = @runtime.write_runtime_validation_report(
    root, "runtime-validation-test", report_json,
  ).unwrap()
  assert_eq(
    path,
    root + "/runs/runtime-validation/runtime-validation-test.json",
  )
  assert_true(@fsx.path_exists(@runtime.latest_runtime_validation_path(root)))
  let text = @fsx.read_file_to_string(
    @runtime.latest_runtime_validation_path(root),
  ) catch {
    _ => fail("failed to read latest runtime validation report")
  }
  assert_true(text.contains("\"status\": \"blocked\""))
  assert_true(text.contains("\"runtime-active\""))
}

///|
test "runtime persists latest bridge contract evidence" {
  let root = "/tmp/moonrobo-bridge-contract-test"
  let contract_json = "{ \"protocol_version\": 1, \"bridge_id\": \"sdk-e1\", \"routes\": [] }"
  let path = @runtime.write_bridge_contract(
    root, "bridge-contract-test", contract_json,
  ).unwrap()
  assert_eq(path, root + "/runs/bridge-contracts/bridge-contract-test.json")
  assert_true(@fsx.path_exists(@runtime.latest_bridge_contract_path(root)))
  let text = @fsx.read_file_to_string(
    @runtime.latest_bridge_contract_path(root),
  ) catch {
    _ => fail("failed to read latest bridge contract")
  }
  assert_true(text.contains("\"bridge_id\": \"sdk-e1\""))
}

///|
test "runtime persists latest runtime validation session" {
  let root = "/tmp/moonrobo-runtime-validation-session-test"
  let session_json = "{ \"status\": \"blocked\", \"sample_count\": 2, \"first_blocker_code\": \"runtime-active\" }"
  let path = @runtime.write_runtime_validation_session(
    root, "runtime-validation-session-test", session_json,
  ).unwrap()
  assert_eq(
    path,
    root +
    "/runs/runtime-validation/sessions/runtime-validation-session-test.json",
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
  )
  let text = @fsx.read_file_to_string(
    @runtime.latest_runtime_validation_session_path(root),
  ) catch {
    _ => fail("failed to read latest runtime validation session")
  }
  assert_true(text.contains("\"sample_count\": 2"))
  assert_true(text.contains("\"runtime-active\""))
}

///|
test "runtime persists latest runtime calibration plan" {
  let root = "/tmp/moonrobo-runtime-calibration-plan-test"
  let plan_json = "{ \"status\": \"needs-calibration\", \"action_count\": 2, \"session_id\": \"runtime-validation-session-test\" }"
  let path = @runtime.write_runtime_calibration_plan(
    root, "runtime-calibration-test", plan_json,
  ).unwrap()
  assert_eq(
    path,
    root + "/runs/runtime-calibration/runtime-calibration-test.json",
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_calibration_plan_path(root)),
  )
  let text = @fsx.read_file_to_string(
    @runtime.latest_runtime_calibration_plan_path(root),
  ) catch {
    _ => fail("failed to read latest runtime calibration plan")
  }
  assert_true(text.contains("\"needs-calibration\""))
  assert_true(text.contains("\"runtime-validation-session-test\""))
}

///|
test "runtime persists latest runtime calibration resolution" {
  let root = "/tmp/moonrobo-runtime-calibration-resolution-test"
  let resolution_json = "{ \"status\": \"resolved-pending-validation\", \"action_id\": \"calibrate-runtime-process\" }"
  let path = @runtime.write_runtime_calibration_resolution(
    root, "runtime-calibration-resolution-test", resolution_json,
  ).unwrap()
  assert_eq(
    path,
    root +
    "/runs/runtime-calibration/resolutions/runtime-calibration-resolution-test.json",
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_calibration_resolution_path(root)),
  )
  let text = @fsx.read_file_to_string(
    @runtime.latest_runtime_calibration_resolution_path(root),
  ) catch {
    _ => fail("failed to read latest runtime calibration resolution")
  }
  assert_true(text.contains("\"resolved-pending-validation\""))
  assert_true(text.contains("\"calibrate-runtime-process\""))
}

///|
fn ensure_dir(path : String) -> Bool {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => ()
    }
  }
  @fsx.path_exists(path)
}

///|
fn ensure_robobook_receipt_dirs(root : String) -> Bool {
  ensure_dir(root) &&
  ensure_dir(root + "/runs") &&
  ensure_dir(root + "/runs/receipts")
}

///|
fn receipt_fixture(receipt_id : @core.ReceiptId) -> @core.RunReceipt {
  let profile = @core.noetix_e1_profile("receipt-test", "Receipt Test")
  let intent = @core.command_intent(
    "intent-\{receipt_id}",
    profile.id,
    "observe.telemetry",
    @core.operator_requester("test"),
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
  @core.receipt_from_verdict(receipt_id, profile.bridge.id, intent, verdict, 0L)
}

///|
test "runtime writes run receipt JSON" {
  let root = "/tmp/moonrobo-runtime-receipt-test"
  assert_true(ensure_robobook_receipt_dirs(root))
  let receipt = receipt_fixture("receipt-runtime-test")
  let path = @runtime.write_run_receipt(root, receipt).unwrap()
  assert_eq(path, root + "/runs/receipts/receipt-runtime-test.json")
  let text = @fsx.read_file_to_string(path) catch {
    _ => fail("failed to read receipt JSON")
  }
  let json = @json.parse(text) catch {
    _ => fail("failed to parse receipt JSON")
  }
  let decoded : @core.RunReceipt = @json.from_json(json) catch {
    _ => fail("failed to decode receipt JSON")
  }
  assert_eq(decoded.receipt_id, "receipt-runtime-test")
  assert_true(decoded.status == ReadyForExecution)
}

///|
test "runtime lists and reads run receipts" {
  let root = "/tmp/moonrobo-runtime-receipt-list-test"
  assert_true(ensure_robobook_receipt_dirs(root))
  ignore(@runtime.write_run_receipt(root, receipt_fixture("receipt-list-a")))
  ignore(@runtime.write_run_receipt(root, receipt_fixture("receipt-list-b")))
  let paths = @runtime.list_receipt_paths(root).unwrap()
  assert_true(paths.contains(root + "/runs/receipts/receipt-list-a.json"))
  assert_true(paths.contains(root + "/runs/receipts/receipt-list-b.json"))
  let receipts = @runtime.list_run_receipts(root).unwrap()
  assert_true(receipts.length() >= 2)
  let receipt = @runtime.read_run_receipt(root, "receipt-list-b").unwrap()
  assert_eq(receipt.receipt_id, "receipt-list-b")
  assert_true(receipt.status == ReadyForExecution)
}

///|
test "runtime writes and reads dry-run and approval evidence" {
  let root = "/tmp/moonrobo-runtime-evidence-test"
  assert_true(ensure_robobook_receipt_dirs(root))
  let receipt = receipt_fixture("receipt-evidence-source")
  let dry_run = @core.dry_run_evidence(
    "dry-run-evidence", receipt, "dry run summary", 42L,
  )
  let dry_run_path = @runtime.write_dry_run_evidence(root, dry_run).unwrap()
  assert_eq(dry_run_path, root + "/runs/dry-runs/dry-run-evidence.json")
  let decoded_dry_run = @runtime.read_dry_run_evidence(root, "dry-run-evidence").unwrap()
  assert_eq(decoded_dry_run.source_receipt_id, "receipt-evidence-source")
  let approval = @core.approval_record(
    "approval-evidence",
    dry_run.dry_run_receipt_id,
    receipt.intent,
    @core.operator_requester("runtime-test"),
    "approved",
    43L,
  )
  let approval_path = @runtime.write_approval_record(root, approval).unwrap()
  assert_eq(approval_path, root + "/runs/approvals/approval-evidence.json")
  let decoded_approval = @runtime.read_approval_record(
    root, "approval-evidence",
  ).unwrap()
  assert_eq(decoded_approval.dry_run_receipt_id, "dry-run-evidence")
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-runtime-evidence",
    "request-runtime-evidence",
    receipt.bridge_id,
    receipt.robot_id,
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    receipt.intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    44L,
    runtime_log_path=root + "/runs/runtime-supervisor/runtime-evidence.log",
  )
  let dispatch_path = @runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap()
  assert_eq(
    dispatch_path,
    root + "/runs/bridge-dispatches/dispatch-runtime-evidence.json",
  )
  let decoded_dispatch = @runtime.read_bridge_dispatch_evidence(
    root, "dispatch-runtime-evidence",
  ).unwrap()
  assert_eq(decoded_dispatch.receipt_id, "receipt-evidence-source")
  assert_eq(decoded_dispatch.path, "/intents/execute")
  assert_eq(
    decoded_dispatch.runtime_log_path,
    root + "/runs/runtime-supervisor/runtime-evidence.log",
  )
  let snapshot = @core.task_execution_snapshot(
    "task-execution-runtime-evidence",
    "message-runtime-evidence",
    root + "/moonbook/task-messages/message-runtime-evidence.json",
    root + "/runs/receipts/receipt-evidence-source.json",
    dispatch_path,
    root + "/moonbook/memory/moonbook-memory-runtime-evidence.json",
    receipt,
    dispatch,
    45L,
    runtime_health_path=root + "/runs/runtime-health/runtime-health-45.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/runtime-evidence.log",
    telemetry_frame_id="frame-runtime-evidence",
    telemetry_captured_at_ms=45L,
  )
  let snapshot_path = @runtime.write_task_execution_snapshot(root, snapshot).unwrap()
  assert_eq(
    snapshot_path,
    root + "/runs/task-executions/task-execution-runtime-evidence.json",
  )
  let decoded_snapshot = @runtime.read_task_execution_snapshot(
    root, "task-execution-runtime-evidence",
  ).unwrap()
  assert_eq(decoded_snapshot.task_id, "message-runtime-evidence")
  assert_eq(decoded_snapshot.bridge_status, "Accepted")
  assert_eq(decoded_snapshot.runtime_status, "healthy")
  assert_eq(decoded_snapshot.telemetry_frame_id, "frame-runtime-evidence")
  assert_true(decoded_snapshot.physical_feedback_verified)
  assert_eq(
    decoded_snapshot.runtime_log_path,
    root + "/runs/runtime-supervisor/runtime-evidence.log",
  )
  let snapshot_paths = @runtime.list_task_execution_snapshot_paths(root).unwrap()
  assert_eq(snapshot_paths.length(), 1)
  assert_eq(snapshot_paths[0], snapshot_path)
}

///|
test "runtime writes and reads process reviews" {
  let root = "/tmp/moonrobo-runtime-review-test"
  let review : @review.ProcessReview = {
    review_id: "review-runtime-test",
    task_id: "task-runtime-test",
    session_id: "session-runtime-test",
    robot_id: "robot-runtime-test",
    receipt_id: "receipt-runtime-test",
    disposition: Accepted,
    severity: Info,
    summary: "accepted",
    findings: [],
    artifact_paths: ["/tmp/artifact-runtime-test.json"],
    created_at_ms: 45L,
    resolved_at_ms: None,
    resolution_note: None,
  }
  let path = @runtime.write_process_review(root, review).unwrap()
  assert_eq(path, root + "/runs/reviews/review-runtime-test.json")
  let decoded = @runtime.read_process_review(root, "review-runtime-test").unwrap()
  assert_eq(decoded.review_id, "review-runtime-test")
  assert_true(decoded.disposition == Accepted)
  let paths = @runtime.list_process_review_paths(root).unwrap()
  assert_true(paths.contains(path))
  let reviews = @runtime.list_process_reviews(root).unwrap()
  assert_eq(reviews.length(), 1)
  assert_eq(reviews[0].session_id, "session-runtime-test")
}

///|
test "runtime writes telemetry frame artifact" {
  let root = "/tmp/moonrobo-runtime-telemetry-test"
  assert_true(ensure_robobook_receipt_dirs(root))
  let frame = @core.empty_telemetry_frame(
    "frame-runtime-test", "robot-runtime-test", "bridge-runtime-test", 44L,
  )
  let path = @runtime.write_telemetry_frame(root, "session-runtime-test", frame).unwrap()
  assert_eq(
    path,
    root + "/runs/telemetry/session-runtime-test/frame-runtime-test.json",
  )
  let text = @fsx.read_file_to_string(path) catch {
    _ => fail("failed to read telemetry frame JSON")
  }
  assert_true(text.contains("\"frame_id\": \"frame-runtime-test\""))
  let paths = @runtime.list_telemetry_frame_paths(root, "session-runtime-test").unwrap()
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], path)
  let decoded = @runtime.read_telemetry_frame_file(path).unwrap()
  assert_eq(decoded.frame_id, "frame-runtime-test")
  let frames = @runtime.list_telemetry_frames(root, "session-runtime-test").unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(frames[0].robot_id, "robot-runtime-test")
}

///|
test "runtime writes policy evaluation JSON" {
  let root = "/tmp/moonrobo-runtime-policy-eval-test"
  let path = @runtime.write_policy_evaluation_json(
    root, "policy-eval-runtime", "{ \"physical_execution_allowed\": false, \"gate_status\": \"requires-dry-run\" }",
  ).unwrap()
  assert_eq(path, root + "/runs/policy-evals/policy-eval-runtime.json")
  let text = @fsx.read_file_to_string(path) catch {
    _ => fail("failed to read policy evaluation JSON")
  }
  assert_true(text.contains("\"physical_execution_allowed\": false"))
  assert_true(text.contains("\"gate_status\": \"requires-dry-run\""))
  let decoded = @runtime.read_policy_evaluation_json(
    root, "policy-eval-runtime",
  ).unwrap()
  assert_true(decoded.contains("\"physical_execution_allowed\": false"))
  let paths = @runtime.list_policy_evaluation_paths(root).unwrap()
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], path)
}

///|
test "runtime writes and lists replay annotations" {
  let root = "/tmp/moonrobo-runtime-annotation-test"
  let annotation = @annotation.replay_annotation(
    "annotation-runtime-test",
    "session-runtime-test",
    "frame-runtime-test",
    "usable",
    "operator accepted frame",
    "info",
    @core.operator_requester("runtime-test"),
    101L,
  )
  let path = @runtime.write_replay_annotation(root, annotation).unwrap()
  assert_eq(
    path,
    root + "/runs/annotations/session-runtime-test/annotation-runtime-test.json",
  )
  let decoded = @runtime.read_replay_annotation(
    root, "session-runtime-test", "annotation-runtime-test",
  ).unwrap()
  assert_eq(decoded.label, "usable")
  let paths = @runtime.list_replay_annotation_paths(
    root, "session-runtime-test",
  ).unwrap()
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], path)
  let annotations = @runtime.list_replay_annotations(
    root, "session-runtime-test",
  ).unwrap()
  assert_eq(annotations.length(), 1)
  assert_eq(annotations[0].frame_id, "frame-runtime-test")
}

///|
test "runtime writes and lists MoonBook memory packs" {
  let root = "/tmp/moonrobo-runtime-moonbook-memory-test"
  let pack : @moonbook.MoonBookMemoryPack = {
    pack_id: "moonbook-memory-runtime",
    robot_id: "robot-runtime-test",
    resident_id: "robot:runtime-test",
    generated_at_ms: 10L,
    card_count: 1,
    highest_priority: 80,
    cards: [
      {
        memory_id: "memory-runtime-next",
        robot_id: "robot-runtime-test",
        resident_id: "robot:runtime-test",
        kind: "next-work",
        priority: 80,
        title: "Collect observation",
        summary: "Robot needs fresh observation evidence",
        evidence_path: "/api/agent/next-action",
        next_route: "/api/agent/dispatch-next",
        created_at_ms: 10L,
      },
    ],
  }
  let path = @runtime.write_moonbook_memory_json(
    root,
    pack.pack_id,
    @moonbook.memory_pack_json(pack),
  ).unwrap()
  assert_eq(path, root + "/moonbook/memory/moonbook-memory-runtime.json")
  let decoded = @runtime.read_moonbook_memory_json(
    root, "moonbook-memory-runtime",
  ).unwrap()
  assert_true(decoded.contains("\"card_count\": 1"))
  assert_true(decoded.contains("\"kind\": \"next-work\""))
  let paths = @runtime.list_moonbook_memory_paths(root).unwrap()
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], path)
}

///|
test "runtime writes MoonBook task message plans" {
  let root = "/tmp/moonrobo-runtime-task-message-test"
  let plan_json =
    #|{
    #|  "task": {
    #|    "task_id": "message-runtime"
    #|  },
    #|  "classification": "command-intent-review"
    #|}
  let path = @runtime.write_moonbook_task_message_json(
    root, "message-runtime", plan_json,
  ).unwrap()
  assert_eq(path, root + "/moonbook/task-messages/message-runtime.json")
  let text = @fsx.read_file_to_string(path) catch {
    _ => fail("failed to read task message artifact")
  }
  assert_true(text.contains("\"classification\": \"command-intent-review\""))
  let decoded = @runtime.read_moonbook_task_message_json(
    root, "message-runtime",
  ).unwrap()
  assert_true(decoded.contains("\"task_id\": \"message-runtime\""))
  let paths = @runtime.list_moonbook_task_message_paths(root).unwrap()
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], path)
}
