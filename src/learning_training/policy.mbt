///|
/// Shared G1 observation schema from policy.py.
pub(all) struct Body {
  q_indices : Array[Int32]
  v_state_indices : Array[Int32]
  nq : Int32
} derive(Debug)

///|
pub fn gravity(
  tape : @numeric.Tape,
  state : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let w = state[3]
  let x = state[4]
  let y = state[5]
  let z = state[6]
  [
    tape.scale(tape.sub(tape.mul(x, z), tape.mul(w, y)), -2),
    tape.scale(tape.add(tape.mul(y, z), tape.mul(w, x)), -2),
    tape.sub(
      tape.scale(tape.add(tape.mul(x, x), tape.mul(y, y)), 2),
      tape.scalar(1),
    ),
  ]
}

///|
pub fn observation(
  tape : @numeric.Tape,
  state : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  body : Body,
) -> Array[@numeric.Value] {
  let result = body.q_indices.map(i => state[i])
  result.append(body.v_state_indices.map(i => state[i]))
  result.append(gravity(tape, state))
  for i in (body.nq + 3)..<(body.nq + 6) {
    result.push(state[i])
  }
  result.append(previous)
  result
}

///|
pub struct Actor {
  obs_stats : @numeric.Normalization
  goal_stats : @numeric.Normalization
  lower : Array[Double]
  upper : Array[Double]
  action_delta_rad : Double
  body : Body
  network : @numeric.MLP
} derive(Debug)

///|
pub fn Actor::new(
  obs_stats : @numeric.Normalization,
  goal_stats : @numeric.Normalization,
  lower : Array[Double],
  upper : Array[Double],
  action_delta_rad : Double,
  body : Body,
  width : Int32,
  rng : @numeric.Rng,
) -> Actor {
  let ng = goal_stats.mean.length()
  guard lower.length() == ng && upper.length() == ng && action_delta_rad > 0 else {
    abort("invalid actor bounds")
  }
  for i in 0..<ng {
    guard lower[i] <= upper[i] else {
      abort("actor lower bound exceeds upper bound")
    }
  }
  {
    obs_stats,
    goal_stats,
    lower,
    upper,
    action_delta_rad,
    body,
    network: @numeric.MLP::new(
      [obs_stats.mean.length() + ng, width, width, ng],
      rng,
      zero_last=true,
    ),
  }
}

///|
pub fn Actor::latent_mean(
  self : Actor,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  obs : Array[@numeric.Value],
  goal : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let input = self.obs_stats.apply(tape, obs)
  input.append(self.goal_stats.apply(tape, goal))
  self.network.forward(tape, parameters, input)
}

///|
pub fn Actor::action_from_latent(
  self : Actor,
  tape : @numeric.Tape,
  latent : Array[@numeric.Value],
  goal : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(goal.length(), i => {
    tape.maximum(
      tape.minimum(
        tape.add(
          goal[i],
          tape.scale(tape.tanh(latent[i]), self.action_delta_rad),
        ),
        tape.scalar(self.upper[i]),
      ),
      tape.scalar(self.lower[i]),
    )
  })
}

///|
pub fn Actor::forward(
  self : Actor,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  obs : Array[@numeric.Value],
  goal : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  self.action_from_latent(
    tape,
    self.latent_mean(tape, parameters, obs, goal),
    goal,
  )
}

///|
pub fn Actor::predict(
  self : Actor,
  obs : Array[Double],
  goal : Array[Double],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  self
  .forward(tape, self.network.bind(tape), tape.vector(obs), tape.vector(goal))
  .map(v => v.value)
}

///|
pub struct Critic {
  state_stats : @numeric.Normalization
  network : @numeric.MLP
  translation_invariant : Bool
  value_bound : Double
} derive(Debug)

///|
pub fn Critic::new(
  state_stats : @numeric.Normalization,
  n_goal : Int32,
  n_context : Int32,
  gamma : Double,
  rng : @numeric.Rng,
  translation_invariant~ : Bool = false,
  zero_output~ : Bool = false,
) -> Critic {
  guard gamma >= 0 && gamma < 1 else { abort("gamma outside [0,1)") }
  let network = @numeric.MLP::new(
    [state_stats.mean.length() + n_goal + n_context, 128, 64, 1],
    rng,
    zero_last=zero_output,
  )
  let critic = {
    state_stats,
    network,
    translation_invariant,
    value_bound: 3.0 / (1 - gamma),
  }
  critic.enforce_input_encoding()
  critic
}

///|
pub fn Critic::enforce_input_encoding(self : Critic) -> Unit {
  if self.translation_invariant {
    let nin = self.network.dimensions[0]
    for row in 0..<self.network.dimensions[1] {
      self.network.parameters[row * nin] = 0
      self.network.parameters[row * nin + 1] = 0
    }
  }
}

///|
pub fn Critic::forward(
  self : Critic,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  state : Array[@numeric.Value],
  goal : Array[@numeric.Value],
  context : Array[@numeric.Value],
) -> @numeric.Value {
  let input = self.state_stats.apply(tape, state)
  if self.translation_invariant {
    input[0] = tape.scalar(0)
    input[1] = tape.scalar(0)
  }
  input.append(goal)
  input.append(context)
  tape.scale(
    tape.tanh(
      tape.scale(
        self.network.forward(tape, parameters, input)[0],
        1 / self.value_bound,
      ),
    ),
    self.value_bound,
  )
}

