///|
pub(all) struct MockBridgeState {
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  frame_index : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn new(profile : @core.RobotProfile) -> MockBridgeState {
  { bridge_id: profile.bridge.id, robot_id: profile.id, frame_index: 0 }
}

///|
pub fn health(
  profile : @core.RobotProfile,
  telemetry_age_ms? : Int = 0,
) -> @core.BridgeHealth {
  @core.bridge_ok(
    profile.bridge.id,
    profile.id,
    last_telemetry_age_ms=telemetry_age_ms,
  )
}

///|
pub fn next_state(state : MockBridgeState) -> MockBridgeState {
  { ..state, frame_index: state.frame_index + 1 }
}

///|
pub fn telemetry_frame(
  profile : @core.RobotProfile,
  state : MockBridgeState,
  captured_at_ms : Int64,
) -> @core.TelemetryFrame {
  {
    frame_id: "mock-\{state.frame_index}",
    robot_id: profile.id,
    bridge_id: state.bridge_id,
    captured_at_ms,
    mode: "read-only",
    joints: profile.joints.map(fn(joint) {
      let base = joint.index.to_double()
      {
        name: joint.name,
        index: joint.index,
        position: base * 0.01,
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
    operator_input: { "source": "mock" },
    errors: [],
  }
}
