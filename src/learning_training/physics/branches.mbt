///|
/// Restored physical counterfactual from counterfactual.py. Times remain parent elapsed times.
pub(all) struct BranchOrigin {
  integration : Array[Double]
  previous : Array[Double]
  goal : Array[Double]
  start_step : Int32
  parent_episode_id : String
}

///|
pub(all) struct BranchConfig {
  branch_steps : Int32
  pulse_steps : Int32
  dt : Double
  fall_height : Double
  fall_upright : Double
}

///|
pub fn branch_rollout(
  runtime : @native_physics.Runtime,
  origin : BranchOrigin,
  case : @native_physics.Case,
  predict : (Array[Double], Array[Double]) -> Array[Double],
  delta : Array[Double],
  config : BranchConfig,
  episode_id : String,
) -> (@native_physics.Episode, @native_physics.Trial) raise {
  guard config.branch_steps > 0 &&
    config.pulse_steps >= 0 &&
    delta.length() == origin.goal.length() else {
    fail("invalid physical branch")
  }
  let original = runtime.integration()
  defer (try! runtime.set_integration(original))
  runtime.set_integration(origin.integration)
  let substeps = runtime.control_substeps(config.dt)
  let (nq, _, _, _) = runtime.dimensions()
  let q_indices = runtime.q_indices()
  let steps : Array[@native_physics.Transition] = []
  let replay : Array[@native_physics.ReplayFrame] = []
  let mut previous = origin.previous
  let mut errors = 0.0
  let mut min_height = 1.0 / 0.0
  for i in 0..<config.branch_steps {
    let before = runtime.state()
    let obs = runtime.observation(previous)
    let request = predict(obs, origin.goal)
    let action = runtime.clip_control(
      Array::makei(request.length(), j => {
        request[j] + (if i < config.pulse_steps { delta[j] } else { 0.0 })
      }),
    )
    let after = runtime.step(action, substeps)
    let height = runtime.root_height()
    let upright = runtime.upright()
    let fallen = height < config.fall_height || upright < config.fall_upright
    let mut error = 0.0
    for j in 0..<origin.goal.length() {
      let d = after[q_indices[j]] - origin.goal[j]
      error += d * d / origin.goal.length().to_double()
    }
    errors += error
    if height < min_height {
      min_height = height
    }
    let time_s = (origin.start_step + i).to_double() * config.dt
    steps.push({
      time_s,
      state: before,
      observation: obs,
      applied_action: action,
      next_state: after,
      goal: origin.goal,
      reward: @math.exp(-error / 0.09),
      terminated: fallen,
      truncated: !fallen && i == config.branch_steps - 1,
    })
    replay.push({
      time_s: time_s + config.dt,
      qpos: Array::makei(nq, j => after[j]),
      target: origin.goal,
      root_height_m: height,
      upright_z: upright,
      contacts: runtime.contacts(),
    })
    previous = action
    if fallen {
      break
    }
  }
  let failed = steps[steps.length() - 1].terminated
  let episode : @native_physics.Episode = {
    id: episode_id,
    source_family: case.family,
    split: "train",
    context: [case.friction, 1.0],
    steps,
    case_id: case.id,
    reference_nominal_rad: origin.goal,
  }
  let trial : @native_physics.Trial = {
    episode_id,
    case_id: case.id,
    seed: 0,
    controller: "counterfactual",
    split: "train",
    steps: steps.length(),
    failed,
    joint_rmse_rad: (errors / steps.length().to_double()).sqrt(),
    min_root_height_m: min_height,
    simulated_seconds: steps.length().to_double() * config.dt,
    end_reason: if failed {
      "fall"
    } else {
      "branch_time_limit"
    },
    replay,
  }
  (episode, trial)
}

///|
/// Replay validation includes before/after state, observation and applied action.
pub fn unperturbed_replay_error(
  parent : @native_physics.Episode,
  start_step : Int32,
  branch : @native_physics.Episode,
) -> Double raise {
  guard start_step >= 0 &&
    start_step + branch.steps.length() <= parent.steps.length() else {
    fail("unperturbed branch length differs from parent")
  }
  let mut maximum = 0.0
  for i in 0..<branch.steps.length() {
    let a = parent.steps[start_step + i]
    let b = branch.steps[i]
    for
      (left, right) in [
        (a.state, b.state),
        (a.next_state, b.next_state),
        (a.observation, b.observation),
        (a.applied_action, b.applied_action),
      ] {
      guard left.length() == right.length() else {
        fail("unperturbed branch layout differs")
      }
      for j in 0..<left.length() {
        let difference = (left[j] - right[j]).abs()
        if difference > maximum {
          maximum = difference
        }
      }
    }
  }
  guard maximum <= 0.00000001 else {
    fail("unperturbed branch does not reproduce parent")
  }
  maximum
}