///|
pub fn Critic::predict(
  self : Critic,
  state : Array[Double],
  goal : Array[Double],
  context : Array[Double],
) -> Double {
  let tape = @numeric.Tape::new()
  self.forward(
    tape,
    self.network.bind(tape),
    tape.vector(state),
    tape.vector(goal),
    tape.vector(context),
  ).value
}

///|
pub fn step_reward(
  tape : @numeric.Tape,
  state : Array[@numeric.Value],
  action : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  goal : Array[@numeric.Value],
  q_indices : Array[Int32],
  target_height : Double,
) -> (@numeric.Value, @numeric.Value) {
  let upright = tape.scale(gravity(tape, state)[2], -1)
  let tracking_errors = Array::makei(goal.length(), i => {
    let d = tape.sub(state[q_indices[i]], goal[i])
    tape.mul(d, d)
  })
  let smooth_errors = Array::makei(action.length(), i => {
    let d = tape.scale(tape.sub(action[i], previous[i]), 10)
    tape.mul(d, d)
  })
  let tracking = tape.exp(tape.scale(tape.mean(tracking_errors), -1.0 / 0.09))
  let balance_delta = tape.scale(tape.sub(tape.scalar(1), upright), 5)
  let balance = tape.exp(tape.scale(tape.mul(balance_delta, balance_delta), -1))
  let height_delta = tape.scale(
    tape.sub(state[2], tape.scalar(target_height)),
    1.0 / 0.15,
  )
  let height = tape.exp(tape.scale(tape.mul(height_delta, height_delta), -1))
  let reward = tape.sub(
    tape.add(tape.add(tracking, balance), height),
    tape.scale(tape.mean(smooth_errors), 0.05),
  )
  let continuation = tape.mul(
    tape.sigmoid(tape.scale(tape.sub(state[2], tape.scalar(0.35)), 50)),
    tape.sigmoid(tape.scale(tape.sub(upright, tape.scalar(0.5)), 20)),
  )
  (reward, continuation)
}

///|
pub(all) struct RolloutConfig {
  horizon : Int32
  gamma : Double
  target_height : Double
  bootstrap : Bool
} derive(Debug)

///|
pub struct ImaginedRollout {
  objective : @numeric.Value
  states : Array[Array[@numeric.Value]]
  rewards : Array[@numeric.Value]
  continuations : Array[@numeric.Value]
}

///|
pub fn imagined_rollout(
  dynamics : Dynamics,
  actor : Actor,
  critic : Critic,
  tape : @numeric.Tape,
  dynamics_parameters : Array[@numeric.Value],
  actor_parameters : Array[@numeric.Value],
  critic_parameters : Array[@numeric.Value],
  initial : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  goal : Array[@numeric.Value],
  context : Array[@numeric.Value],
  config : RolloutConfig,
) -> ImaginedRollout {
  guard config.horizon > 0 else { abort("empty rollout horizon") }
  let mut state = initial
  let mut previous = previous
  let mut survival = tape.scalar(1)
  let mut objective = tape.scalar(0)
  let states = [state]
  let rewards = []
  let continuations = []
  for t in 0..<config.horizon {
    let action = actor.forward(
      tape,
      actor_parameters,
      observation(tape, state, previous, actor.body),
      goal,
    )
    state = dynamics.forward(tape, dynamics_parameters, state, action, context)
    let (reward, continuation) = step_reward(
      tape,
      state,
      action,
      previous,
      goal,
      actor.body.q_indices,
      config.target_height,
    )
    objective = tape.add(
      objective,
      tape.scale(
        tape.mul(survival, reward),
        @math.pow(config.gamma, t.to_double()),
      ),
    )
    survival = tape.mul(survival, continuation)
    states.push(state)
    rewards.push(reward)
    continuations.push(continuation)
    previous = action
  }
  if config.bootstrap {
    objective = tape.add(
      objective,
      tape.scale(
        tape.mul(
          survival,
          critic.forward(tape, critic_parameters, state, goal, context),
        ),
        @math.pow(config.gamma, config.horizon.to_double()),
      ),
    )
  }
  { objective, states, rewards, continuations, }
}

///|
pub fn physical_return_targets(
  rewards : Array[Double],
  continuation : Array[Double],
  terminated : Array[Bool],
  tail : Double,
  gamma : Double,
) -> Array[Double] {
  guard continuation.length() == rewards.length() &&
    terminated.length() == rewards.length() else {
    abort("return target shape mismatch")
  }
  let result = Array::make(rewards.length(), 0.0)
  let mut value = tail
  for i = rewards.length() - 1; i >= 0; i = i - 1 {
    value = rewards[i] +
      gamma * continuation[i] * (if terminated[i] { 0.0 } else { value })
    result[i] = value
  }
  result
}

///|
pub fn gae_targets(
  values : Array[Double],
  rewards : Array[Double],
  continuation : Array[Double],
  gamma : Double,
  lam : Double,
) -> Array[Double] {
  guard values.length() == rewards.length() + 1 &&
    continuation.length() == rewards.length() else {
    abort("GAE shape mismatch")
  }
  let targets = Array::make(rewards.length(), 0.0)
  let mut advantage = 0.0
  for t = rewards.length() - 1; t >= 0; t = t - 1 {
    let delta = rewards[t] + gamma * continuation[t] * values[t + 1] - values[t]
    advantage = delta + gamma * lam * continuation[t] * advantage
    targets[t] = advantage + values[t]
  }
  targets
}
