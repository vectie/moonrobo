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
fn zero_telemetry() -> @core.TelemetryFrame {
  @core.empty_telemetry_frame(
    "frame-viewport-zero", "noetix-e1-lab-01", "sdk-e1", 0L,
  )
}

///|
fn changed_by_more_than(a : Double, b : Double, epsilon : Double) -> Bool {
  let delta = a - b
  delta > epsilon || delta < 0.0 - epsilon
}

///|
test "URDF viewport simulation projects root and accumulated link poses" {
  let model = @urdf.parse(fixture())
  let simulation = @urdf_viewport.simulate(Some(model), telemetry())
  let zeroed = @urdf_viewport.simulate(Some(model), zero_telemetry())
  assert_eq(simulation.root_link, "base_link")
  assert_eq(simulation.simulated_links, 25)
  assert_eq(simulation.links[0].name, "base_link")
  assert_eq(simulation.links[0].status, "root")
  assert_eq(simulation.links[0].world_basis.xx, 1.0)
  assert_eq(simulation.links[0].world_basis.yy, 1.0)
  assert_eq(simulation.links[0].world_basis.zz, 1.0)
  assert_eq(simulation.links[1].name, "torso_link")
  assert_eq(simulation.links[1].parent_joint, "waist_1_joint")
  assert_eq(simulation.links[1].depth, 1)
  assert_eq(simulation.links[1].z, 0.32)
  assert_true(simulation.links[1].transform.contains("q(0.22)"))
  assert_true(
    changed_by_more_than(
      simulation.links[1].world_basis.xy,
      zeroed.links[1].world_basis.xy,
      0.0001,
    ),
  )
  assert_eq(simulation.links[3].name, "left_arm_1")
  assert_eq(simulation.links[3].depth, 3)
  assert_true(
    changed_by_more_than(simulation.links[3].y, zeroed.links[3].y, 0.0001),
  )
  assert_eq(simulation.links[4].name, "left_arm_2")
  assert_true(
    changed_by_more_than(simulation.links[4].x, zeroed.links[4].x, 0.0001),
  )
  assert_true(
    changed_by_more_than(
      simulation.links[4].world_basis.xz,
      zeroed.links[4].world_basis.xz,
      0.0001,
    ),
  )
}

///|
test "URDF viewport visual instances follow link transforms" {
  let model = @urdf.parse(fixture())
  let posed = @urdf_viewport.visual_instances(Some(model), telemetry())
  let zeroed = @urdf_viewport.visual_instances(Some(model), zero_telemetry())
  assert_eq(posed.length(), 6)
  assert_eq(posed[0].link_name, "base_link")
  assert_eq(posed[0].geometry_kind, "mesh")
  assert_eq(posed[0].link_status, "root")
  assert_eq(posed[1].link_name, "torso_link")
  assert_eq(posed[1].z, 0.4)
  assert_eq(posed[3].link_name, "left_arm_1")
  assert_true(changed_by_more_than(posed[3].x, zeroed[3].x, 0.0001))
  assert_true(
    changed_by_more_than(
      posed[3].world_basis.xy,
      zeroed[3].world_basis.xy,
      0.0001,
    ),
  )
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
