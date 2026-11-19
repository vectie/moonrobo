///|
/// Train-only temporal targets, rebuilt from physical timestamps and a caller's declared reference schedule. Current goals are checked rather than silently regenerated.
pub fn episode_points(
  episode : @native_physics.Episode,
  history_length : Int32,
  future_length : Int32,
  dt : Double,
  reference : (Double) -> Array[Double],
  targets? : Array[Array[Double]],
) -> Array[@temporal.TemporalPoint] raise {
  guard episode.split == "train" && !episode.steps.is_empty() else {
    fail("temporal supervision accepts nonempty train episodes only")
  }
  for i in 0..<(episode.steps.length() - 1) {
    guard !episode.steps[i].terminated && !episode.steps[i].truncated else {
      fail("history cannot cross reset boundaries")
    }
  }
  let labels = targets.unwrap_or(episode.steps.map(fn(s) { s.applied_action }))
  guard labels.length() == episode.steps.length() else {
    fail("teacher targets do not match physical episode")
  }
  let history = @temporal.causal_history(
    episode.steps.map(fn(s) { s.observation }),
    episode.steps.map(fn(s) { s.time_s }),
    history_length,
    dt,
  )
  Array::makei(episode.steps.length(), fn(i) {
    let step = episode.steps[i]
    let expected = reference(step.time_s)
    guard expected.length() == step.goal.length() else {
      fail("reference current goal width mismatch")
    }
    for j in 0..<expected.length() {
      guard (expected[j] - step.goal[j]).abs() <=
        1.0e-6 + 1.0e-6 * step.goal[j].abs() else {
        fail("stored goals disagree with declared reference schedule")
      }
    }
    {
      history: history[i],
      goal: step.goal,
      future: @temporal.preview_goals(reference, step.time_s, dt, future_length),
      target: labels[i],
    }
  })
}

///|
pub fn episode_value_points(
  episode : @native_physics.Episode,
  actor : @temporal.TemporalPolicy,
  dt : Double,
  duration : Double,
  gamma : Double,
  target_height : Double,
  reference : (Double) -> Array[Double],
) -> Array[@temporal.ValuePoint] raise {
  let points = episode_points(episode, 10, 10, dt, reference)
  let rewards : Array[Double] = []
  let continuation : Array[Double] = []
  for i, step in episode.steps {
    let last = points[i].history[9]
    let nu = actor.base.lower.length()
    let previous = Array::makei(nu, fn(j) { last[last.length() - nu + j] })
    let tape = @numeric.Tape::new()
    let (r, c) = @training.step_reward(
      tape,
      tape.vector(step.next_state),
      tape.vector(step.applied_action),
      tape.vector(previous),
      tape.vector(step.goal),
      actor.base.body.q_indices,
      target_height,
    )
    rewards.push(r.value)
    continuation.push(c.value)
  }
  let targets = @training.physical_return_targets(
    rewards,
    continuation,
    episode.steps.map(fn(s) { s.terminated }),
    0.0,
    gamma,
  )
  Array::makei(points.length(), fn(i) {
    let p = points[i]
    let goals = [p.goal]
    goals.append(p.future)
    {
      state: episode.steps[i].state,
      history: p.history,
      goals,
      context: episode.context,
      remaining: duration - episode.steps[i].time_s,
      target: targets[i],
    }
  })
}

