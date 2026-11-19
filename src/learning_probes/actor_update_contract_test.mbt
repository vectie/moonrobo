///|
/// Exact toy contract from test_actor_update_probe.py. The actor owns one
/// parameter and a separate immutable normalization buffer; dynamics adds the
/// action at state[7], and the critic returns 20 * state[7].
struct ToyActor {
  parameters : Array[Double]
  normalization : Double
}

///|
struct ToyRolloutSettings {
  horizon : Int32
  gamma : Double
  target_height : Double
  actor_learning_rate : Double
  actor_critic_bootstrap : Bool?
}

///|
fn toy_imagined_rollout(
  parameters : Array[Double],
  config : ToyRolloutSettings,
  bootstrap : Bool,
) -> (Double, Array[Double]) {
  let tape = @numeric.Tape::new()
  let bound = tape.vector(parameters)
  let initial = Array::make(14, 0.0)
  initial[2] = 0.8
  initial[3] = 1
  let mut state = tape.vector(initial)
  let mut previous = [tape.scalar(0)]
  let goal = [tape.scalar(0)]
  let mut survival = tape.scalar(1)
  let mut objective = tape.scalar(0)
  let mut discount = 1.0
  for _ in 0..<config.horizon {
    let action = [bound[0]]
    state = Array::makei(state.length(), i => {
      if i == 7 {
        tape.add(state[i], action[0])
      } else {
        state[i]
      }
    })
    let (reward, continuation) = @training.step_reward(
      tape,
      state,
      action,
      previous,
      goal,
      [7],
      config.target_height,
    )
    objective = tape.add(
      objective,
      tape.scale(tape.mul(survival, reward), discount),
    )
    survival = tape.mul(survival, continuation)
    previous = action
    discount *= config.gamma
  }
  if bootstrap {
    objective = tape.add(
      objective,
      tape.scale(tape.mul(survival, tape.scale(state[7], 20)), discount),
    )
  }
  tape.backward(objective)
  (objective.value, bound.map(v => tape.gradient(v)))
}

///|
fn toy_scaled_actor(
  actor : ToyActor,
  delta : Array[Double],
  multiplier : Double,
) -> ToyActor raise {
  {
    parameters: @learning_probes.scaled_actor(
      actor.parameters,
      delta,
      multiplier,
    ),
    normalization: actor.normalization,
  }
}

///|
test "actual Adam actor update preserves buffers and follows ascent with and without critic tail" {
  let actor : ToyActor = { parameters: [0.01], normalization: 2.0, }
  let config : ToyRolloutSettings = {
    horizon: 4,
    gamma: 0.9,
    target_height: 0.8,
    actor_learning_rate: 0.001,
    actor_critic_bootstrap: None,
  }
  let update = @learning_probes.adam_direction(
    actor.parameters,
    p => toy_imagined_rollout(p, config, true),
    config.actor_learning_rate,
    config.horizon,
  )
  assert_true(update.gradient_norm > 0)
  assert_true(update.delta[0] > 0)
  for multiplier in [-1.0, 0.0, 1.0] {
    let candidate = toy_scaled_actor(actor, update.delta, multiplier)
    let value = toy_imagined_rollout(candidate.parameters, config, true).0
    if multiplier != 0 {
      assert_true((value - update.objective_before) * multiplier > 0)
    } else {
      assert_eq(value, update.objective_before)
    }
    assert_eq(candidate.normalization, 2.0)
  }
  assert_true((actor.parameters[0] - 0.01).abs() < 0.000000001)
  let no_tail = @learning_probes.adam_direction(
    actor.parameters,
    p => toy_imagined_rollout(p, config, false),
    config.actor_learning_rate,
    config.horizon,
  )
  assert_true(no_tail.delta[0] < 0)
  let candidate = toy_scaled_actor(actor, update.delta, 1)
  let (reward_change, bootstrapped_change) = @learning_probes.predicted_changes(
    actor.parameters,
    candidate.parameters,
    (p, bootstrap) => toy_imagined_rollout(p, config, bootstrap).0,
  )
  assert_true(bootstrapped_change > 0)
  assert_true(reward_change < 0)
  assert_eq(config.actor_critic_bootstrap, None)
}
