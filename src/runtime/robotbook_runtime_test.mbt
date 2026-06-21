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
  assert_true(decoded.status == Executed)
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
  assert_true(receipt.status == Executed)
}
