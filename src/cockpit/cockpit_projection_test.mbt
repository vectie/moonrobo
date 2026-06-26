///|
fn loaded_book() -> @runtime.LoadedRoboBook {
  @runtime.load_robobook("examples/noetix-e1").unwrap()
}

///|
fn pipeline_result(
  book : @runtime.LoadedRoboBook,
  health : @core.BridgeHealth,
) -> @pipeline.PipelineResult {
  let intent = @pipeline.high_walk_intent(
    "intent-cockpit-walk",
    book.profile.id,
    @core.operator_requester("cockpit-test"),
    "0.10",
    "0.00",
    "1000",
  )
  @pipeline.evaluate_request(
    book.profile,
    health,
    intent,
    "receipt-cockpit-walk",
    0L,
  )
}

///|
fn telemetry(book : @runtime.LoadedRoboBook) -> @core.TelemetryFrame {
  {
    ..@core.empty_telemetry_frame(
      "frame-cockpit",
      book.profile.id,
      book.profile.bridge.id,
      0L,
    ),
    mode: "read-only",
    joints: book.profile.joints.map(fn(joint) {
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
    operator_input: { "source": "test" },
  }
}

///|
fn sidecar(
  book : @runtime.LoadedRoboBook,
) -> @bridge_sidecar.BridgeSidecarStatus {
  @bridge_sidecar.status_for_spec(
    @bridge_sidecar.spec_for_profile(book.profile, book.root),
    false,
  )
}

///|
test "cockpit projection composes first-screen state" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=10,
  )
  let safety = pipeline_result(book, health)
  let receipts = [safety.receipt]
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    telemetry(book),
    safety,
    receipts,
  )
  assert_eq(snapshot.robot.robot_id, "noetix-e1-lab-01")
  assert_eq(snapshot.product_status.service, "moonrobo")
  assert_eq(snapshot.product_status.status, "needs-foundation")
  assert_true(snapshot.robot.ready)
  assert_eq(snapshot.robot.joints, 24)
  assert_eq(snapshot.bridge.status, "ok")
  assert_false(snapshot.bridge.telemetry_stale)
  assert_eq(snapshot.sidecar.state, "missing-command")
  assert_false(snapshot.sidecar.ready_for_execution)
  assert_eq(snapshot.telemetry.joints, 24)
  assert_true(snapshot.telemetry.imu_available)
  assert_eq(snapshot.model_viewport.format, "urdf")
  assert_eq(snapshot.model_viewport.status, "ready")
  assert_eq(snapshot.model_viewport.mapped_joints, 24)
  assert_eq(snapshot.model_viewport.unmapped_joints, 0)
  assert_eq(snapshot.model_viewport.joints[0].name, "arm_l1_joint")
  assert_eq(snapshot.model_viewport.joints[0].role, "arm")
  assert_true(snapshot.model_viewport.joints[0].mapped)
  assert_eq(snapshot.safety.next_action, "collect-dry-run")
  assert_eq(snapshot.latest_receipt.unwrap().receipt_id, "receipt-cockpit-walk")
}

///|
test "cockpit projection detects stale telemetry" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=9999,
  )
  let safety = pipeline_result(book, health)
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    telemetry(book),
    safety,
    [],
  )
  assert_true(snapshot.bridge.telemetry_stale)
  assert_eq(snapshot.product_status.next_route, "/api/moonrobo/ask")
  assert_true(snapshot.latest_receipt is None)
}

///|
test "cockpit viewport reports missing telemetry mappings" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=10,
  )
  let safety = pipeline_result(book, health)
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    @core.empty_telemetry_frame(
      "frame-empty",
      book.profile.id,
      book.profile.bridge.id,
      0L,
    ),
    safety,
    [],
  )
  assert_eq(snapshot.model_viewport.status, "diagnostic")
  assert_eq(snapshot.model_viewport.mapped_joints, 0)
  assert_eq(snapshot.model_viewport.unmapped_joints, 24)
  assert_true(snapshot.model_viewport.issues[0].contains("declared joint"))
}
