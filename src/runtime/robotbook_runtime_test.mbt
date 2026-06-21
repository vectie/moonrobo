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
test "runtime writes run receipt JSON" {
  let root = "/tmp/moonrobo-runtime-receipt-test"
  assert_true(ensure_dir(root))
  assert_true(ensure_dir(root + "/runs"))
  assert_true(ensure_dir(root + "/runs/receipts"))
  let profile = @core.noetix_e1_profile("receipt-test", "Receipt Test")
  let intent = @core.command_intent(
    "intent-receipt-test",
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
  let receipt = @core.receipt_from_verdict(
    "receipt-runtime-test",
    profile.bridge.id,
    intent,
    verdict,
    0L,
  )
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
