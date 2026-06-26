///|
fn fixture() -> String raise {
  @fsx.read_file_to_string("examples/noetix-e1/model/robot.urdf") catch {
    _ => fail("failed to read URDF fixture")
  }
}

///|
fn telemetry() -> @core.TelemetryFrame {
  {
    ..@core.empty_telemetry_frame(
      "frame-viewport", "noetix-e1-lab-01", "sdk-e1", 0L,
    ),
    joints: [
      {
        name: "waist_1_joint",
        index: 22,
        position: 0.22,
        velocity: 0.0,
        torque: 0.0,
        error: None,
      },
      {
        name: "waist_2_joint",
        index: 23,
        position: 0.23,
        velocity: 0.0,
        torque: 0.0,
        error: None,
      },
      {
        name: "arm_l1_joint",
        index: 0,
        position: 0.08,
        velocity: 0.0,
        torque: 0.0,
        error: None,
      },
    ],
  }
}

///|
test "URDF viewport simulation projects root and accumulated link poses" {
  let model = @urdf.parse(fixture())
  let simulation = @urdf_viewport.simulate(Some(model), telemetry())
  assert_eq(simulation.root_link, "base_link")
  assert_eq(simulation.simulated_links, 25)
  assert_eq(simulation.links[0].name, "base_link")
  assert_eq(simulation.links[0].status, "root")
  assert_eq(simulation.links[1].name, "torso_link")
  assert_eq(simulation.links[1].parent_joint, "waist_1_joint")
  assert_eq(simulation.links[1].depth, 1)
  assert_eq(simulation.links[1].z, 0.32)
  assert_true(simulation.links[1].transform.contains("q(0.22)"))
  assert_eq(simulation.links[3].name, "left_arm_1")
  assert_eq(simulation.links[3].depth, 3)
  assert_eq(simulation.links[3].y, 0.16)
  assert_eq(simulation.links[3].z, 0.62)
}

///|
test "URDF viewport limit helpers classify mapped poses" {
  assert_eq(
    @urdf_viewport.limit_state(true, true, 2.0, Some(-1.0), Some(1.0)),
    "above-limit",
  )
  assert_eq(
    @urdf_viewport.limit_state(true, true, 0.0, Some(-1.0), Some(1.0)),
    "ok",
  )
  assert_true(
    @urdf_viewport.normalized_position(0.0, Some(-1.0), Some(1.0)) is Some(0.5),
  )
}
