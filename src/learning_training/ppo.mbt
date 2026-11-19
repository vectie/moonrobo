///|
/// True termination removes bootstrap; truncation retains bootstrap and stops GAE propagation.
pub fn physical_gae(
  rewards : Array[Double],
  values : Array[Double],
  next_values : Array[Double],
  terminated : Array[Bool],
  truncated : Array[Bool],
  gamma : Double,
  lam : Double,
) -> (Array[Double], Array[Double]) {
  let n = rewards.length()
  guard values.length() == n &&
    next_values.length() == n &&
    terminated.length() == n &&
    truncated.length() == n else {
    abort("physical GAE shape mismatch")
  }
  let result = Array::make(n, 0.0)
  let mut advantage = 0.0
  for i = n - 1; i >= 0; i = i - 1 {
    let delta = rewards[i] +
      (if terminated[i] { 0.0 } else { gamma * next_values[i] }) -
      values[i]
    advantage = delta +
      (if terminated[i] || truncated[i] {
        0.0
      } else {
        gamma * lam * advantage
      })
    result[i] = advantage
  }
  (result, Array::makei(n, i => result[i] + values[i]))
}

///|
/// Latents precede tanh/clipping; likelihoods never use applied setpoints.
pub(all) struct PPOSample {
  observation : Array[Double]
  goal : Array[Double]
  state : Array[Double]
  context : Array[Double]
  latent : Array[Double]
  old_log_prob : Double
  advantage : Double
  target : Double
} derive(Debug)

///|
pub(all) struct PPOConfig {
  epochs : Int32
  minibatch_size : Int32
  raw_action_std : Double
  target_kl : Double
  clip_ratio : Double
} derive(Debug)

///|
pub struct PPOLosses {
  policy_loss : Double
  value_loss : Double
  maximum_minibatch_kl : Double
  policy_early_stopped : Bool
} derive(Debug)

///|
pub fn gaussian_log_prob(
  tape : @numeric.Tape,
  mean : Array[@numeric.Value],
  latent : Array[Double],
  std : Double,
) -> @numeric.Value {
  guard std > 0 && mean.length() == latent.length() else {
    abort("Gaussian shape or scale invalid")
  }
  let mut result = tape.scalar(0)
  for i in 0..<mean.length() {
    let d = tape.scale(tape.sub(tape.scalar(latent[i]), mean[i]), 1 / std)
    result = tape.add(
      result,
      tape.sub(
        tape.scale(tape.mul(d, d), -0.5),
        tape.scalar(@math.ln(std) + 0.9189385332046727),
      ),
    )
  }
  result
}

///|
/// Translates optimize() with epoch shuffles, clipped surrogate, KL stop and separate value fitting.
pub fn ppo_optimize(
  actor : Actor,
  critic : Critic,
  actor_optimizer : @numeric.Adam,
  critic_optimizer : @numeric.Adam,
  batch : Array[PPOSample],
  config : PPOConfig,
  rng : @numeric.Rng,
) -> PPOLosses {
  guard batch.length() > 0 &&
    config.epochs > 0 &&
    config.minibatch_size > 0 &&
    config.raw_action_std > 0 else {
    abort("invalid PPO batch/config")
  }
  let stats = @numeric.fit_normalization(
    batch.map(s => [s.advantage]),
    0.00000001,
  )
  let advantage = batch.map(s => (s.advantage - stats.mean[0]) / stats.scale[0])
  let mut maximum_kl = 0.0
  let mut stopped = false
  let mut policy_loss = 0.0
  let mut value_loss = 0.0
  for _ in 0..<config.epochs {
    let indices = Array::makei(batch.length(), i => i)
    rng.shuffle(indices)
    for start = 0
        start < indices.length()
        start = start + config.minibatch_size {
      let stop = @math.minimum(start + config.minibatch_size, indices.length())
      let tape = @numeric.Tape::new()
      let bound = actor.network.bind(tape)
      let terms = []
      let mut kl = 0.0
      for j in start..<stop {
        let id = indices[j]
        let sample = batch[id]
        let mean = actor.latent_mean(
          tape,
          bound,
          tape.vector(sample.observation),
          tape.vector(sample.goal),
        )
        let difference = tape.sub(
          gaussian_log_prob(tape, mean, sample.latent, config.raw_action_std),
          tape.scalar(sample.old_log_prob),
        )
        let ratio = tape.exp(difference)
        kl += (ratio.value - 1 - difference.value) / (stop - start).to_double()
        terms.push(
          tape.scale(
            tape.minimum(
              tape.scale(ratio, advantage[id]),
              tape.scale(
                tape.clamp(ratio, 1 - config.clip_ratio, 1 + config.clip_ratio),
                advantage[id],
              ),
            ),
            -1,
          ),
        )
      }
      maximum_kl = @math.maximum(maximum_kl, kl)
      if kl > config.target_kl {
        stopped = true
        break
      }
      let loss = tape.mean(terms)
      guard @numeric.finite(loss.value) else {
        abort("nonfinite PPO policy loss")
      }
      policy_loss = loss.value
      tape.backward(loss)
      ignore(actor_optimizer.step(actor.network.parameters, tape, bound))
    }
    if stopped {
      break
    }
  }
  for _ in 0..<config.epochs {
    let indices = Array::makei(batch.length(), i => i)
    rng.shuffle(indices)
    for start = 0
        start < indices.length()
        start = start + config.minibatch_size {
      let tape = @numeric.Tape::new()
      let bound = critic.network.bind(tape)
      let terms = []
      for
        j in start..<@math.minimum(
          start + config.minibatch_size,
          indices.length(),
        ) {
        let sample = batch[indices[j]]
        let value = critic.forward(
          tape,
          bound,
          tape.vector(sample.state),
          tape.vector(sample.goal),
          tape.vector(sample.context),
        )
        let error = tape.sub(value, tape.scalar(sample.target))
        terms.push(tape.mul(error, error))
      }
      let loss = tape.mean(terms)
      guard @numeric.finite(loss.value) else {
        abort("nonfinite PPO value loss")
      }
      value_loss = loss.value
      tape.backward(loss)
      ignore(critic_optimizer.step(critic.network.parameters, tape, bound))
    }
  }
  {
    policy_loss,
    value_loss,
    maximum_minibatch_kl: maximum_kl,
    policy_early_stopped: stopped,
  }
}
