///|
pub(all) struct ActorStart {
  state : Array[Double]
  previous : Array[Double]
  goal : Array[Double]
  context : Array[Double]
} derive(Debug)

///|
pub struct ActorUpdate {
  loss : Double
  objective : Double
  gradient_norm : Double
} derive(Debug)

///|
/// Full pathwise actor gradient through frozen world-model and critic parameter values.
/// Only actor parameters are passed to Adam, preserving frozen model/value weights.
pub fn imagined_actor_update(
  dynamics : Dynamics,
  actor : Actor,
  critic : Critic,
  optimizer : @numeric.Adam,
  starts : Array[ActorStart],
  config : RolloutConfig,
) -> ActorUpdate {
  let tape = @numeric.Tape::new()
  let dynamics_bound = dynamics.network.bind(tape)
  let actor_bound = actor.network.bind(tape)
  let critic_bound = critic.network.bind(tape)
  let objectives = starts.map(start => {
    imagined_rollout(
      dynamics,
      actor,
      critic,
      tape,
      dynamics_bound,
      actor_bound,
      critic_bound,
      tape.vector(start.state),
      tape.vector(start.previous),
      tape.vector(start.goal),
      tape.vector(start.context),
      config,
    ).objective
  })
  let objective = tape.mean(objectives)
  let loss = tape.scale(objective, -1.0 / config.horizon.to_double())
  guard @numeric.finite(loss.value) else {
    abort("nonfinite imagined policy objective")
  }
  tape.backward(loss)
  let norm = optimizer.step(actor.network.parameters, tape, actor_bound)
  { loss: loss.value, objective: objective.value, gradient_norm: norm, }
}

///|
pub(all) struct ValuePoint {
  state : Array[Double]
  goal : Array[Double]
  context : Array[Double]
  target : Double
} derive(Debug)

///|
pub fn Critic::update(
  self : Critic,
  optimizer : @numeric.Adam,
  points : Array[ValuePoint],
) -> Double {
  let tape = @numeric.Tape::new()
  let bound = self.network.bind(tape)
  let errors = points.map(p => {
    let value = self.forward(
      tape,
      bound,
      tape.vector(p.state),
      tape.vector(p.goal),
      tape.vector(p.context),
    )
    let error = tape.sub(value, tape.scalar(p.target))
    tape.mul(error, error)
  })
  let loss = tape.mean(errors)
  guard @numeric.finite(loss.value) else { abort("nonfinite critic loss") }
  tape.backward(loss)
  ignore(optimizer.step(self.network.parameters, tape, bound))
  loss.value
}

///|
/// Freeze actor/model during GAE target generation; retain time-limit value bootstrap.
pub fn imagined_value_points(
  dynamics : Dynamics,
  actor : Actor,
  critic : Critic,
  starts : Array[ActorStart],
  config : RolloutConfig,
  lam : Double,
) -> Array[ValuePoint] {
  let points = []
  for start in starts {
    let tape = @numeric.Tape::new()
    let rollout = imagined_rollout(
      dynamics,
      actor,
      critic,
      tape,
      dynamics.network.bind(tape),
      actor.network.bind(tape),
      critic.network.bind(tape),
      tape.vector(start.state),
      tape.vector(start.previous),
      tape.vector(start.goal),
      tape.vector(start.context),
      config,
    )
    let states = rollout.states.map(row => row.map(v => v.value))
    let values = states.map(state => {
      critic.predict(state, start.goal, start.context)
    })
    let targets = gae_targets(
      values,
      rollout.rewards.map(v => v.value),
      rollout.continuations.map(v => v.value),
      config.gamma,
      lam,
    )
    for t in 0..<targets.length() {
      points.push({
        state: states[t],
        goal: start.goal,
        context: start.context,
        target: targets[t],
      })
    }
  }
  points
}

///|
/// Actual physics returns calibrated on pre-transition state and next-state reward.
pub fn physical_value_points(
  actor : Actor,
  critic : Critic,
  episodes : Array[Episode],
  gamma : Double,
  target_height : Double,
) -> Array[ValuePoint] {
  let points = []
  for episode in episodes {
    guard episode.split == "train" && episode.steps.length() > 0 else {
      abort("physics critic requires nonempty train episode")
    }
    let rewards = []
    let continuations = []
    for step in episode.steps {
      let na = step.applied_action.length()
      let previous = Array::makei(na, j => {
        step.observation[step.observation.length() - na + j]
      })
      let tape = @numeric.Tape::new()
      let (reward, continuation) = step_reward(
        tape,
        tape.vector(step.next_state),
        tape.vector(step.applied_action),
        tape.vector(previous),
        tape.vector(step.goal),
        actor.body.q_indices,
        target_height,
      )
      rewards.push(reward.value)
      continuations.push(continuation.value)
    }
    let last = episode.steps[episode.steps.length() - 1]
    let tail = if last.truncated {
      critic.predict(last.next_state, last.goal, episode.context)
    } else {
      0.0
    }
    let targets = physical_return_targets(
      rewards,
      continuations,
      episode.steps.map(s => s.terminated),
      tail,
      gamma,
    )
    for t in 0..<targets.length() {
      points.push({
        state: episode.steps[t].state,
        goal: episode.steps[t].goal,
        context: episode.context,
        target: targets[t],
      })
    }
  }
  points
}

///|
/// Turn actual on-policy collection into PPO samples with stored Gaussian latents.
pub fn ppo_samples(
  actor : Actor,
  critic : Critic,
  episodes : Array[Episode],
  latents : Array[Array[Double]],
  gamma : Double,
  lam : Double,
  raw_action_std : Double,
  target_height : Double,
) -> Array[PPOSample] {
  let steps = []
  let contexts = []
  for episode in episodes {
    guard episode.split == "train" else {
      abort("PPO cannot consume held-out episodes")
    }
    steps.append(episode.steps)
    for _ in episode.steps {
      contexts.push(episode.context)
    }
  }
  guard steps.length() == latents.length() else {
    abort("PPO latent count differs from collected transitions")
  }
  let rewards = []
  let values = []
  let next_values = []
  let probabilities = []
  for i in 0..<steps.length() {
    let s = steps[i]
    let tape = @numeric.Tape::new()
    let na = s.applied_action.length()
    let previous = Array::makei(na, j => {
      s.observation[s.observation.length() - na + j]
    })
    let (reward, _) = step_reward(
      tape,
      tape.vector(s.next_state),
      tape.vector(s.applied_action),
      tape.vector(previous),
      tape.vector(s.goal),
      actor.body.q_indices,
      target_height,
    )
    rewards.push(reward.value)
    values.push(critic.predict(s.state, s.goal, contexts[i]))
    next_values.push(critic.predict(s.next_state, s.goal, contexts[i]))
    let mean = actor.latent_mean(
      tape,
      actor.network.bind(tape),
      tape.vector(s.observation),
      tape.vector(s.goal),
    )
    probabilities.push(
      gaussian_log_prob(tape, mean, latents[i], raw_action_std).value,
    )
  }
  let (advantages, targets) = physical_gae(
    rewards,
    values,
    next_values,
    steps.map(s => s.terminated),
    steps.map(s => s.truncated),
    gamma,
    lam,
  )
  Array::makei(steps.length(), i => {
    observation: steps[i].observation,
    goal: steps[i].goal,
    state: steps[i].state,
    context: contexts[i],
    latent: latents[i],
    old_log_prob: probabilities[i],
    advantage: advantages[i],
    target: targets[i],
  })
}
