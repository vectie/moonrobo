///|
fn fixture_body(name : String, x : Double) -> @scene.RigidBody {
  {
    path: name,
    name,
    world_transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 0, 0, 1],
    enabled: true,
    kinematic: false,
    mass_properties: Json::null(),
    velocity: [0, 0, 0],
    angular_velocity_degrees: [0, 0, 0],
  }
}

///|
fn fixture_joint(
  name : String,
  parent : String,
  child : String,
  kind : String,
) -> @scene.Joint {
  {
    path: name,
    name,
    kind,
    body0: [parent],
    body1: [child],
    local_position0: [1, 0, 0],
    local_position1: [0, 0, 0],
    local_rotation0_wxyz: [1, 0, 0, 0],
    local_rotation1_wxyz: [1, 0, 0, 0],
    axis: "Z",
    limits: { "lower": -180.0, "upper": 180.0, "unit": "degrees" },
    enabled: true,
    collision_enabled: false,
    excluded_from_articulation: false,
    drives: [],
  }
}

///|
fn fixture_source() -> @scene.ArticulationIR {
  {
    format: "moonrobo.aligned-usd-articulation-ir.v1",
    root: "A",
    meters_per_unit: 1.0,
    kilograms_per_unit: 1.0,
    up_axis: "Z",
    bodies: [
      fixture_body("C", 2.0),
      fixture_body("A", 0.0),
      fixture_body("B", 1.0),
    ],
    joints: [
      fixture_joint("hinge", "A", "B", "revolute"),
      fixture_joint("fixed", "B", "C", "fixed"),
    ],
    shapes: [],
    materials: [],
    filtered_pairs: [],
    articulation_roots: ["A"],
    unsupported_features: [],
    extension_properties: [],
  }
}

///|
fn fixture_plan() -> @scene.ScenePlan {
  {
    format: "moonrobo.aligned-fixed-g1-scene-plan.v1",
    source: fixture_source(),
    canonical_joint_names: ["hinge"],
    actuators: [
      {
        name: "hinge",
        joint_name: "hinge",
        joint_path: "hinge",
        joint_index: 0,
        default_position_radians: @math.pi / 2.0,
        default_velocity_radians: 0.0,
        effort_limit: 10.0,
        velocity_limit: 2.0,
        stiffness: 5.0,
        damping: 1.0,
        armature: 0.1,
        action_scale: 0.5,
      },
    ],
    recipe: {
      "root_pose": { "position": [0, 0, 0], "quaternion_wxyz": [1, 0, 0, 0] },
    },
    sdk_revision_pins: {},
    newton_model_constructed: false,
    physical_equivalence_verified: false,
  }
}

///|
test "prepared reset FK and two-world global offsets remain consistent" {
  let result = prepare(fixture_plan(), [
    { transform: @geo.transform3(@geo.identity_basis3(), @geo.vec3(0, 0, 0)), },
    {
      transform: @geo.transform3(
        @geo.yaw_basis3(@math.pi / 2.0),
        @geo.vec3(10, 0, 0),
      ),
    },
  ])
  assert_eq(result.body_source_index, [1, 2, 0, 1, 2, 0])
  assert_eq(result.body_world, [0, 0, 0, 1, 1, 1])
  assert_eq(result.joint_parent, [-1, 0, 1, -1, 3, 4])
  assert_eq(result.joint_child, [0, 1, 2, 3, 4, 5])
  assert_eq(result.joint_type, [4, 1, 3, 4, 1, 3])
  assert_eq(result.joint_q_start, [0, 7, 8, 8, 15, 16, 16])
  assert_eq(result.joint_qd_start, [0, 6, 7, 7, 13, 14, 14])
  assert_eq(result.canonical_joint_to_builder, [1, 4])
  assert_eq(result.canonical_coord_to_builder, [7, 15])
  assert_eq(result.canonical_dof_to_builder, [6, 13])
  assert_true((result.body_q[14] - 1.0).abs() < 1.0e-12)
  assert_true((result.body_q[15] - 1.0).abs() < 1.0e-12)
  assert_true((result.body_q[35] - 9.0).abs() < 1.0e-12)
  assert_true((result.body_q[36] - 1.0).abs() < 1.0e-12)
  assert_true(
    !result.full_finalize_complete &&
    !result.newton_model_constructed &&
    !result.mass_properties_complete,
  )
}

///|
test "tree rejects parallel parents hidden cycles and improper transforms" {
  let source = fixture_source()
  try
    tree({
      ..source,
      joints: source.joints + [fixture_joint("parallel", "A", "B", "fixed")],
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("parallel joint must be rejected")
  }
  try
    tree({
      ..source,
      joints: source.joints + [fixture_joint("cycle", "C", "A", "fixed")],
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("cycle must be rejected")
  }
  let reflected = {
    ..source.bodies[0],
    world_transform: [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
  }
  try
    tree({ ..source, bodies: [reflected, source.bodies[1], source.bodies[2]], })
  catch {
    _ => ()
  } noraise {
    _ => fail("reflection must be rejected")
  }
}

///|
test "DFS preserves source sibling order and descends before the next branch" {
  let source = fixture_source()
  let ordered = tree({
    ..source,
    bodies: source.bodies + [fixture_body("D", 2.0)],
    joints: [
      fixture_joint("root_C", "A", "C", "fixed"),
      fixture_joint("B_D", "B", "D", "fixed"),
      fixture_joint("root_B", "A", "B", "fixed"),
    ],
  })
  assert_eq(ordered.joints, [0, 2, 1])
  assert_eq(ordered.bodies, [1, 0, 2, 3])
}

///|
test "authored inertia rotates principal axes without inferring missing data" {
  assert_true(mass_properties(Json::null()) is None)
  let s = 0.5.sqrt()
  let value : Json = {
    "mass": 2.0,
    "center_of_mass": [1, 2, 3],
    "diagonal_inertia": [1, 2, 2],
    "principal_axes_wxyz": Json([s, 0.0, 0.0, s]),
  }
  let properties = mass_properties(value).unwrap()
  assert_eq(properties.mass, 2.0)
  assert_eq(properties.inverse_mass, 0.5)
  assert_true((properties.inertia[0] - 2.0).abs() < 1.0e-12)
  assert_true((properties.inertia[4] - 1.0).abs() < 1.0e-12)
  assert_true((properties.inverse_inertia[0] - 0.5).abs() < 1.0e-12)
  try
    mass_properties({
      "mass": 2.0,
      "center_of_mass": [0, 0, 0],
      "diagonal_inertia": [1, 1, 5],
      "principal_axes_wxyz": [1, 0, 0, 0],
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("unphysical principal inertia must be rejected")
  }
}
