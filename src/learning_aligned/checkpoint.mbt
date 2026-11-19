///|
pub(all) struct NormSnapshot {
  mean : Array[Double]
  variance : Array[Double]
  count : Double
} derive(Debug, ToJson, FromJson)

///|
fn RunningNorm::save(self : RunningNorm) -> NormSnapshot {
  let (mean, variance, count) = self.snapshot()
  { mean, variance, count, }
}

///|
fn RunningNorm::load(self : RunningNorm, saved : NormSnapshot) -> Unit raise {
  self.restore(saved.mean, saved.variance, saved.count)
}

///|
pub(all) struct LearnerSnapshot {
  config : LearnerConfig
  parameters : Array[Array[Double]]
  norms : Array[NormSnapshot]
  optimizers : Array[@numeric.Adam]
  rng : UInt32
} derive(ToJson, FromJson)

///|
pub fn Learner::snapshot(self : Learner) -> LearnerSnapshot {
  {
    config: self.config,
    parameters: [
      self.wm.net.parameters.copy(),
      self.policy.encoder.parameters.copy(),
      self.policy.decoder.parameters.copy(),
      self.critic.net.parameters.copy(),
    ],
    norms: [
      self.wm.input_norm.save(),
      self.wm.output_norm.save(),
      self.policy.obs_norm.save(),
      self.policy.goal_norm.save(),
      self.critic.norm.save(),
    ],
    optimizers: [
      self.opt_wm.snapshot(),
      self.opt_policy.snapshot(),
      self.opt_critic.snapshot(),
    ],
    rng: self.rng.state(),
  }
}

///|
pub fn Learner::restore(
  self : Learner,
  snapshot : LearnerSnapshot,
) -> Unit raise {
  guard snapshot.config.to_json() == self.config.to_json() &&
    snapshot.parameters.length() == 4 &&
    snapshot.norms.length() == 5 &&
    snapshot.optimizers.length() == 3 else {
    fail("incompatible aligned learner checkpoint")
  }
  let models = [
    self.wm.net,
    self.policy.encoder,
    self.policy.decoder,
    self.critic.net,
  ]
  for i, net in models {
    guard net.parameters.length() == snapshot.parameters[i].length() &&
      snapshot.parameters[i].all(finite) else {
      fail("incompatible network checkpoint shape or values")
    }
  }
  for i, net in models {
    for j, v in snapshot.parameters[i] {
      net.parameters[j] = v
    }
  }
  let norms = [
    self.wm.input_norm,
    self.wm.output_norm,
    self.policy.obs_norm,
    self.policy.goal_norm,
    self.critic.norm,
  ]
  for i, norm in norms {
    norm.load(snapshot.norms[i])
  }
  self.opt_wm.restore(snapshot.optimizers[0])
  self.opt_policy.restore(snapshot.optimizers[1])
  self.opt_critic.restore(snapshot.optimizers[2])
  self.rng.set_state(snapshot.rng)
}

///|
pub(all) struct TrainingCheckpoint {
  identity : Json
  learner : LearnerSnapshot
  replay : Array[Array[Transition]]
  environment : Json
  histories : Array[Array[Array[Double]]]
  iteration : Int32
  counters : TrainingCounters
  step_accumulator : Double
} derive(ToJson, FromJson)

///|
pub async fn save_training_checkpoint(
  path : String,
  saved : TrainingCheckpoint,
) -> String {
  let checkpoint = @artifacts.Checkpoint::new(
    "aligned-supermimic",
    saved.to_json(),
  )
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
pub async fn load_training_checkpoint(
  path : String,
  identity : Json,
) -> TrainingCheckpoint {
  let checkpoint = @artifacts.load_checkpoint(path, "aligned-supermimic")
  let saved : TrainingCheckpoint = @json.from_json(checkpoint.metadata)
  guard saved.identity == identity else {
    fail(
      "resume requires identical scene, catalog hashes, backend and physics settings",
    )
  }
  saved
}
