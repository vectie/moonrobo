///|
pub(all) struct Schedule {
  nominal : Array[Double]
  offset : Array[Double]?
  sines : @native_physics.JointSines?
}

///|
/// One schedule per physical episode; history is initialized from the first observed frame and never crosses resets.
pub fn rollout(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  case : @native_physics.Case,
  seed : Int32,
  seconds : Double,
  dt : Double,
  _rng : @numeric.Rng,
  offset? : Array[Double],
  schedule? : @native_physics.JointSines,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> (@native_physics.Episode, @native_physics.Trial) raise {
  let frames : Array[Array[Double]] = []
  let mut index = 0
  let mut nominal : Array[Double] = []
  let policy = fn(
    observation : Array[Double],
    goal : Array[Double],
  ) -> Array[Double] {
    if frames.is_empty() {
      nominal = Array::makei(goal.length(), fn(i) { observation[i] })
      for _ in 0..<actor.temporal.history_length {
        frames.push(observation.copy())
      }
    } else {
      frames.remove(0) |> ignore
      frames.push(observation.copy())
    }
    // Runtime.reference validates model bounds; valid schedules are checked before rollout below.
    let future = Array::makei(actor.temporal.future_length, fn(i) {
      try! runtime.reference(
        nominal,
        case.motion,
        (index + i + 1).to_double() * dt,
        offset?,
        schedule?,
      )
    })
    index += 1
    actor.predict(frames, goal, future)
  }
  let reset_rng = @numeric.Rng::new(seed.reinterpret_as_uint())
  runtime.rollout(
    case,
    seed,
    "policy",
    seconds,
    dt,
    fn() { reset_rng.normal() },
    fall_height~,
    fall_upright~,
    policy~,
    offset?,
    schedule?,
  )
}

///|
pub fn evaluate(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  cases : Array[@native_physics.Case],
  seeds : Array[Int32],
  seconds : Double,
  dt : Double,
  seed : UInt32,
  split? : String,
) -> (
  @training.PhysicsSummary,
  Array[@native_physics.Episode],
  Array[@native_physics.Trial],
) raise {
  let episodes : Array[@native_physics.Episode] = []
  let trials : Array[@native_physics.Trial] = []
  let rng = @numeric.Rng::new(seed)
  for case in cases {
    if split is Some(s) && case.split != s {
      continue
    }
    for reset_seed in seeds {
      let (episode, trial) = rollout(
        runtime, actor, case, reset_seed, seconds, dt, rng,
      )
      episodes.push(episode)
      trials.push(trial)
    }
  }
  guard !trials.is_empty() else { fail("no temporal evaluation cases") }
  let mut falls = 0
  let mut survival_s = 0.0
  let mut joint_rmse_rad = 0.0
  for trial in trials {
    if trial.failed {
      falls += 1
    }
    survival_s += trial.simulated_seconds / trials.length().to_double()
    joint_rmse_rad += trial.joint_rmse_rad / trials.length().to_double()
  }
  ({ falls, survival_s, joint_rmse_rad, }, episodes, trials)
}

///|
pub(all) struct Origin {
  integration : Array[Double]
  state : Array[Double]
  history : Array[Array[Double]]
  goals : Array[Array[Double]]
  context : Array[Double]
  remaining_steps : Int32
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct PhysicalReturn {
  soft_return : Double
  steps : Int32
  failed : Bool
  states : Array[Array[Double]]
  actions : Array[Array[Double]]
} derive(Debug, ToJson)

///|
/// Restores complete integration state once, then evolves only with MuJoCo. The caller supplies the exact declared future goal schedule and episode-local causal history.
pub fn physical_return(
  runtime : @native_physics.Runtime,
  origin : Origin,
  actor : @temporal.TemporalPolicy,
  dt : Double,
  gamma : Double,
  target_height : Double,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> PhysicalReturn raise {
  guard origin.remaining_steps > 0 &&
    !origin.context.is_empty() &&
    origin.history.length() == actor.temporal.history_length &&
    origin.goals.length() >=
    origin.remaining_steps + actor.temporal.future_length else {
    fail("incomplete physical origin")
  }
  let history = origin.history.map(fn(row) { row.copy() })
  let nu = actor.base.lower.length()
  let last = history[history.length() - 1]
  let mut previous = Array::makei(nu, fn(i) { last[last.length() - nu + i] })
  runtime.save()
  defer runtime.restore()
  runtime.restore_disable_flags()
  runtime.set_friction(origin.context[0])
  runtime.set_integration(origin.integration)
  let substeps = runtime.control_substeps(dt)
  let states : Array[Array[Double]] = []
  let actions : Array[Array[Double]] = []
  let mut total = 0.0
  let mut survival = 1.0
  let mut discount = 1.0
  let mut failed = false
  for t in 0..<origin.remaining_steps {
    let action = runtime.clip_control(
      actor.predict(
        history,
        origin.goals[t],
        Array::makei(actor.temporal.future_length, fn(i) {
          origin.goals[t + i + 1]
        }),
      ),
    )
    let state = runtime.step(action, substeps)
    let tape = @numeric.Tape::new()
    let (reward, continuation) = @training.step_reward(
      tape,
      tape.vector(state),
      tape.vector(action),
      tape.vector(previous),
      tape.vector(origin.goals[t]),
      actor.base.body.q_indices,
      target_height,
    )
    total += discount * survival * reward.value
    survival *= continuation.value
    discount *= gamma
    states.push(state)
    actions.push(action)
    failed = runtime.root_height() < fall_height ||
      runtime.upright() < fall_upright
    if failed {
      break
    }
    history.remove(0) |> ignore
    history.push(runtime.observation(action))
    previous = action
  }
  { soft_return: total, steps: states.length(), failed, states, actions, }
}