///|
/// Collects on-policy Gaussian latents in the actual physics rollout; applied clipped setpoints are never used as likelihood samples.
pub fn collect_ppo(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  case : @native_physics.Case,
  reset_seed : Int32,
  seconds : Double,
  dt : Double,
  gamma : Double,
  target_height : Double,
  std : Double,
  rng : @numeric.Rng,
  offset? : Array[Double],
  schedule? : @native_physics.JointSines,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> (
  Array[@temporal.TemporalPPOSample],
  @native_physics.Episode,
  @native_physics.Trial,
) raise {
  guard case.split == "train" &&
    actor.temporal.history_length <= 10 &&
    actor.temporal.future_length <= 10 &&
    std > 0.0 else {
    fail(
      "PPO requires train-only cases and histories/previews fitting the value model",
    )
  }
  let history : Array[Array[Double]] = []
  let samples : Array[Array[Double]] = []
  let means : Array[Array[Double]] = []
  let captured : Array[Array[Array[Double]]] = []
  let captured_goal : Array[Array[Double]] = []
  let captured_future : Array[Array[Array[Double]]] = []
  let log_probs : Array[Double] = []
  let mut nominal : Array[Double] = []
  let mut index = 0
  let policy = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    if history.is_empty() {
      nominal = Array::makei(goal.length(), fn(i) { obs[i] })
      for _ in 0..<actor.temporal.history_length {
        history.push(obs.copy())
      }
    } else {
      history.remove(0) |> ignore
      history.push(obs.copy())
    }
    captured.push(history.map(fn(row) { row.copy() }))
    let future = Array::makei(actor.temporal.future_length, fn(j) {
      try! runtime.reference(
        nominal,
        case.motion,
        (index + j + 1).to_double() * dt,
        offset?,
        schedule?,
      )
    })
    captured_goal.push(goal.copy())
    captured_future.push(future.map(fn(row) { row.copy() }))
    let tape = @numeric.Tape::new()
    let mean = actor.latent_mean(
      tape,
      tape.vector(actor.parameters()),
      history.map(fn(row) { tape.vector(row) }),
      tape.vector(goal),
      future.map(fn(row) { tape.vector(row) }),
    )
    let latent = mean.map(fn(v) { v.value + std * rng.normal() })
    let action = actor.base
      .action_from_latent(tape, tape.vector(latent), tape.vector(goal))
      .map(fn(v) { v.value })
    samples.push(latent)
    means.push(mean.map(fn(v) { v.value }))
    log_probs.push(
      @temporal.gaussian_log_probability(tape, mean, latent, std).value,
    )
    index += 1
    action
  }
  let reset_rng = @numeric.Rng::new(reset_seed.reinterpret_as_uint())
  let (episode, trial) = runtime.rollout(
    case,
    reset_seed,
    "policy",
    seconds,
    dt,
    fn() { reset_rng.normal() },
    policy~,
    offset?,
    schedule?,
    fall_height~,
    fall_upright~,
  )
  let reference = fn(time : Double) {
    try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
  }
  let points = episode_value_points(
    episode, actor, dt, seconds, gamma, target_height, reference,
  )
  let rewards : Array[Double] = []
  let continuation : Array[Double] = []
  for i, step in episode.steps {
    let tape = @numeric.Tape::new()
    let last = points[i].history[9]
    let nu = actor.base.lower.length()
    let previous = Array::makei(nu, fn(j) { last[last.length() - nu + j] })
    let (r, c) = @training.step_reward(
      tape,
      tape.vector(step.next_state),
      tape.vector(step.applied_action),
      tape.vector(previous),
      tape.vector(step.goal),
      actor.base.body.q_indices,
      target_height,
    )
    rewards.push(r.value)
    continuation.push(c.value)
    let h = points[i].history
    guard captured_goal[i] == points[i].goals[0] &&
      captured_future[i] ==
      Array::makei(actor.temporal.future_length, fn(j) {
        points[i].goals[j + 1]
      }) else {
      fail(
        "PPO online current/preview inputs differ from physical reconstruction",
      )
    }
    for j in 0..<actor.temporal.history_length {
      guard captured[i][j] == h[h.length() - actor.temporal.history_length + j] else {
        fail("PPO online history differs from physical episode reconstruction")
      }
    }
  }
  let weights = @temporal.discounted_visitation(continuation, gamma)
  let batch : Array[@temporal.TemporalPPOSample] = Array::makei(
    points.length(),
    fn(i) {
      let p = points[i]
      let estimate = value.predict(
        p.state,
        p.history,
        p.goals,
        p.context,
        p.remaining,
      )
      {
        point: p,
        latent: samples[i],
        old_mean: means[i],
        old_log_prob: log_probs[i],
        advantage: p.target - estimate,
        weight: weights[i],
      }
    },
  )
  (batch, episode, trial)
}
