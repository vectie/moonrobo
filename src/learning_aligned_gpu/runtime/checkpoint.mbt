///|
/// Host orchestration state only. Publish together with a matching immutable
/// learner/optimizer generation and the physical adapter checkpoint.
pub(all) struct RuntimeSnapshot {
  format : String
  config : @aligned.LearnerConfig
  observation_mode : String
  motion_names : Array[String]
  motion_sha256 : Array[String]
  source_fps : Double
  capacity : Int32
  num_envs : Int32
  iteration : Int32
  step_accumulator : Double
  counters : TrainingCounters
  rng : UInt32
  histories : Array[Array[Array[Double]]]
  replay : Array[Array[@aligned.Transition]]
  distributed : DistributedRankSnapshot?
} derive(ToJson, FromJson)

///|
fn mode_name(mode : @aligned.ObservationMode) -> String {
  match mode {
    Paper => "paper"
    Smc => "smc"
    Observable => "observable"
  }
}

///|
/// Snapshot copies bounded host replay. Budget temporary replay + serialized
/// output in addition to live training memory when publishing checkpoints.
pub fn TrainingRunner::snapshot(self : TrainingRunner) -> RuntimeSnapshot {
  {
    format: "moonrobo-aligned-gpu-runtime-v1",
    config: self.learner.config,
    observation_mode: mode_name(self.learner.mode),
    motion_names: self.motion.names.copy(),
    motion_sha256: self.motion.source_sha256.copy(),
    source_fps: self.motion.source_fps,
    capacity: self.capacity,
    num_envs: self.num_envs,
    iteration: self.iteration,
    step_accumulator: self.step_accumulator,
    counters: { ..self.counters, },
    rng: self.rng.state(),
    histories: self.histories.map(h => h.map(row => row.copy())),
    replay: self.replay.snapshot(),
    distributed: self.distributed_snapshot(),
  }
}

///|
/// Exact resume requires the caller to restore matching physics and learner
/// checkpoints too. Without physical state, replay/history are cleared and run
/// refills at least a complete model window before any sample.
pub fn TrainingRunner::restore(
  self : TrainingRunner,
  saved : RuntimeSnapshot,
  exact_physics_resume : Bool,
) -> Unit raise {
  guard self.learner.collective is None && saved.distributed is None else {
    fail(
      "native distributed resume is unsupported: rank-local replay/physics and equal optimizer-state verification are required",
    )
  }
  guard saved.format == "moonrobo-aligned-gpu-runtime-v1" &&
    saved.config.to_json() == self.learner.config.to_json() &&
    saved.observation_mode == mode_name(self.learner.mode) &&
    saved.motion_names == self.motion.names &&
    saved.motion_sha256 == self.motion.source_sha256 &&
    saved.source_fps == self.motion.source_fps &&
    saved.capacity == self.capacity &&
    saved.num_envs == self.num_envs &&
    saved.rng != 0U &&
    saved.histories.length() == self.num_envs &&
    saved.replay.length() <= self.capacity &&
    saved.iteration >= 0 &&
    @numeric.finite(saved.step_accumulator) &&
    saved.step_accumulator >= 0.0 &&
    saved.step_accumulator < 1.0 else {
    fail(
      "incompatible GPU runtime checkpoint configuration, motion catalog, or counters",
    )
  }
  let counts = saved.counters
  guard counts.physical_transitions >= 0L &&
    counts.imagined_transitions >= 0L &&
    counts.actor_updates >= 0L &&
    counts.model_updates >= 0L &&
    counts.critic_updates >= 0L &&
    counts.model_fit_transition_slots >= 0L else {
    fail("negative runtime checkpoint counters")
  }
  for history in saved.histories {
    guard history.is_empty() || history.length() == self.learner.config.hist else {
      fail("checkpoint observation history length differs")
    }
    for row in history {
      guard row.length() == self.learner.mode.dim() && row.all(@numeric.finite) else {
        fail("invalid checkpoint observation history")
      }
    }
  }
  for row in saved.replay {
    guard row.length() == self.num_envs else {
      fail("checkpoint replay environment count differs")
    }
    for tr in row {
      validate_transition(tr, self.motion)
    }
  }
  // Validate all metadata before mutating a live runner.
  self.iteration = saved.iteration
  self.step_accumulator = saved.step_accumulator
  self.rng.set_state(saved.rng)
  self.counters.physical_transitions = counts.physical_transitions
  self.counters.imagined_transitions = counts.imagined_transitions
  self.counters.actor_updates = counts.actor_updates
  self.counters.model_updates = counts.model_updates
  self.counters.critic_updates = counts.critic_updates
  self.counters.model_fit_transition_slots = counts.model_fit_transition_slots
  if exact_physics_resume {
    self.replay.restore(saved.replay)
    for i, history in saved.histories {
      self.histories[i] = history.map(row => row.copy())
    }
  } else {
    self.replay.restore([])
    for i in 0..<self.num_envs {
      self.histories[i] = []
    }
  }
}
