///|
priv struct Config {
  adapter : @adapter.Settings
  joint_calibration : @mapping.Calibration
  imu_calibration : @mapping.ImuCalibration
  maximum_policy_ms : Int32
  approach_ms : Int32
} derive(FromJson)

///|
priv struct Pose {
  names : Array[String]
  q : Array[Double]
} derive(FromJson)

///|
async fn main {
  guard @env.args()[1:]
    is [bundle_path, ref_path, config_path, pose_path, library, scene, report] else {
    fail(
      "usage: BUNDLE REFERENCE CONFIG SAVED_POSE MUJOCO_LIBRARY SUSPENDED_SCENE NEW_REPORT",
    )
  }
  guard !@fs.exists(report) else { fail("simulation report exists") }
  let bundle = @actor.Bundle::read(bundle_path)
  let actor = @actor.Actor::reference(
    bundle,
    @fs.read_file(bundle_path + "/parameters.f32").binary()[:],
  )
  defer (actor.close() catch { _ => () })
  let clip = @reference.Clip::read(bundle, ref_path)
  let config : Config = @json.from_json(@fs.read_file(config_path).json())
  let pose : Pose = @json.from_json(@fs.read_file(pose_path).json())
  assert_eq(pose.names, bundle.joints()[:].to_owned())
  assert_eq(pose.q.length(), 23)
  let mapping = @mapping.Mapping::new(bundle, config.joint_calibration, resolve=name => {
    for axis in config.joint_calibration.axes {
      if axis.sdk_joint == name {
        return axis.motor_id
      }
    }
    for axis in config.joint_calibration.fixed {
      if axis.sdk_joint == name {
        return axis.motor_id
      }
    }
    fail("unmapped simulated SDK slot")
  })
  let hold : Array[@low.MotorCommand] = Array::makei(24, i => {
    position: 0.0,
    velocity: 0.0,
    torque: 0.0,
    kp: if i == 23 {
      0.0
    } else {
      50.0
    },
    kd: if i == 9 || i == 10 || i == 20 || i == 21 {
      1.0
    } else {
      5.0
    },
  })
  for axis in config.joint_calibration.axes {
    let index = bundle.joints().search_by(j => j == axis.actor_joint).unwrap()
    hold[axis.motor_id] = {
      ..hold[axis.motor_id],
      position: axis.zero + axis.direction * pose.q[index],
    }
  }
  let control = @adapter.Adapter::new(config.adapter, hold[:])
  let rt = @physics.Runtime::open(library, scene)
  assert_eq(rt.joint_names(), pose.names)
  let (nq, nv, _) = (rt.dimensions().0, rt.dimensions().1, rt.dimensions().2)
  let qi = rt.q_indices()
  let vi = rt.v_indices()
  let arms = rt.joint_armatures()
  let (_, effort) = rt.actuator_force_bounds()
  for i, axis in config.joint_calibration.axes {
    rt.configure_joint_actuator(
      axis.actor_joint,
      50.0,
      if axis.motor_id == 9 ||
        axis.motor_id == 10 ||
        axis.motor_id == 20 ||
        axis.motor_id == 21 {
        1.0
      } else {
        5.0
      },
      effort[i],
      arms[i],
    )
  }
  let state = rt.state()
  for i in 0..<nv {
    state[nq + i] = 0.0
  }
  for i in 0..<23 {
    state[qi[i]] = pose.q[i]
  }
  rt.set_recorded_state(state, pose.q.copy())
  let encoder = bundle.smc_observation()
  let imu = @mapping.Imu::new(config.imu_calibration)
  let root = rt.root_body_index()
  let alignment = @reference.heading_alignment(
    rt.body_rotations()[root][:],
    clip.frame(
      {
        request_id: "sim",
        sequence: 0L,
        skill_id: "sim",
        reference_id: clip.reference_id(),
        parameters: {},
        state: Running,
        accepted_at_ms: 0L,
        deadline_ms: 0L,
        detail: "suspended closed-loop validation",
      },
      0,
    ).body_to_world[:],
  )
  let execution : @skills.Execution = {
    request_id: "sim",
    sequence: 0L,
    skill_id: "sim",
    reference_id: clip.reference_id(),
    parameters: {},
    state: Running,
    accepted_at_ms: 0L,
    deadline_ms: 0L,
    detail: "suspended closed-loop validation",
  }
  let history : Array[Array[Double]] = []
  let mut previous = mapping.actions_for_commands(hold[:])
  let reference_duration = clip
    .duration_ms()
    .min(config.maximum_policy_ms.to_int64())
  let duration = reference_duration + config.approach_ms.to_int64()
  let mut ticks = 0
  let mut policy_ticks = 0
  let limited = [0, 0]
  let bounded = [0, 0]
  let raw_min = [1.0e100, 1.0e100]
  let raw_max = [-1.0e100, -1.0e100]
  let command_min = [hold[3].position, hold[14].position]
  let command_max = command_min.copy()
  let measured_min = [pose.q[16], pose.q[21]]
  let measured_max = measured_min.copy()
  let mut max_leg_change = 0.0
  let mut max_counterfactual_difference = 0.0
  let mut max_applied_counterfactual_difference = 0.0
  let mut completed = false
  for tick in 0..<6000 {
    let now = tick.to_int64() * 20L
    let policy_elapsed = (now - 1000L).max(0L)
    let phase = if now < 1000L {
      "baseline"
    } else if policy_elapsed <= duration {
      "policy"
    } else {
      "return"
    }
    let step = ((policy_elapsed - config.approach_ms.to_int64())
    .max(0L)
    .min(reference_duration) /
    20L).to_int()
    let frame = clip.frame(execution, step)
    let current = rt.state()
    assert_true(current.all(x => x - x == 0.0))
    let q = Array::makei(23, i => current[qi[i]])
    let qd = Array::makei(23, i => current[nq + vi[i]])
    let quat = rt.body_world_quat(root)
    let world_velocity = rt.body_object_velocity_world(root)
    let rotation = rt.body_rotations()[root]
    let gyro = Array::makei(3, i => {
      rotation[i] * world_velocity[0] +
      rotation[3 + i] * world_velocity[1] +
      rotation[6 + i] * world_velocity[2]
    })
    let attitude = imu.decode(
      [quat[1], quat[2], quat[3], quat[0]],
      gyro[:],
      @reference.align_heading(alignment[:], frame.body_to_world[:])[:],
    )
    let observation = encoder.encode(
      q[:],
      qd[:],
      previous[:],
      attitude.body_gyro()[:],
      attitude.gravity()[:],
      attitude.reference_orientation()[:],
    )
    if history.is_empty() {
      for _ in 0..<bundle.history_frames() {
        history.push(observation.copy())
      }
    } else {
      ignore(history.remove(0))
      history.push(observation)
    }
    let raw = actor.forward_embedded(history, frame.goals)
    if phase == "policy" && tick % 100 == 0 {
      let alternative = history.map(row => row.copy())
      alternative[alternative.length() - 1][16] += 0.01
      let other = actor.forward_embedded(alternative, frame.goals)
      for index in [16, 21] {
        max_counterfactual_difference = max_counterfactual_difference.max(
          (raw[index] - other[index]).abs(),
        )
      }
      let original_proposal = control.preview(
        mapping.commands(raw[:])[:],
        now,
        policy_elapsed,
        phase,
      )
      let other_proposal = control.preview(
        mapping.commands(other[:])[:],
        now,
        policy_elapsed,
        phase,
      )
      for slot in [3, 14] {
        max_applied_counterfactual_difference = max_applied_counterfactual_difference.max(
          (original_proposal.commands[slot].position -
          other_proposal.commands[slot].position).abs(),
        )
      }
    }
    let applied = control.next(
      mapping.commands(raw[:])[:],
      now,
      policy_elapsed,
      phase,
    )
    previous = mapping.actions_for_commands(applied.commands[:])
    let target = bundle.nominal_setpoints(previous[:])
    for axis in config.joint_calibration.axes {
      if axis.motor_id != 3 && axis.motor_id != 14 {
        assert_eq(
          applied.commands[axis.motor_id].position,
          hold[axis.motor_id].position,
        )
        let index = pose.names.search_by(j => j == axis.actor_joint).unwrap()
        max_leg_change = if (axis.motor_id >= 5 && axis.motor_id <= 10) ||
          (axis.motor_id >= 16 && axis.motor_id <= 21) {
          max_leg_change.max((q[index] - pose.q[index]).abs())
        } else {
          max_leg_change
        }
      }
    }
    for i, index in [16, 21] {
      measured_min[i] = measured_min[i].min(q[index])
      measured_max[i] = measured_max[i].max(q[index])
      let value = applied.commands[if i == 0 { 3 } else { 14 }].position
      command_min[i] = command_min[i].min(value)
      command_max[i] = command_max[i].max(value)
      if phase == "policy" {
        raw_min[i] = raw_min[i].min(applied.raw_elbow_rad[i])
        raw_max[i] = raw_max[i].max(applied.raw_elbow_rad[i])
        if applied.rate_limited[i] {
          limited[i] += 1
        }
        if applied.requested_elbow_rad[i] != applied.bounded_elbow_rad[i] {
          bounded[i] += 1
        }
      }
    }
    if phase == "policy" {
      policy_ticks += 1
    }
    ticks += 1
    ignore(rt.step(target, rt.control_substeps(0.02)))
    if phase == "return" && control.returned() {
      completed = true
      break
    }
  }
  assert_true(completed)
  assert_true(policy_ticks > 0)
  assert_true(max_counterfactual_difference > 1.0e-8)
  assert_true(max_applied_counterfactual_difference > 1.0e-8)
  assert_true(rt.root_height() > 0.5)
  let report_value : Json = {
    "passed": true,
    "backend": "frozen LunaKine CPU reference with real MuJoCo feedback",
    "mujoco_version": rt.version(),
    "ticks": Json(ticks),
    "policy_ticks": Json(policy_ticks),
    "fixed_motor_records": 22,
    "max_fixed_target_change": 0,
    "target_positions_returned_exactly": true,
    "maximum_raw_action_sensor_sensitivity": Json(max_counterfactual_difference),
    "maximum_applied_command_sensor_sensitivity_rad": Json(
      max_applied_counterfactual_difference,
    ),
    "policy_authority": Json(config.adapter.policy_authority),
    "policy_raw_elbow_range_rad": {
      "minimum": Json(raw_min),
      "maximum": Json(raw_max),
    },
    "command_elbow_range_rad": {
      "minimum": Json(command_min),
      "maximum": Json(command_max),
    },
    "measured_elbow_range_rad": {
      "minimum": Json(measured_min),
      "maximum": Json(measured_max),
    },
    "rate_limited_policy_ticks": Json(limited),
    "position_bounded_policy_ticks": Json(bounded),
    "max_measured_leg_displacement_rad": Json(max_leg_change),
    "physical_control_qualified": false,
    "assumptions": "Root welded to world to approximate weight-bearing crane; saved initial physical joint readings; supplied scene force bounds and inertia; PD gains match commissioning. This does not identify firmware torque limits or certify whole-body calibration.",
  }
  @fs.write_file(
    report,
    report_value.stringify(indent=2),
    create_mode=CreateNew,
  )
  println(report_value.stringify(indent=2))
}
