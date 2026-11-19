///|
pub(all) struct ScheduledCase {
  case : @native_physics.Case
  offset : Array[Double]?
  schedule : @native_physics.JointSines?
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct PhysicsConfig {
  cases : Array[ScheduledCase]
  seconds : Double
  dt : Double
  gamma : Double
  target_height : Double
  collect_seed_base : Int32
  validation_seeds : Array[Int32]
  test_seeds : Array[Int32]
  iterations : Int32
  epochs : Int32
  minibatch_size : Int32
  raw_action_std : Double
  clip_ratio : Double
  target_kl : Double
  actor_learning_rate : Double
  critic_learning_rate : Double
  seed : UInt32
} derive(Debug, FromJson, ToJson)

///|
pub fn evaluate_scheduled(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  cases : Array[ScheduledCase],
  seeds : Array[Int32],
  seconds : Double,
  dt : Double,
  rng : @numeric.Rng,
  split : String,
) -> (@training.PhysicsSummary, Array[@native_physics.Trial]) raise {
  let trials : Array[@native_physics.Trial] = []
  for configured in cases {
    if configured.case.split != split {
      continue
    }
    for reset_seed in seeds {
      let (_, trial) = rollout(
        runtime,
        actor,
        configured.case,
        reset_seed,
        seconds,
        dt,
        rng,
        offset?=configured.offset,
        schedule?=configured.schedule,
      )
      trials.push(trial)
    }
  }
  guard !trials.is_empty() else {
    fail("no cases or seeds for physics split: " + split)
  }
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
  ({ falls, survival_s, joint_rmse_rad, }, trials)
}

///|
fn summary_json(summary : @training.PhysicsSummary) -> Json {
  {
    "falls": summary.falls.to_json(),
    "mean_survival_s": summary.survival_s.to_json(),
    "mean_joint_rmse_rad": summary.joint_rmse_rad.to_json(),
  }
}

///|
/// Complete actual-physics temporal PPO driver: paired incoming actor/value, train-only collection, full-batch KL-constrained optimization, validation-only selection, best/latest checkpoints, reload and held-out test report. Library and scene are explicit native dependencies.
pub async fn run_ppo(
  library : String,
  scene : String,
  actor_path : String,
  value_path : String,
  config_path : String,
  output : String,
) -> Json {
  let config : PhysicsConfig = @json.from_json(
    @json.parse(@fs.read_file(config_path).text()),
  )
  guard config.iterations >= 0 && config.seconds > 0.0 && config.dt > 0.0 else {
    fail("invalid temporal physics configuration")
  }
  let actor = @temporal.load_temporal(actor_path)
  let actor_sha = @artifacts.sha256(@fs.read_file(actor_path).binary())
  let value = @temporal.load_paired_value(value_path, actor_sha)
  guard value.dt == config.dt &&
    value.gamma == config.gamma &&
    value.duration == config.seconds else {
    fail(
      "PPO physical cadence, discount or task duration differs from calibrated value",
    )
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let collection_rng = @numeric.Rng::new(config.seed)
  let optimizer_rng = @numeric.Rng::new(config.seed + 1U)
  let actor_optimizer = @numeric.Adam::new(
    actor.parameters().length(),
    config.actor_learning_rate,
  )
  let value_optimizer = @numeric.Adam::new(
    value.net.parameters.length(),
    config.critic_learning_rate,
  )
  let (baseline, _) = evaluate_scheduled(
    runtime,
    actor,
    config.cases,
    config.validation_seeds,
    config.seconds,
    config.dt,
    @numeric.Rng::new(config.seed + 2U),
    "validation",
  )
  let mut best = baseline
  let mut best_actor = actor.parameters()
  let mut best_value = value.net.parameters.copy()
  let mut selected = 0
  let history : Array[Json] = [
    { "iteration": 0, "validation": summary_json(baseline) },
  ]
  let mut transitions = 0
  let mut falls = 0
  for iteration in 0..<config.iterations {
    let batch : Array[@temporal.TemporalPPOSample] = []
    let episodes : Array[@native_physics.Episode] = []
    let reset_seed = config.collect_seed_base + iteration
    for configured in config.cases {
      if configured.case.split != "train" {
        continue
      }
      let (samples, episode, trial) = collect_ppo(
        runtime,
        actor,
        value,
        configured.case,
        reset_seed,
        config.seconds,
        config.dt,
        config.gamma,
        config.target_height,
        config.raw_action_std,
        collection_rng,
        offset?=configured.offset,
        schedule?=configured.schedule,
      )
      batch.append(samples)
      episodes.push(episode)
      if trial.failed {
        falls += 1
      }
    }
    guard !batch.is_empty() else {
      fail("no train cases produced temporal PPO samples")
    }
    transitions += batch.length()
    let losses = @temporal.optimize(
      actor,
      value,
      actor_optimizer,
      value_optimizer,
      batch,
      {
        epochs: config.epochs,
        minibatch_size: config.minibatch_size,
        raw_action_std: config.raw_action_std,
        target_kl: config.target_kl,
        clip_ratio: config.clip_ratio,
      },
      optimizer_rng,
    )
    let (current, _) = evaluate_scheduled(
      runtime,
      actor,
      config.cases,
      config.validation_seeds,
      config.seconds,
      config.dt,
      @numeric.Rng::new(config.seed + 2U),
      "validation",
    )
    if @training.ranks_above(current, best) {
      best = current
      best_actor = actor.parameters()
      best_value = value.net.parameters.copy()
      selected = iteration + 1
    }
    let row : Json = {
      "iteration": (iteration + 1).to_json(),
      "transitions": transitions.to_json(),
      "falls": falls.to_json(),
      "validation": summary_json(current),
      "losses": losses.to_json(),
    }
    history.push(row)
    // Persist every actual collection, including unclipped latent samples and behavior means, for deferred parity tests.
    let log : Json = {
      "iteration": (iteration + 1).to_json(),
      "dataset": runtime.dataset(episodes, "moonbit-temporal-ppo", dt=config.dt),
      "samples": batch.to_json(),
    }
    @fs.write_file(
      output + ".iteration-" + iteration.to_string() + ".json",
      @utf8.encode(log.stringify()),
      create_mode=CreateOrTruncate,
    )
  }
  let provenance : Json = {
    "config": config.to_json(),
    "incoming_actor": actor_path.to_json(),
    "incoming_value": value_path.to_json(),
    "selected_update": selected.to_json(),
    "physical_execution_allowed": false,
    "rng": "MoonBit xorshift32; not Torch-equivalent",
    "precision": "float64",
  }
  ignore(
    @temporal.save_temporal(output + ".latest-actor.json", actor, provenance),
  )
  ignore(@temporal.save_value(output + ".latest-value.json", value, provenance))
  actor.restore(best_actor)
  for i in 0..<best_value.length() {
    value.net.parameters[i] = best_value[i]
  }
  let actor_digest = @temporal.save_temporal(
    output + ".actor.json",
    actor,
    provenance,
  )
  let value_digest = @temporal.save_value(
    output + ".value.json",
    value,
    provenance,
  )
  let restored = @temporal.load_temporal(output + ".actor.json")
  guard restored.parameters() == actor.parameters() else {
    fail("temporal PPO actor reload differs")
  }
  let restored_value = @temporal.load_value(output + ".value.json")
  guard restored_value.net.parameters == value.net.parameters else {
    fail("temporal PPO value reload differs")
  }
  let (test_summary, trials) = evaluate_scheduled(
    runtime,
    restored,
    config.cases,
    config.test_seeds,
    config.seconds,
    config.dt,
    @numeric.Rng::new(config.seed + 3U),
    "test",
  )
  let report : Json = {
    "format": "moonrobo.moonbit-temporal-ppo-fit.v1",
    "algorithm": "temporal-ppo-physics",
    "selected_iteration": selected.to_json(),
    "training_transitions": transitions.to_json(),
    "training_falls": falls.to_json(),
    "history": history.to_json(),
    "test": summary_json(test_summary),
    "test_trials": trials.to_json(),
    "actor_sha256": actor_digest.to_json(),
    "value_sha256": value_digest.to_json(),
    "checkpoint_selection": "validation-physics-only",
    "reload_matches": true,
    "physical_execution_allowed": false,
    "parity_verified": false,
  }
  @fs.write_file(
    output + ".report.json",
    @utf8.encode(report.stringify()),
    create_mode=CreateOrTruncate,
  )
  report
}
