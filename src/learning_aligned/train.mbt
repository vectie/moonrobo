///|
pub(all) struct CollectorFrame {
  state : State
  previous : Array[Double]
  xi : Array[Double]
  frame : Int32
  episode_step : Int32
}

///|
pub(all) struct TrainingCounters {
  mut physical_transitions : Int32
  mut imagined_transitions : Int32
  mut actor_updates : Int32
  mut model_updates : Int32
  mut critic_updates : Int32
  mut model_fit_transition_slots : Int32
} derive(Debug, ToJson, FromJson)

///|
pub fn TrainingCounters::new() -> TrainingCounters {
  {
    physical_transitions: 0,
    imagined_transitions: 0,
    actor_updates: 0,
    model_updates: 0,
    critic_updates: 0,
    model_fit_transition_slots: 0,
  }
}

///|
pub(all) struct TrainingOptions {
  iterations : Int32
  warmup_steps : Int32
  world_only_iterations : Int32
  update_to_data : Double
  learning_rate_decay_iterations : Int32
  action_noise : Double
} derive(Debug)

///|
pub(all) struct IterationMetrics {
  iteration : Int32
  learning_rate : Double
  world : WorldFitMetrics
  policy : PolicyMetrics?
  actor_readiness : ActorReadiness?
} derive(Debug, ToJson)

///|
pub struct TrainingRunner {
  learner : Learner
  replay : ReplayBuffer
  counters : TrainingCounters
  histories : Array[Array[Array[Double]]]
  actor_catalog : String
  mut iteration : Int32
  mut step_accumulator : Double
}

///|
pub fn TrainingRunner::new(
  learner : Learner,
  capacity : Int32,
  num_envs : Int32,
) -> TrainingRunner raise {
  let actor_catalog = learner.motion.require_actor_horizon(
    learner.config.horizon,
  )
  {
    learner,
    replay: ReplayBuffer::new(capacity, num_envs),
    counters: TrainingCounters::new(),
    histories: Array::makei(num_envs, _ => []),
    actor_catalog,
    iteration: 0,
    step_accumulator: 0.0,
  }
}

///|
fn TrainingRunner::collect(
  self : TrainingRunner,
  steps : Int32,
  inspect_env : () -> Array[CollectorFrame] raise,
  step_env : (Array[Array[Double]]) -> Array[Transition] raise,
  action_noise : Double,
) -> Unit raise {
  for _ in 0..<steps {
    let frames = inspect_env()
    guard frames.length() == self.histories.length() else {
      fail("physical adapter environment count differs")
    }
    let observations : Array[Array[Double]] = []
    let goals : Array[Array[Double]] = []
    for i, frame in frames {
      let obs = observation(
        frame.state,
        frame.previous,
        frame.xi,
        self.learner.default_q,
        self.learner.motion.states[frame.frame],
        self.learner.mode,
      )
      let noisy = if self.learner.config.observation_noise {
        let widths = observation_noise(self.learner.mode)
        Array::makei(obs.length(), j => {
          obs[j] + (self.learner.rng.uniform() * 2.0 - 1.0) * widths[j]
        })
      } else {
        obs
      }
      let history = if frame.episode_step == 0 || self.histories[i].is_empty() {
        Array::makei(self.learner.config.hist, _ => noisy.copy())
      } else {
        let next = self.histories[i][1:].to_owned()
        next.push(noisy)
        next
      }
      self.histories[i] = history
      observations.push(noisy)
      goals.push(
        self.learner.motion.goal(frame.frame, self.learner.config.goal_frames),
      )
    }
    self.learner.policy.update_normalizers(observations, goals)
    let actions : Array[Array[Double]] = []
    for i in 0..<frames.length() {
      let action = self.learner.policy
        .forward(self.histories[i], goals[i])
        .map(x => {
          (x + action_noise * self.learner.rng.normal()).max(-20.0).min(20.0)
        })
      actions.push(action)
    }
    let transitions = step_env(actions)
    self.replay.add(transitions)
    self.learner.wm.observe_batch(transitions)
    self.counters.physical_transitions += frames.length()
  }
}

