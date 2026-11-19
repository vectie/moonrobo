///|
fn limit(value : Json) -> Double? raise {
  match value {
    Number(v) => {
      finite([v])
      Some(v * @math.pi / 180.0)
    }
    String("+infinity") | String("-infinity") => None
    _ => fail("unsupported USD angular limit encoding")
  }
}

///|
/// Prepare CPU/Double reset-state and topology arrays, not a Newton Model.
/// Each world offset composes with the recipe root pose; joint frames and
/// defaults determine body poses by FK, avoiding inconsistent q/body_q states.
pub fn prepare(
  plan : @scene.ScenePlan,
  worlds : Array[WorldPlacement],
) -> PreparedArrays raise {
  let source = plan.source
  guard source.format == "moonrobo.aligned-usd-articulation-ir.v1" &&
    source.up_axis == "Z" &&
    source.meters_per_unit == 1.0 &&
    source.kilograms_per_unit == 1.0 &&
    worlds.length() > 0 &&
    worlds.length() <= 1000000 else {
    fail("unsupported scene units or world count")
  }
  let topology = tree(source)
  let nb = topology.bodies.length()
  let nj = topology.joints.length() + 1
  guard worlds.length() <= 1000000 / nb else {
    fail("prepared CPU arrays exceed one million bodies")
  }
  guard plan.recipe
    is { "root_pose": { "position": p, "quaternion_wxyz": q, .. }, .. } else {
    fail("recipe initial root pose missing")
  }
  let recipe_root = frame(@json.from_json(p), @json.from_json(q))
  let actuator_by_path : Map[String, @scene.Actuator] = {}
  let names : Map[String, Unit] = {}
  guard plan.actuators.length() == plan.canonical_joint_names.length() else {
    fail("canonical motor map length differs")
  }
  for i, motor in plan.actuators {
    finite([
      motor.default_position_radians,
      motor.default_velocity_radians,
      motor.effort_limit,
      motor.velocity_limit,
      motor.stiffness,
      motor.damping,
      motor.armature,
      motor.action_scale,
    ])
    guard motor.joint_index == i &&
      motor.joint_name == plan.canonical_joint_names[i] &&
      !names.contains(motor.joint_name) &&
      !actuator_by_path.contains(motor.joint_path) &&
      motor.default_velocity_radians == 0.0 &&
      motor.effort_limit > 0.0 &&
      motor.velocity_limit > 0.0 &&
      motor.stiffness >= 0.0 &&
      motor.damping >= 0.0 &&
      motor.armature >= 0.0 else {
      fail("unsupported/inconsistent canonical motor parameters")
    }
    names[motor.joint_name] = ()
    actuator_by_path[motor.joint_path] = motor
  }
  let revolute = topology.joints.filter(i => source.joints[i].kind == "revolute")
  guard revolute.length() == actuator_by_path.length() else {
    fail("every supported revolute joint must have one explicit motor")
  }
  let body_paths = []
  let body_source_index = []
  let body_world = []
  let body_q = []
  let body_qd = []
  let body_mass_properties = []
  let joint_paths = []
  let joint_source_index = []
  let joint_world = []
  let joint_type = []
  let joint_parent = []
  let joint_child = []
  let joint_X_p = []
  let joint_X_c = []
  let joint_q_start = []
  let joint_qd_start = []
  let joint_q = []
  let joint_qd = []
  let joint_axis = []
  let joint_axis_start = []
  let joint_armature = []
  let joint_target_ke = []
  let joint_target_kd = []
  let joint_effort_limit = []
  let joint_velocity_limit = []
  let joint_limit_lower = []
  let joint_limit_upper = []
  let articulation_start = []
  let articulation_end = []
  let canonical_joint_to_builder = []
  let canonical_coord_to_builder = []
  let canonical_dof_to_builder = []
  let identity = @geo.transform3(@geo.identity_basis3(), @geo.vec3(0, 0, 0))
  for world, placement in worlds {
    let base_body = world * nb
    let base_joint = world * nj
    let root_pose = checked_transform(placement.transform).compose(recipe_root)
    ignore(checked_transform(root_pose))
    let poses : Map[String, @geo.Transform3] = {}
    let root_body = source.bodies[topology.root]
    poses[root_body.path] = root_pose
    articulation_start.push(base_joint)
    joint_paths.push(root_body.path + "::__floating_base__")
    joint_source_index.push(-1)
    joint_world.push(world)
    joint_type.push(4)
    joint_parent.push(-1)
    joint_child.push(base_body)
    joint_X_p.append(pose(identity))
    joint_X_c.append(pose(identity))
    joint_q_start.push(joint_q.length())
    joint_qd_start.push(joint_qd.length())
    joint_axis_start.push(joint_armature.length())
    joint_q.append(pose(root_pose))
    for i in 0..<6 {
      joint_qd.push(0.0)
      let a = match i % 3 {
        0 => [1.0, 0.0, 0.0]
        1 => [0.0, 1.0, 0.0]
        _ => [0.0, 0.0, 1.0]
      }
      joint_axis.append(a)
      joint_armature.push(0.0)
      joint_target_ke.push(0.0)
      joint_target_kd.push(0.0)
      joint_effort_limit.push(1000000.0)
      joint_velocity_limit.push(1000000.0)
      joint_limit_lower.push(None)
      joint_limit_upper.push(None)
    }
    let motor_joints : Map[String, Int32] = {}
    let motor_coords : Map[String, Int32] = {}
    let motor_dofs : Map[String, Int32] = {}
    for order, source_index in topology.joints {
      let joint = source.joints[source_index]
      let parent_path = joint.body0[0]
      let child_path = joint.body1[0]
      let xp = frame(joint.local_position0, joint.local_rotation0_wxyz)
      let xc = frame(joint.local_position1, joint.local_rotation1_wxyz)
      joint_paths.push(joint.path)
      joint_source_index.push(source_index)
      joint_world.push(world)
      joint_parent.push(base_body + topology.body_index[parent_path])
      joint_child.push(base_body + topology.body_index[child_path])
      joint_X_p.append(pose(xp))
      joint_X_c.append(pose(xc))
      joint_q_start.push(joint_q.length())
      joint_qd_start.push(joint_qd.length())
      joint_axis_start.push(joint_armature.length())
      let movement = if joint.kind == "revolute" {
        guard actuator_by_path.get(joint.path) is Some(motor) &&
          motor.joint_name == joint.name else {
          fail("joint does not match its canonical motor")
        }
        guard joint.limits
          is { "lower": lo, "upper": hi, "unit": String("degrees"), .. } else {
          fail("revolute joint requires explicit USD degree limits")
        }
        let lower = limit(lo)
        let upper = limit(hi)
        guard !(lo is String("+infinity")) && !(hi is String("-infinity")) else {
          fail("unsupported inverted infinite limit")
        }
        if lower is Some(a) && upper is Some(b) {
          guard a <= b else { fail("inverted revolute limits") }
        }
        let a = axis(joint.axis)
        motor_joints[joint.path] = base_joint + order + 1
        motor_coords[joint.path] = joint_q.length()
        motor_dofs[joint.path] = joint_qd.length()
        joint_type.push(1)
        joint_q.push(motor.default_position_radians)
        joint_qd.push(0.0)
        joint_axis.append([a.x, a.y, a.z])
        joint_armature.push(motor.armature)
        joint_target_ke.push(motor.stiffness)
        joint_target_kd.push(motor.damping)
        joint_effort_limit.push(motor.effort_limit)
        joint_velocity_limit.push(motor.velocity_limit)
        joint_limit_lower.push(lower)
        joint_limit_upper.push(upper)
        @geo.transform3(
          @geo.axis_angle_basis3(a, motor.default_position_radians),
          @geo.vec3(0, 0, 0),
        )
      } else {
        joint_type.push(3)
        identity
      }
      poses[child_path] = poses[parent_path]
        .compose(xp)
        .compose(movement)
        .compose(inverse(xc))
      ignore(checked_transform(poses[child_path]))
    }
    for source_index in topology.bodies {
      let body = source.bodies[source_index]
      body_paths.push(body.path)
      body_source_index.push(source_index)
      body_world.push(world)
      body_q.append(pose(poses[body.path]))
      body_qd.append([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
      body_mass_properties.push(mass_properties(body.mass_properties))
    }
    for motor in plan.actuators {
      guard motor_joints.contains(motor.joint_path) else {
        fail("canonical motor did not bind to a revolute joint")
      }
      canonical_joint_to_builder.push(motor_joints[motor.joint_path])
      canonical_coord_to_builder.push(motor_coords[motor.joint_path])
      canonical_dof_to_builder.push(motor_dofs[motor.joint_path])
    }
    articulation_end.push(joint_paths.length())
  }
  // Prefix arrays include a final sentinel, as finalized Newton model arrays do.
  joint_q_start.push(joint_q.length())
  joint_qd_start.push(joint_qd.length())
  joint_axis_start.push(joint_armature.length())
  let unresolved_semantics = source.unsupported_features.copy()
  unresolved_semantics.append([
    "IR source joint order is preserved within DFS; UsdPhysics parser descriptor order has not been differentially verified",
    "collision shapes, ground/world filtering, materials, mesh cooking and mass inference are not finalized",
    "Newton/Physx/Mjc extension precedence, mimic/equality constraints and solver-specific arrays are not finalized",
    "CPU Double reset FK is prepared; no float32 conversion, Warp device allocation, builder finalization or Newton model exists",
  ])
  {
    format: "moonrobo.aligned-prepared-tree-arrays.v1",
    body_paths,
    body_source_index,
    body_world,
    body_q,
    body_qd,
    body_mass_properties,
    joint_paths,
    joint_source_index,
    joint_world,
    joint_type,
    joint_parent,
    joint_child,
    joint_X_p,
    joint_X_c,
    joint_q_start,
    joint_qd_start,
    joint_q,
    joint_qd,
    joint_axis,
    joint_axis_start,
    joint_armature,
    joint_target_ke,
    joint_target_kd,
    joint_effort_limit,
    joint_velocity_limit,
    joint_limit_lower,
    joint_limit_upper,
    articulation_start,
    articulation_end,
    canonical_joint_to_builder,
    canonical_coord_to_builder,
    canonical_dof_to_builder,
    unresolved_semantics,
    mass_properties_complete: body_mass_properties.all(x => x is Some(_)),
    full_finalize_complete: false,
    newton_model_constructed: false,
    numerical_equivalence_verified: false,
  }
}
