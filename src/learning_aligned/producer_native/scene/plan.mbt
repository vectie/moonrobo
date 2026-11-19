///|
/// Decode the real native USD schema extraction. Unknown Newton/Physx/Mjc
/// properties remain in the IR and are not treated as portable physics.
pub fn articulation_ir(receipt : Json) -> ArticulationIR raise {
  guard receipt
    is {
      "format": String("moonrobo.aligned-native-usd-receipt.v1"),
      "metadata": { "articulation_ir": ir, .. },
      ..
    } else {
    fail("native USD articulation receipt is required")
  }
  let source : ArticulationIR = @json.from_json(ir)
  guard source.format == "moonrobo.aligned-usd-articulation-ir.v1" else {
    fail("unsupported USD articulation IR format")
  }
  guard source.root != "" && source.bodies.length() > 0 else {
    fail("USD articulation must have a root and rigid bodies")
  }
  source
}

///|
/// Fixed G1 first-party configuration expressed in MoonBit. This binds canonical
/// motor names to actual USD joint paths; it does not claim Newton array order,
/// automatic inertia, resolver precedence or a finalized native solver model.
pub fn g1_plan(
  receipt : Json,
  num_envs : Int32,
  self_collisions : Bool,
) -> ScenePlan raise {
  guard num_envs > 0 && num_envs <= 1000000 else {
    fail("G1 scene environment count outside supported bounds")
  }
  let source = articulation_ir(receipt)
  guard source.up_axis == "Z" &&
    source.meters_per_unit == 1.0 &&
    source.kilograms_per_unit == 1.0 else {
    fail("fixed G1 recipe currently requires Z-up metre/kilogram USD assets")
  }
  let body_paths : Map[String, Unit] = {}
  for body in source.bodies {
    guard !body_paths.contains(body.path) &&
      body.path != "" &&
      body.world_transform.length() == 16 &&
      body.velocity.length() == 3 &&
      body.angular_velocity_degrees.length() == 3 else {
      fail("invalid or duplicate USD rigid body")
    }
    body_paths[body.path] = ()
  }
  let names = @aligned.joint_names()
  let positions = @aligned.default_joint_positions()
  let canonical : Map[String, Joint] = {}
  for joint in source.joints {
    guard joint.body0.length() <= 1 &&
      joint.body1.length() <= 1 &&
      joint.local_position0.length() == 3 &&
      joint.local_position1.length() == 3 &&
      joint.local_rotation0_wxyz.length() == 4 &&
      joint.local_rotation1_wxyz.length() == 4 else {
      fail("USD joint endpoint or frame dimensions are invalid: " + joint.name)
    }
    for endpoint in joint.body0 + joint.body1 {
      guard body_paths.contains(endpoint) else {
        fail(
          "USD joint references a body outside the extracted root: " + endpoint,
        )
      }
    }
    if !joint.enabled || joint.excluded_from_articulation {
      continue
    }
    guard joint.kind == "fixed" || joint.kind == "revolute" else {
      fail("G1 fixed recipe cannot represent joint kind: " + joint.kind)
    }
    if joint.kind == "fixed" {
      continue
    }
    guard names.contains(joint.name) &&
      !canonical.contains(joint.name) &&
      joint.body0.length() == 1 &&
      joint.body1.length() == 1 &&
      (joint.axis == "X" || joint.axis == "Y" || joint.axis == "Z") else {
      fail("G1 revolute joint name/axis/body mapping differs: " + joint.name)
    }
    canonical[joint.name] = joint
  }
  guard canonical.length() == names.length() else {
    fail("USD does not expose exactly the 29 canonical enabled G1 joints")
  }
  let actuators : Array[Actuator] = []
  let motors : Array[Json] = []
  let defaults : Array[Json] = []
  for index, name in names {
    let motor = @aligned.motor_of(name)
    let actuator_name = name.replace(old="_joint", new="")
    actuators.push({
      name: actuator_name,
      joint_name: name,
      joint_path: canonical[name].path,
      joint_index: index,
      default_position_radians: positions[index],
      default_velocity_radians: 0.0,
      effort_limit: motor.effort,
      velocity_limit: motor.velocity,
      stiffness: motor.stiffness(),
      damping: motor.damping(),
      armature: motor.armature,
      action_scale: motor.action_scale(),
    })
    motors.push({
      "name": Json(name),
      "actuator_name": Json(actuator_name),
      "effort": Json(motor.effort),
      "velocity": Json(motor.velocity),
      "stiffness": Json(motor.stiffness()),
      "damping": Json(motor.damping()),
      "armature": Json(motor.armature),
      "action_scale": Json(motor.action_scale()),
    })
    defaults.push({
      "name": Json(name),
      "position": Json(positions[index]),
      "velocity": 0.0,
    })
  }
  let recipe : Json = {
    "format": "moonrobo.aligned-fixed-g1-scene-recipe.v1",
    "root_pose": {
      "position": [0.0, 0.0, 0.76],
      "quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
    },
    "root_joint_defaults": Json(defaults),
    "motors": Json(motors),
    "robot": {
      "prim_path": "{ENV_REGEX_NS}/Robot",
      "soft_joint_pos_limit_factor": 0.9,
      "activate_contact_sensors": false,
      "disable_gravity": false,
      "linear_damping": 0.0,
      "angular_damping": 0.0,
      "self_collisions": Json(self_collisions),
    },
    "scene": {
      "num_envs": Json(num_envs),
      "env_spacing": 0.0,
      "replicate_physics": true,
    },
    "solver": {
      "control_dt_s": 0.02,
      "physics_dt_s": 0.005,
      "num_substeps": 4,
      "njmax": 500,
      "nconmax": 128,
      "cone": "pyramidal",
      "integrator": "implicitfast",
      "use_mujoco_contacts": true,
      "use_cuda_graph": false,
    },
    "ground": {
      "prim_path": "/World/ground",
      "upstream_cfg": "GroundPlaneCfg",
      "overrides": {},
    },
    "origin_policy": "zero spacing gives coincident environment origins; independent world collision groups remain an upstream builder responsibility",
    "source_joint_order": "USD traversal; actuators use canonical order; finalized SDK order must still be checked",
    "native_builder_ready": false,
  }
  {
    format: "moonrobo.aligned-fixed-g1-scene-plan.v1",
    source,
    canonical_joint_names: names,
    actuators,
    recipe,
    sdk_revision_pins: {
      "isaaclab": "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed",
      "newton": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
      "warp": "1.17.0",
      "mujoco_warp": "3.15.0",
    },
    newton_model_constructed: false,
    physical_equivalence_verified: false,
  }
}
