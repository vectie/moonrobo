///|
pub(all) struct Origin {
  integration : Array[Double]
  previous : Array[Double]
  goal : Array[Double]
  context : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct PhysicalOutcome {
  reward_return : Double
  bootstrapped_return : Double
  critic_tail : Double
  failed : Bool
  steps : Int32
} derive(Debug, ToJson, FromJson)

///|
/// Restores all MuJoCo integration fields, then replays clipped applied controls.
pub fn physical_rollout(
  runtime : @physics.Runtime,
  integration : Array[Double],
  actions : Array[Array[Double]],
  substeps : Int32,
  xy_shift? : (Double, Double),
) -> Array[Array[Double]] raise {
  let original = runtime.integration()
  defer (try! runtime.set_integration(original))
  runtime.set_integration(integration)
  if xy_shift is Some((x, y)) {
    runtime.shift_xy(x, y)
  }
  let states : Array[Array[Double]] = []
  for action in actions {
    states.push(runtime.step(action, substeps))
  }
  states
}

///|
/// Closed-loop actor-parameter probe against actual native physics.
pub fn physical_window(
  runtime : @physics.Runtime,
  origin : Origin,
  actor : (Array[Double], Array[Double]) -> Array[Double],
  critic : (Array[Double], Array[Double], Array[Double]) -> Double,
  horizon : Int32,
  dt : Double,
  gamma : Double,
  target_height : Double,
  fall_height : Double,
  fall_upright : Double,
  bootstrap~ : Bool = true,
) -> (PhysicalOutcome, Array[Array[Double]], Array[Array[Double]]) raise {
  if horizon < 1 || origin.context.is_empty() {
    raise Invalid("invalid physical window")
  }
  let original = runtime.integration()
  defer (try! runtime.set_integration(original))
  runtime.set_friction(origin.context[0])
  runtime.set_integration(origin.integration)
  let substeps = runtime.control_substeps(dt)
  let mut previous = origin.previous.copy()
  let mut total = 0.0
  let mut survival = 1.0
  let mut discount = 1.0
  let mut failed = false
  let states : Array[Array[Double]] = []
  let actions : Array[Array[Double]] = []
  for _ in 0..<horizon {
    let observation = runtime.observation(previous)
    let action = runtime.clip_control(actor(observation, origin.goal))
    let state = runtime.step(action, substeps)
    let (reward, continuation) = step_reward(
      state,
      action,
      previous,
      origin.goal,
      runtime.q_indices(),
      target_height,
    )
    total += discount * survival * reward
    survival *= continuation
    discount *= gamma
    states.push(state)
    actions.push(action)
    previous = action.copy()
    failed = runtime.root_height() < fall_height ||
      runtime.upright() < fall_upright
    if failed {
      survival = 0
      break
    }
  }
  let tail = if bootstrap {
    discount *
    survival *
    critic(states[states.length() - 1], origin.goal, origin.context)
  } else {
    0.0
  }
  (
    {
      reward_return: total,
      bootstrapped_return: total + tail,
      critic_tail: tail,
      failed,
      steps: states.length(),
    },
    states,
    actions,
  )
}

///|
/// Normalized centered finite differences use the same clipped physical actions.
pub fn physical_direction(
  runtime : @physics.Runtime,
  integration : Array[Double],
  actions : Array[Array[Double]],
  direction : Array[Array[Double]],
  epsilon : Double,
  substeps : Int32,
  objective : (Array[Array[Double]], Array[Array[Double]]) -> Double,
) -> Double raise {
  if epsilon <= 0 || direction.length() != actions.length() {
    raise Invalid("invalid physical perturbation")
  }
  let returns : Array[Double] = []
  for sign in [1.0, -1.0] {
    let perturbed : Array[Array[Double]] = []
    for t, action in actions {
      require_width(action, direction[t])
      perturbed.push(
        runtime.clip_control(
          Array::makei(action.length(), i => {
            action[i] + sign * epsilon * direction[t][i]
          }),
        ),
      )
    }
    let states = physical_rollout(runtime, integration, perturbed, substeps)
    returns.push(objective(states, perturbed))
  }
  (returns[0] - returns[1]) / (2 * epsilon)
}
