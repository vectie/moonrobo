///|
pub(all) struct ReferenceFrame {
  state : Array[Double]
  integration : Array[Double]
  body_position : Array[Array[Double]]
  body_rotation : Array[Array[Double]]
  body_quaternion : Array[Array[Double]]
  contacts : Int32
  time : Double
} derive(Debug, ToJson, FromJson)

///|
pub fn capture_frame(
  runtime : @native_physics.Runtime,
  time : Double,
) -> ReferenceFrame raise {
  let ids = Array::makei(runtime.body_count() - 1, fn(i) { i + 1 })
  let quaternions = ids.map(fn(body) { runtime.body_world_quat(body) })
  {
    state: runtime.state(),
    integration: runtime.integration(),
    body_position: ids.map(fn(body) { runtime.body_world_pos(body) }),
    body_rotation: quaternions.map(fn(q) { @balance.quaternion_matrix(q) }),
    body_quaternion: quaternions,
    contacts: runtime.contacts(),
    time,
  }
}

///|
pub(all) struct NativeReference {
  frames : Array[ReferenceFrame]
  controls : Array[Array[Double]]
  observations : Array[Array[Double]]
  reference : @balance.FullBodyReference
  q_indices : Array[Int32]
  v_indices : Array[Int32]
  nq : Int32
  root_index : Int32
} derive(Debug)

///|
pub fn NativeReference::new(
  runtime : @native_physics.Runtime,
  frames : Array[ReferenceFrame],
  controls : Array[Array[Double]],
  observations : Array[Array[Double]],
  dt : Double,
) -> NativeReference raise {
  let (nq, _, _, nu) = runtime.dimensions()
  guard frames.length() >= 2 &&
    (
      observations.length() == controls.length() ||
      observations.length() == frames.length()
    ) &&
    controls.length() + 1 == frames.length() else {
    fail("reference needs T controls/observations and T+1 state frames")
  }
  guard controls.all(fn(row) { row.length() == nu }) else {
    fail("reference source control layout differs")
  }
  let q_indices = runtime.q_indices()
  let v_indices = runtime.v_indices()
  let root_index = runtime.root_body() - 1
  let goals = frames.map(fn(frame) {
    @balance.encode_goal(
      frame.state,
      frame.body_position,
      frame.body_rotation,
      q_indices,
      v_indices,
      nq,
      root_index,
    )
  })
  {
    frames,
    controls,
    observations,
    reference: @balance.FullBodyReference::new(
      goals,
      frames.map(fn(f) { f.time }),
      controls,
      dt,
    ),
    q_indices,
    v_indices,
    nq,
    root_index,
  }
}

