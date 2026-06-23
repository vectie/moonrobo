///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create test directory: \{path}")
    }
  }
}

///|
fn clear_json_files(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path) catch {
      _ => fail("failed to read test directory: \{path}")
    }
    for name in names {
      if name.has_suffix(".json") {
        @fsx.remove_file(path + "/\{name}") catch {
          _ => fail("failed to remove stale test file: \{path}/\{name}")
        }
      }
    }
  }
}

///|
fn prepare_root(root : String) -> Unit raise {
  ensure_dir(root)
  ensure_dir(root + "/runs")
  ensure_dir(root + "/runs/receipts")
  ensure_dir(root + "/runs/dry-runs")
  ensure_dir(root + "/runs/approvals")
  ensure_dir(root + "/runs/bridge-dispatches")
  ensure_dir(root + "/runs/task-executions")
  ensure_dir(root + "/moonbook")
  ensure_dir(root + "/moonbook/memory")
  ensure_dir(root + "/moonbook/task-messages")
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/dry-runs")
  clear_json_files(root + "/runs/approvals")
  clear_json_files(root + "/runs/bridge-dispatches")
  clear_json_files(root + "/runs/task-executions")
  clear_json_files(root + "/moonbook/memory")
  clear_json_files(root + "/moonbook/task-messages")
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write test profile")
  }
}

///|
fn task_message_json(message_id : String) -> String {
  @task.task_message_request(
    message_id,
    "",
    @core.operator_requester("bridge-execution-test"),
    "walk forward",
    3000L,
  )
  .to_json()
  .stringify()
}

///|
fn post(root : String, path : String, body : String) -> Unit raise {
  let response = @host_api.route_with_body(root, "POST", path, body)
  assert_eq(response.status, 200)
}

///|
fn prepare_task_message_for_execution(root : String) -> Unit raise {
  post(
    root,
    @host_api.moontown_task_message_path(),
    task_message_json("sidecar-ledger"),
  )
  post(
    root,
    @host_api.moonbook_task_message_evaluate_path("message-sidecar-ledger"),
    "",
  )
  post(
    root,
    @host_api.moonbook_task_message_dry_run_path("message-sidecar-ledger"),
    "",
  )
  post(
    root,
    @host_api.moonbook_task_message_approve_path("message-sidecar-ledger"),
    "",
  )
}

///|
test "sidecar task-message execution persists rejected bridge response as failed receipt" {
  let root = "/tmp/moonrobo-bridge-execution-sidecar-ledger-test"
  prepare_root(root)
  prepare_task_message_for_execution(root)
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-message-sidecar-ledger",
    profile.id,
    "control.high.walk",
    @core.operator_requester("bridge-execution-test"),
    parameters={ "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
  )
  let request = @bridge_protocol.execute_request(
    "request-execute-intent-message-sidecar-ledger-3000", profile, intent, 3000L,
  )
  let response = @bridge_protocol.rejected_response(
    request, "SDK E1 bridge scaffold is read-only until supervised control transport is enabled",
  )
  let execution = @bridge_execution.persist_task_message_execution_response(
    root,
    "message-sidecar-ledger",
    response,
    runtime_log_path=root + "/runs/runtime-supervisor/message-sidecar.log",
  ).unwrap()
  assert_true(execution.receipt.status == Failed)
  assert_eq(
    execution.receipt.bridge_error.unwrap(),
    "SDK E1 bridge scaffold is read-only until supervised control transport is enabled",
  )
  assert_true(execution.bridge_response.status == Rejected)
  assert_eq(execution.bridge_dispatch.status, "Rejected")
  assert_eq(execution.bridge_dispatch.path, "/intents/execute")
  assert_eq(
    execution.bridge_dispatch.runtime_log_path,
    root + "/runs/runtime-supervisor/message-sidecar.log",
  )
  assert_eq(
    execution.receipt_path,
    root + "/runs/receipts/receipt-intent-message-sidecar-ledger-executed.json",
  )
  assert_eq(
    execution.dispatch_path,
    root +
    "/runs/bridge-dispatches/dispatch-request-execute-intent-message-sidecar-ledger-3000.json",
  )
  assert_eq(
    execution.memory.memory_path,
    root + "/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
  )
  assert_true(@fsx.path_exists(execution.memory.memory_path))
  assert_eq(
    execution.execution_snapshot_path,
    root +
    "/runs/task-executions/task-execution-message-sidecar-ledger-3000.json",
  )
  assert_true(@fsx.path_exists(execution.execution_snapshot_path))
  assert_eq(
    execution.execution_snapshot.memory_path,
    execution.memory.memory_path,
  )
  assert_eq(execution.execution_snapshot.dispatch_path, execution.dispatch_path)
  let persisted = @runtime.read_run_receipt(
    root, "receipt-intent-message-sidecar-ledger-executed",
  ).unwrap()
  assert_true(persisted.status == Failed)
  let dispatch = @runtime.read_bridge_dispatch_evidence(
    root, "dispatch-request-execute-intent-message-sidecar-ledger-3000",
  ).unwrap()
  assert_eq(dispatch.status, "Rejected")
  let snapshot = @runtime.read_task_execution_snapshot(
    root, "task-execution-message-sidecar-ledger-3000",
  ).unwrap()
  assert_eq(snapshot.receipt_id, execution.receipt.receipt_id)
  assert_eq(snapshot.bridge_status, "Rejected")
  assert_eq(
    snapshot.runtime_log_path,
    root + "/runs/runtime-supervisor/message-sidecar.log",
  )
}

