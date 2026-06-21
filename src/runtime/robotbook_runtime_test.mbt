///|
test "runtime loads example RobotBook from disk" {
  let loaded = @runtime.load_robotbook("examples/noetix-e1").unwrap()
  assert_eq(loaded.profile.id, "noetix-e1-lab-01")
  assert_eq(loaded.profile.joints.length(), 24)
  assert_true(loaded.status.ready)
}

///|
test "runtime reports missing RobotBook profile" {
  let result = @runtime.load_robotbook("examples/missing")
  assert_true(result is Err(_))
  match result {
    Err(issue) => assert_eq(issue.code, "read-profile")
    Ok(_) => fail("expected missing profile to fail")
  }
}

///|
test "runtime writes RobotBook profile JSON" {
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
fn ensure_dir(path : String) -> Bool {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => ()
    }
  }
  @fsx.path_exists(path)
}

///|
fn ensure_robotbook_receipt_dirs(root : String) -> Bool {
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
  assert_true(ensure_robotbook_receipt_dirs(root))
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
  assert_true(ensure_robotbook_receipt_dirs(root))
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
  assert_true(ensure_robotbook_receipt_dirs(root))
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
  assert_true(ensure_robotbook_receipt_dirs(root))
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