///|
/// Source-setpoint, joint-position or callback-policy replay. Only the initial integration state is restored; target frames never overwrite subsequent physics states.
pub fn replay_reference(
  runtime : @native_physics.Runtime,
  reference : NativeReference,
  case : @native_physics.Case,
  start : Int32,
  mode : String,
  policy? : (Array[Double], Array[Double], Array[Array[Double]], Array[Bool]) -> Array[
    Double,
  ],
  preview_length~ : Int32 = 10,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> (@native_physics.Episode, Json) raise {
  let steps = reference.controls.length()
  guard start >= 0 &&
    start < steps &&
    ["source-setpoint", "joint-position", "policy"].contains(mode) &&
    (mode == "policy") == policy.is_some() else {
    fail("invalid reference replay mode, start or callback")
  }
  runtime.reset_data()
  runtime.set_friction(case.friction)
  runtime.set_integration(reference.frames[start].integration)
  let (_, nv, _, nu) = runtime.dimensions()
  let dt = reference.reference.dt
  let substeps = runtime.control_substeps(dt)
  let initial_obs = reference.observations[0]
  let mut previous = if start > 0 {
    reference.controls[start - 1].copy()
  } else {
    Array::makei(nu, fn(i) { initial_obs[initial_obs.length() - nu + i] })
  }
  let transitions : Array[@native_physics.Transition] = []
  let metric_sums : Map[String, Double] = {
    "joint_rmse_rad": 0.0,
    "body_position_rmse_m": 0.0,
    "root_position_rmse_m": 0.0,
    "root_orientation_rmse_rad": 0.0,
    "joint_speed_rmse_rad_per_s": 0.0,
    "root_linear_speed_rmse_m_per_s": 0.0,
    "root_angular_speed_rmse_rad_per_s": 0.0,
  }
  let mut maximum_state_error = 0.0
  let mut failed = false
  for i in start..<steps {
    let observation = if i == start {
      let obs = reference.observations[start].copy()
      for j in 0..<nu {
        obs[obs.length() - nu + j] = previous[j]
      }
      obs
    } else {
      runtime.observation(previous)
    }
    let before = runtime.state()
    let target = reference.frames[i + 1]
    let (preview, valid) = reference.reference.preview(i, length=preview_length)
    let requested = match mode {
      "source-setpoint" => reference.controls[i]
      "joint-position" => reference.q_indices.map(fn(j) { target.state[j] })
      _ =>
        policy.unwrap()(
          observation.copy(),
          reference.reference.goals[i].copy(),
          preview,
          valid,
        )
    }
    guard requested.length() == nu &&
      requested.all(fn(v) { @numeric.finite(v) }) else {
      fail("reference policy must return finite setpoints")
    }
    let action = runtime.clip_control(requested)
    let after = runtime.step(action, substeps)
    for j in 0..<after.length() {
      maximum_state_error = @balance.clip(
        (after[j] - target.state[j]).abs(),
        maximum_state_error,
        1.0 / 0.0,
      )
    }
    let mut q_error = 0.0
    for j in reference.q_indices {
      let d = after[j] - target.state[j]
      q_error += d * d / nu.to_double()
    }
    let mut body_error = 0.0
    let mut root_error = 0.0
    for body in 0..<target.body_position.length() {
      let actual = runtime.body_world_pos(body + 1)
      let mut squared = 0.0
      for j in 0..<3 {
        let d = actual[j] - target.body_position[body][j]
        squared += d * d
      }
      body_error += squared / target.body_position.length().to_double()
      if body == reference.root_index {
        root_error = squared
      }
    }
    let actual_rotation = @balance.quaternion_matrix(
      runtime.body_world_quat(reference.root_index + 1),
    )
    let relative = @balance.matmul(
      target.body_rotation[reference.root_index],
      @balance.transpose(actual_rotation),
    )
    let cosine = @balance.clip(
      (relative[0] + relative[4] + relative[8] - 1.0) / 2.0,
      -1.0,
      1.0,
    )
    let angle = @math.acos(cosine)
    let speed_error = Array::makei(nv, fn(j) {
      let d = after[reference.nq + j] - target.state[reference.nq + j]
      d * d
    })
    let mut joint_speed_error = 0.0
    for j in reference.v_indices {
      joint_speed_error += speed_error[j] / nu.to_double()
    }
    metric_sums["joint_rmse_rad"] += q_error
    metric_sums["body_position_rmse_m"] += body_error
    metric_sums["root_position_rmse_m"] += root_error
    metric_sums["root_orientation_rmse_rad"] += angle * angle
    metric_sums["joint_speed_rmse_rad_per_s"] += joint_speed_error
    metric_sums["root_linear_speed_rmse_m_per_s"] += (
        speed_error[0] + speed_error[1] + speed_error[2]
      ) /
      3.0
    metric_sums["root_angular_speed_rmse_rad_per_s"] += (
        speed_error[3] + speed_error[4] + speed_error[5]
      ) /
      3.0
    failed = runtime.root_height() < fall_height ||
      runtime.upright() < fall_upright
    transitions.push({
      time_s: (i - start).to_double() * dt,
      state: before,
      observation,
      applied_action: action,
      next_state: after,
      goal: preview[0],
      reward: @math.exp(-body_error / 0.09),
      terminated: failed,
      truncated: !failed && i == steps - 1,
    })
    previous = action
    if failed {
      break
    }
  }
  let ident = case.id + "-reference-" + mode + "-start-" + start.to_string()
  let episode : @native_physics.Episode = {
    id: ident,
    source_family: case.family,
    split: case.split,
    context: [case.friction, 1.0],
    steps: transitions,
    case_id: case.id,
    reference_nominal_rad: reference.q_indices.map(fn(i) {
      reference.frames[start].state[i]
    }),
  }
  let fields : Map[String, Json] = {
    "episode_id": ident.to_json(),
    "case_id": case.id.to_json(),
    "controller": mode.to_json(),
    "reference_start_step": start.to_json(),
    "steps": transitions.length().to_json(),
    "failed": failed.to_json(),
    "simulated_seconds": (transitions.length().to_double() * dt).to_json(),
    "requested_seconds": ((steps - start).to_double() * dt).to_json(),
    "max_state_component_error": maximum_state_error.to_json(),
  }
  for name, value in metric_sums {
    fields[name] = (value / transitions.length().to_double()).sqrt().to_json()
  }
  (episode, Json::object(fields))
}
