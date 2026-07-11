///|
fn simulation_profile() -> @core.RobotProfile {
  {
    id: "simulation-rover",
    label: "Simulation Rover",
    kind: MobileBase,
    platform: "simulation",
    profile_version: 1,
    model: { primary: "model/robot.urdf", alternates: [] },
    bridge: { id: "sim-rover", kind: Sim, config_path: "bridge/bridge.json" },
    joints: [@core.joint("wheel", 0)],
    sensors: [],
    capabilities: [
      @core.capability("simulate.motion", Simulate, "Simulate motion"),
    ],
    limits: {
      telemetry_freshness_ms: 1000,
      heartbeat_ms: 500,
      default_mode: "simulation-only",
      high_control_max_x_abs: 0.1,
      high_control_max_yaw_abs: 0.25,
      high_control_max_duration_ms: 1000,
    },
  }
}

///|
test "simulation bridge readiness does not demand physical runtime evidence" {
  let profile = simulation_profile()
  let bridge = bridge_contract_ready("/tmp/simulation-rover", profile)
  let runtime = runtime_health_ready(profile, true, "missing")
  assert_eq(bridge.status, "pass")
  assert_true(bridge.message.contains("simulation bridge"))
  assert_eq(runtime.status, "pass")
  assert_true(runtime.message.contains("no physical runtime supervisor"))
}
