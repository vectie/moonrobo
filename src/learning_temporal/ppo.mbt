///|
pub(all) struct TemporalPPOSample {
  point : ValuePoint
  latent : Array[Double]
  old_mean : Array[Double]
  old_log_prob : Double
  advantage : Double
  weight : Double
} derive(Debug, ToJson, FromJson)

///|
fn actor_inputs(actor : TemporalPolicy, point : ValuePoint) -> TemporalPoint {
  let nh = actor.temporal.history_length
  let nf = actor.temporal.future_length
  guard point.history.length() >= nh && point.goals.length() >= nf + 1 else {
    abort("PPO point lacks causal history or command preview")
  }
  {
    history: Array::makei(nh, fn(i) {
      point.history[point.history.length() - nh + i]
    }),
    goal: point.goals[0],
    future: Array::makei(nf, fn(i) { point.goals[i + 1] }),
    target: [],
  }
}

///|
fn full_batch_kl(
  actor : TemporalPolicy,
  batch : Array[TemporalPPOSample],
  std : Double,
) -> Double {
  let means = batch.map(fn(sample) {
    let p = actor_inputs(actor, sample.point)
    let tape = @numeric.Tape::new()
    actor
    .latent_mean(
      tape,
      tape.vector(actor.parameters()),
      p.history.map(fn(row) { tape.vector(row) }),
      tape.vector(p.goal),
      p.future.map(fn(row) { tape.vector(row) }),
    )
    .map(fn(v) { v.value })
  })
  exact_kl(means, batch.map(fn(s) { s.old_mean }), std)
}

///|
pub(all) struct TemporalPPOLosses {
  actor_steps : Int32
  critic_steps : Int32
  actor_early_stopped : Bool
  maximum_full_batch_kl : Double
  final_policy_loss : Double
  value_before_rmse : Double
  value_after_rmse : Double
} derive(Debug, ToJson)

///|
/// Finite-return weighted PPO, including full-batch KL early stopping after every actor step. MC advantages are scaled without centering, preserving their score-function direction.
pub fn optimize(
  actor : TemporalPolicy,
  value : TemporalValue,
  actor_optimizer : @numeric.Adam,
  value_optimizer : @numeric.Adam,
  batch : Array[TemporalPPOSample],
  config : @training.PPOConfig,
  rng : @numeric.Rng,
) -> TemporalPPOLosses {
  guard !batch.is_empty() && config.minibatch_size > 0 else {
    abort("invalid temporal PPO minibatch")
  }
  let count = batch.length().to_double()
  let mut mean = 0.0
  let mut mean_weight = 0.0
  for sample in batch {
    mean += sample.advantage / count
    mean_weight += sample.weight / count
  }
  let mut variance = 0.0
  for sample in batch {
    let d = sample.advantage - mean
    variance += d * d / count
  }
  let denominator = @math.maximum(variance.sqrt(), 1.0)
  let weight_denominator = @math.maximum(mean_weight, 1.0e-8)
  let normalized_advantage = batch.map(fn(s) { s.advantage / denominator })
  let normalized_weight = batch.map(fn(s) { s.weight / weight_denominator })
  let points = batch.map(fn(s) { s.point })
  let value_before_rmse = value.error(points)
  let mut actor_steps = 0
  let mut critic_steps = 0
  let mut stopped = false
  let mut maximum_kl = 0.0
  let mut last_policy_loss = 0.0
  for _ in 0..<config.epochs {
    let ids = Array::makei(batch.length(), fn(i) { i })
    rng.shuffle(ids)
    let mut start = 0
    while start < ids.length() {
      let size = if start + config.minibatch_size > ids.length() {
        ids.length() - start
      } else {
        config.minibatch_size
      }
      let tape = @numeric.Tape::new()
      let parameters = actor.parameters()
      let bound = tape.vector(parameters)
      let log_prob : Array[@numeric.Value] = []
      let old_log : Array[Double] = []
      let advantage : Array[Double] = []
      let weight : Array[Double] = []
      for offset in 0..<size {
        let i = ids[start + offset]
        let sample = batch[i]
        let p = actor_inputs(actor, sample.point)
        let means = actor.latent_mean(
          tape,
          bound,
          p.history.map(fn(row) { tape.vector(row) }),
          tape.vector(p.goal),
          p.future.map(fn(row) { tape.vector(row) }),
        )
        log_prob.push(
          gaussian_log_probability(
            tape,
            means,
            sample.latent,
            config.raw_action_std,
          ),
        )
        old_log.push(sample.old_log_prob)
        advantage.push(normalized_advantage[i])
        weight.push(normalized_weight[i])
      }
      let loss = policy_loss(
        tape,
        log_prob,
        old_log,
        advantage,
        weight,
        config.clip_ratio,
      )
      guard @numeric.finite(loss.value) else {
        abort("nonfinite temporal PPO actor loss")
      }
      tape.backward(loss)
      ignore(actor_optimizer.step(parameters, tape, bound))
      actor.restore(parameters)
      actor_steps += 1
      last_policy_loss = loss.value
      let kl = full_batch_kl(actor, batch, config.raw_action_std)
      maximum_kl = @math.maximum(maximum_kl, kl)
      if kl > config.target_kl {
        stopped = true
        break
      }
      start += size
    }
    if stopped {
      break
    }
  }
  for _ in 0..<config.epochs {
    let ids = Array::makei(batch.length(), fn(i) { i })
    rng.shuffle(ids)
    let mut start = 0
    while start < ids.length() {
      let size = if start + config.minibatch_size > ids.length() {
        ids.length() - start
      } else {
        config.minibatch_size
      }
      ignore(
        value.fit_update(
          value_optimizer,
          Array::makei(size, fn(offset) { points[ids[start + offset]] }),
        ),
      )
      critic_steps += 1
      start += size
    }
  }
  {
    actor_steps,
    critic_steps,
    actor_early_stopped: stopped,
    maximum_full_batch_kl: maximum_kl,
    final_policy_loss: last_policy_loss,
    value_before_rmse,
    value_after_rmse: value.error(points),
  }
}

///|
/// Physical finite-task returns are computed independently for each episode; no reset is allowed in its interior.
pub fn ppo_return_targets(
  rewards : Array[Double],
  continuation : Array[Double],
  terminated : Array[Bool],
  gamma : Double,
) -> (Array[Double], Array[Double]) {
  (
    @training.physical_return_targets(
      rewards, continuation, terminated, 0.0, gamma,
    ),
    discounted_visitation(continuation, gamma),
  )
}