///|
test "reviewed message workflow prepares MoonBook gates before execution" {
  let root = "/tmp/moonrobo-bridge-execution-reviewed-message-test"
  prepare_root(root)
  let preparation = @bridge_execution.prepare_reviewed_message(
    root,
    "reviewed-message",
    "walk forward",
    @core.operator_requester("bridge-execution-test"),
    3100L,
  ).unwrap()
  assert_eq(preparation.task_id, "message-reviewed-message")
  assert_eq(preparation.evaluate_status, 200)
  assert_eq(preparation.dry_run_status, 200)
  assert_eq(preparation.approval_status, 200)
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-message-reviewed-message",
    profile.id,
    "control.high.walk",
    @core.operator_requester("bridge-execution-test"),
    parameters={ "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
  )
  let bridge_request = @bridge_protocol.execute_request(
    "request-execute-intent-message-reviewed-message-3100", profile, intent, 3100L,
  )
  let execution = @bridge_execution.persist_task_message_execution_response(
    root,
    "message-reviewed-message",
    @bridge_protocol.rejected_response(bridge_request, "read-only"),
  ).unwrap()
  assert_true(execution.receipt.status == Failed)
  assert_eq(execution.bridge_dispatch.status, "Rejected")
  assert_true(@fsx.path_exists(execution.execution_snapshot_path))
}

///|
test "accepted sidecar execution preserves SDK command artifact" {
  let root = "/tmp/moonrobo-bridge-execution-accepted-sidecar-test"
  prepare_root(root)
  prepare_task_message_for_execution(root)
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-message-sidecar-ledger",
    profile.id,
    "control.high.walk",
    @core.operator_requester("bridge-execution-test"),
    parameters={ "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
  )
  let request = @bridge_protocol.execute_request(
    "request-execute-intent-message-sidecar-ledger-3000", profile, intent, 3000L,
  )
  let ready = @core.receipt_from_verdict(
    "receipt-intent-message-sidecar-ledger-bridge",
    profile.bridge.id,
    intent,
    @core.evaluate_intent(
      {
        profile,
        bridge_health: @core.bridge_ok(
          profile.bridge.id,
          profile.id,
          last_telemetry_age_ms=0,
        ),
        approval_id: Some("approval-test"),
        dry_run_receipt_id: Some("dry-run-test"),
        developer_gate: false,
      },
      intent,
    ),
    3000L,
  )
  let bridge_receipt = @core.executed_receipt(
    ready.receipt_id,
    ready,
    3000L,
    telemetry_frame_count=1,
    artifact_paths=[
      "sdk-e1://high-control/WALK?vertical=0.1&horizontal=0&duration_ms=1000&data=0",
    ],
  )
  let feedback_frame = {
    ..@core.empty_telemetry_frame(
      "sdk-e1-command-feedback-intent-message-sidecar-ledger-3000",
      profile.id,
      profile.bridge.id,
      3000L,
    ),
    mode: "high",
    joints: profile.joints.map(fn(joint) {
      {
        name: joint.name,
        index: joint.index,
        position: 0.0,
        velocity: 0.0,
        torque: 0.0,
        error: None,
      }
    }),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": "control.high.walk",
      "command_x": "0.10",
      "command_yaw": "0.00",
      "command_duration_ms": "1000",
    },
  }
  let response = {
    ..@bridge_protocol.receipt_response(request, bridge_receipt),
    telemetry: Some(feedback_frame),
  }
  let execution = @bridge_execution.persist_task_message_execution_response(
    root,
    "message-sidecar-ledger",
    response,
    runtime_log_path=root + "/runs/runtime-supervisor/message-sidecar.log",
  ).unwrap()
  assert_true(execution.receipt.status == Executed)
  assert_eq(execution.bridge_dispatch.status, "Accepted")
  assert_eq(
    execution.execution_snapshot.runtime_log_path,
    root + "/runs/runtime-supervisor/message-sidecar.log",
  )
  assert_true(execution.receipt.artifact_paths.length() == 2)
  assert_true(
    execution.receipt.artifact_paths[0].contains("sdk-e1://high-control/WALK"),
  )
  assert_eq(
    execution.receipt.artifact_paths[1],
    root +
    "/runs/telemetry/sidecar-execution/sdk-e1-command-feedback-intent-message-sidecar-ledger-3000.json",
  )
  assert_eq(execution.execution_snapshot.runtime_status, "healthy")
  assert_true(execution.execution_snapshot.runtime_health_persisted)
  assert_eq(
    execution.execution_snapshot.physical_feedback_path,
    execution.receipt.artifact_paths[1],
  )
  assert_true(
    @fsx.path_exists(execution.execution_snapshot.physical_feedback_path),
  )
  let feedback = @runtime.read_telemetry_frame_file(
    execution.execution_snapshot.physical_feedback_path,
  ).unwrap()
  assert_eq(
    feedback.operator_input.get("command_intent_id").unwrap(),
    "intent-message-sidecar-ledger",
  )
  let report = @host_api.task_execution_proof_report(root).unwrap()
  assert_eq(report.verified_count, 1)
  match report.latest {
    Some(latest) => {
      assert_true(latest.verified)
      assert_eq(latest.command_outcome_status, "motion-feedback-checked")
    }
    None => fail("expected latest execution proof")
  }
  assert_true(@fsx.path_exists(execution.execution_snapshot_path))
}
