///|
pub(all) struct ReferenceLearningConfig {
  gamma : Double
  gae_lambda : Double
  raw_action_std : Double
  imagination_horizon : Int32
  critic_updates : Int32
  critic_batch_size : Int32
  model_updates : Int32
  model_batch_size : Int32
  actor_steps : Int32
  actor_batch_size : Int32
  ppo_epochs : Int32
  ppo_minibatch_size : Int32
  ppo_clip : Double
  ppo_target_kl : Double
  actor_trajectory_states : Bool
  actor_critic_tail : Bool
  feedback_gradient : FeedbackGradient
} derive(Debug)

///|
pub(all) struct PpoUpdateResult {
  actor_steps : Int32
  maximum_kl : Double
  kl_early_stopped : Bool
  last_policy_loss : Double
} derive(Debug, ToJson)

///|
pub fn optimize_ppo_actor(
  actor : ReferenceActor,
  optimizer : @numeric.Adam,
  batch : CollectedBatch,
  advantages : Array[Double],
  schedule : ReferenceSchedule,
  config : ReferenceLearningConfig,
  rng : @numeric.Rng,
) -> PpoUpdateResult {
  let n = batch.points.length()
  guard n > 0 &&
    advantages.length() == n &&
    config.ppo_minibatch_size > 0 &&
    config.actor_steps > 0 else {
    abort("invalid PPO updates")
  }
  let weights = batch.points.map(point => {
    @math.pow(config.gamma, (point.step - point.origin).to_double())
  })
  let normalization = (weights.fold(init=0.0, (a, b) => a + b) / n.to_double()).max(
    1.0e-8,
  )
  let points = batch.points.mapi((i, point) => {
    let command = schedule.command(point.clip, point.step, actor.future_length)
    (
      {
        history: point.history,
        current: command.current,
        future: command.future,
        valid: command.valid,
        latent: batch.latent[i],
        old_mean: batch.old_mean[i],
        advantage: advantages[i],
        visitation_weight: weights[i] / normalization,
      } : PpoPoint)
  })
  let mut updates = 0
  let mut maximum_kl = 0.0
  let mut stopped = false
  let mut loss = 0.0
  for _ in 0..<config.ppo_epochs {
    let indices = Array::makei(n, i => i)
    rng.shuffle(indices)
    for first = 0; first < n; first = first + config.ppo_minibatch_size {
      let minibatch = indices[first:(first + config.ppo_minibatch_size).min(n)].map(i => {
          points[i]
        },
      )
      loss = ppo_actor_step(
        actor,
        optimizer,
        minibatch,
        config.raw_action_std,
        config.ppo_clip,
      )
      updates += 1
      let means = points.map(point => {
        actor.latent_mean(
          point.history,
          point.current,
          point.future,
          point.valid,
        )
      })
      let kl = gaussian_mean_kl(means, batch.old_mean, config.raw_action_std)
      maximum_kl = maximum_kl.max(kl)
      stopped = kl > config.ppo_target_kl
      if stopped || updates >= config.actor_steps {
        break
      }
    }
    if stopped || updates >= config.actor_steps {
      break
    }
  }
  {
    actor_steps: updates,
    maximum_kl,
    kl_early_stopped: stopped,
    last_policy_loss: loss,
  }
}

///|
pub fn fit_value_updates(
  value : ReferenceValue,
  optimizer : @numeric.Adam,
  batch : CollectedBatch,
  schedule : ReferenceSchedule,
  config : ReferenceLearningConfig,
  rng : @numeric.Rng,
) -> Double {
  let mut loss = 0.0
  for _ in 0..<config.critic_updates {
    let ids = Array::makei(config.critic_batch_size, _ => {
      rng.index(batch.points.length())
    })
    loss = fit_reference_value(
      value,
      optimizer,
      ids.map(i => batch.points[i]),
      ids.map(i => batch.returns[i]),
      schedule,
    )
  }
  loss
}

