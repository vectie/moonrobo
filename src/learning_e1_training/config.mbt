///|
pub(all) struct Config {
  format : String
  learner : @aligned.LearnerConfig
  environments : Int32
  replay_steps : Int32
  seed : Int32
  warmup_steps : Int32
  world_only_iterations : Int32
  update_to_data : Double
  checkpoint_every : Int32
  action_noise : Double
  randomization : Bool
  reset_noise : Bool
  max_episode_steps : Int32
  world_microbatch : Int32
  actor_microbatch : Int32
  learning_rate_decay_iterations : Int32?
} derive(ToJson, FromJson)

///|
pub fn Config::smoke() -> Config {
  {
    format: "moonrobo.e1-training-config.v1",
    learner: {
      ..@aligned.LearnerConfig::default(),
      wm_hidden: [32],
      policy_hidden: [32],
      critic_hidden: [16],
      horizon: 4,
      wm_window: 2,
      wm_batches: 1,
      wm_batch: 2,
      policy_batch: 2,
      critic_epochs: 1,
      critic_minibatches: 1,
      observation_noise: false,
    },
    environments: 1,
    replay_steps: 64,
    seed: 1,
    warmup_steps: 8,
    world_only_iterations: 0,
    update_to_data: 0.4,
    checkpoint_every: 1,
    action_noise: 0.1,
    randomization: false,
    reset_noise: false,
    max_episode_steps: 500,
    world_microbatch: 0,
    actor_microbatch: 0,
    learning_rate_decay_iterations: None,
  }
}

///|
pub fn Config::training() -> Config {
  {
    ..Config::smoke(),
    learner: {
      ..@aligned.LearnerConfig::default(),
      wm_batch: 256,
      policy_batch: 512,
    },
    environments: 128,
    update_to_data: 0.1,
    replay_steps: 1000,
    warmup_steps: 64,
    world_only_iterations: 500,
    checkpoint_every: 100,
    randomization: true,
    reset_noise: true,
    world_microbatch: 64,
    actor_microbatch: 64,
    learning_rate_decay_iterations: Some(14000),
  }
}

///|
/// Full training architecture/horizons with actor updates enabled immediately
/// for bounded integration validation; production retains world-only warm-up.
pub fn Config::method_gate() -> Config {
  { ..Config::training(), world_only_iterations: 0, checkpoint_every: 1, }
}

///|
pub fn Config::validate(self : Config) -> Unit raise {
  let c = self.learner
  guard self.format == "moonrobo.e1-training-config.v1" &&
    self.environments > 0 &&
    self.environments <= 128 &&
    self.replay_steps >= c.wm_window &&
    self.replay_steps <= 4096 &&
    self.environments.to_int64() * self.replay_steps.to_int64() * 241L <=
    67108864L &&
    self.seed >= 0 &&
    self.warmup_steps >= 0 &&
    self.world_only_iterations >= 0 &&
    self.learning_rate_decay_iterations.unwrap_or(250000) > 0 &&
    self.checkpoint_every > 0 &&
    self.max_episode_steps > c.horizon &&
    self.action_noise >= 0.0 &&
    @numeric.finite(self.action_noise) &&
    self.world_microbatch >= 0 &&
    self.world_microbatch <= c.wm_batch &&
    self.actor_microbatch >= 0 &&
    self.actor_microbatch <= c.policy_batch &&
    self.update_to_data > 0.0 &&
    @numeric.finite(self.update_to_data) &&
    c.hist == 10 &&
    c.goal_frames == 10 &&
    c.horizon > 0 &&
    c.horizon <= 32 &&
    c.wm_window > 0 &&
    c.wm_window <= 8 &&
    c.wm_batch > 0 &&
    c.wm_batch <= 512 &&
    c.policy_batch > 0 &&
    c.policy_batch <= 512 &&
    c.wm_batches > 0 &&
    c.wm_batches <= 10 &&
    c.critic_epochs > 0 &&
    c.critic_epochs <= 5 &&
    c.critic_minibatches > 0 &&
    c.critic_minibatches <= 4 &&
    @numeric.finite(c.learning_rate) &&
    c.learning_rate > 0.0 &&
    c.gamma > 0.0 &&
    c.gamma < 1.0 &&
    c.lam >= 0.0 &&
    c.lam <= 1.0 &&
    [c.wm_hidden, c.policy_hidden, c.critic_hidden].all(x => {
      !x.is_empty() && x.length() <= 4 && x.all(n => n > 0 && n <= 2048)
    }) else {
    fail("E1 config exceeds the bounded native training profile")
  }
}

///|
pub fn Config::options(
  self : Config,
  iterations : Int32,
) -> @aligned.TrainingOptions {
  {
    iterations,
    warmup_steps: self.warmup_steps,
    world_only_iterations: self.world_only_iterations,
    update_to_data: self.update_to_data,
    learning_rate_decay_iterations: self.learning_rate_decay_iterations.unwrap_or(
      250000,
    ),
    action_noise: self.action_noise,
  }
}