///|
// The adapter callbacks must provide actual physical transitions. There is no synthetic fallback.
pub fn TrainingRunner::run(
  self : TrainingRunner,
  options : TrainingOptions,
  inspect_env : () -> Array[CollectorFrame] raise,
  step_env : (Array[Array[Double]]) -> Array[Transition] raise,
  on_iteration : (IterationMetrics) -> Unit raise,
) -> Unit raise {
  guard options.iterations >= self.iteration &&
    options.update_to_data > 0.0 &&
    finite(options.update_to_data) &&
    options.learning_rate_decay_iterations > 0 else {
    fail("invalid training iteration or UTD configuration")
  }
  let c = self.learner.config
  if !self.replay.can_sample_windows(c.wm_window) {
    self.collect(
      options.warmup_steps.max(c.wm_window),
      inspect_env,
      step_env,
      options.action_noise,
    )
  }
  for it in self.iteration..<options.iterations {
    let ratio = (it.to_double() /
    options.learning_rate_decay_iterations.to_double()).min(1.0)
    let lr = c.learning_rate *
      (0.03 + 0.97 * 0.5 * (1.0 + @math.cos(@math.PI * ratio)))
    self.learner.opt_wm.set_learning_rate(lr)
    self.learner.opt_policy.set_learning_rate(lr)
    self.learner.opt_critic.set_learning_rate(lr)
    self.step_accumulator += 1.0 / options.update_to_data
    let collect_steps = self.step_accumulator.to_int()
    self.step_accumulator -= collect_steps.to_double()
    self.collect(collect_steps, inspect_env, step_env, options.action_noise)
    let actor_readiness = if it >= options.world_only_iterations {
      Some(
        self.replay.ensure_actor_ready(
          f => self.learner.motion.clip_end[self.learner.motion.clip_id[f]],
          c.horizon,
          c.wm_window,
          steps => {
            self.collect(steps, inspect_env, step_env, options.action_noise)
          },
          context=self.actor_catalog + "; iteration=\{it + 1}",
        ),
      )
    } else {
      None
    }
    let world = self.learner.fit_world_model(self.replay)
    self.counters.model_updates += c.wm_batches
    self.counters.model_fit_transition_slots += c.wm_batches *
      c.wm_batch *
      c.wm_window
    let policy = if it >= options.world_only_iterations {
      let metrics = self.learner.update_policy(self.replay)
      self.counters.actor_updates += 1
      self.counters.critic_updates += metrics.critic_updates
      self.counters.imagined_transitions += metrics.imagined_steps
      Some(metrics)
    } else {
      None
    }
    self.iteration = it + 1
    on_iteration({
      iteration: it + 1,
      learning_rate: lr,
      world,
      policy,
      actor_readiness,
    })
  }
}

///|
pub fn TrainingRunner::checkpoint(
  self : TrainingRunner,
  identity : Json,
  environment : Json,
) -> TrainingCheckpoint {
  {
    identity,
    learner: self.learner.snapshot(),
    replay: self.replay.snapshot(),
    environment,
    histories: self.histories.map(h => h.map(row => row.copy())),
    iteration: self.iteration,
    counters: { ..self.counters, },
    step_accumulator: self.step_accumulator,
  }
}

///|
pub fn TrainingRunner::restore(
  self : TrainingRunner,
  saved : TrainingCheckpoint,
  exact_physics_resume : Bool,
) -> Unit raise {
  self.learner.restore(saved.learner)
  self.iteration = saved.iteration
  self.step_accumulator = saved.step_accumulator
  let c = self.counters
  c.physical_transitions = saved.counters.physical_transitions
  c.imagined_transitions = saved.counters.imagined_transitions
  c.actor_updates = saved.counters.actor_updates
  c.model_updates = saved.counters.model_updates
  c.critic_updates = saved.counters.critic_updates
  c.model_fit_transition_slots = saved.counters.model_fit_transition_slots
  guard saved.histories.length() == self.histories.length() else {
    fail("checkpoint environment count differs")
  }
  if exact_physics_resume {
    self.replay.restore(saved.replay)
    for i, h in saved.histories {
      self.histories[i] = h.map(row => row.copy())
    }
  } else {
    self.replay.restore([])
    for i in 0..<self.histories.length() {
      self.histories[i] = []
    }
  }
}