///|
pub fn fit_model_updates(
  model : @training.Dynamics,
  optimizer : @numeric.Adam,
  replay : ReferenceModelReplay,
  config : ReferenceLearningConfig,
  rng : @numeric.Rng,
  sample_indices? : (Array[Int32]) -> Unit,
) -> Double {
  let windows = replay.windows()
  let mut loss = 0.0
  for _ in 0..<config.model_updates {
    let ids = Array::makei(config.model_batch_size, _ => {
      rng.index(windows.length())
    })
    if sample_indices is Some(record) {
      record(ids)
    }
    let sampled = ids.map(index => {
      let window = windows[index]
      (
        {
          state: window.state,
          action: window.action,
          target: window.target,
          context: window.context,
          start_time_s: 0.0,
        } : @training.Window)
    })
    loss = model.update(optimizer, sampled)
  }
  loss
}

///|
/// Model/value tensors are frozen by supplying only actor tensors to Adam.
/// Optional logit cap uses the same interpolation/backoff rule as Python.
pub fn optimize_model_actor(
  model : @training.Dynamics,
  actor : ReferenceActor,
  value : ReferenceValue?,
  optimizer : @numeric.Adam,
  batch : CollectedBatch,
  geometry : @balance.Kinematics,
  schedule : ReferenceSchedule,
  config : ReferenceLearningConfig,
  rng : @numeric.Rng,
  logit_cap? : Double,
  calibration_batch_size~ : Int32 = 256,
  sample_indices? : (Array[Int32]) -> Unit,
  optimization_trace? : (Double, Int32, Double, Double, Double, Double) -> Unit,
) -> Array[(Double, Double)] {
  let model_before = model.network.parameters.copy()
  let candidates = actor_origin_candidates(
    batch.episode_lengths,
    trajectory_states=config.actor_trajectory_states,
  )
  let calibration = if logit_cap is Some(_) {
    Array::makei(calibration_batch_size, _ => {
      batch.points[rng.index(batch.points.length())]
    })
  } else {
    []
  }
  let means = (points : Array[LearningPoint]) => {
    points.map(point => {
      let command = schedule.command(
        point.clip,
        point.step,
        actor.future_length,
      )
      actor.latent_mean(
        point.history,
        command.current,
        command.future,
        command.valid,
      )
    })
  }
  let result : Array[(Double, Double)] = []
  for _ in 0..<config.actor_steps {
    let ids = Array::makei(config.actor_batch_size, _ => {
      candidates[rng.index(candidates.length())]
    })
    if sample_indices is Some(record) {
      record(ids)
    }
    let points = ids.map(index => batch.points[index])
    let base = actor.parameters()
    let initial = means(calibration)
    let (objective, active, gradient_norm) = optimize_model_actor_step(
      model,
      actor,
      value,
      optimizer,
      points,
      geometry,
      schedule,
      config.imagination_horizon,
      config.gamma,
      feedback_gradient=config.feedback_gradient,
      critic_tail=config.actor_critic_tail,
    )
    let raw = actor.parameters()
    let rms = () => {
      let current = means(calibration)
      let mut total = 0.0
      let mut count = 0
      for i, row in current {
        for j, x in row {
          let d = x - initial[i][j]
          total += d * d
          count += 1
        }
      }
      (total / count.to_double()).sqrt()
    }
    let mut applied = if calibration.is_empty() { 0.0 } else { rms() }
    let proposed = applied
    let mut scale = 1.0
    if logit_cap is Some(cap) {
      guard cap > 0.0 && finite(applied) else {
        abort("positive finite logit cap and proposal required")
      }
      if applied > cap {
        scale = 0.99 * cap / applied
        actor.set_parameters(base.mapi((i, x) => x + scale * (raw[i] - x)))
        applied = rms()
        for ;; {
          if applied <= cap {
            break
          }
          scale *= 0.5
          actor.set_parameters(base.mapi((i, x) => x + scale * (raw[i] - x)))
          applied = rms()
          guard finite(applied) else {
            abort("nonfinite calibrated policy step")
          }
        }
        guard applied <= cap else {
          abort("calibrated policy step exceeds cap")
        }
      }
    }
    result.push((objective, applied))
    if optimization_trace is Some(record) {
      record(objective, active, gradient_norm, proposed, applied, scale)
    }
  }
  guard model.network.parameters == model_before else {
    abort("world model changed during policy optimization")
  }
  result
}
