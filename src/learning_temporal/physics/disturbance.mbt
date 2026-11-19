///|
pub(all) struct LabeledCollection {
  episodes : Array[@native_physics.Episode]
  teacher_targets : Array[Array[Array[Double]]]
  latent_samples : Array[Array[Array[Double]]]
  trials : Array[@native_physics.Trial]
  points : Array[@temporal.TemporalPoint]
} derive(Debug, ToJson)

///|
/// Train-family labeling on clean or disturbed student rollouts. Teacher targets are separate labels; applied_action always remains the student's physically executed setpoint.
pub fn collect_labeled(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Array[ScheduledCase],
  reset_seeds : Array[Int32],
  noise_seed : UInt32,
  latent_std : Double,
  seconds : Double,
  dt : Double,
  teacher_parameters : @balance.FeedbackParameters?,
  teacher_factory? : () -> (Array[Double], Array[Double]) -> Array[Double],
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> LabeledCollection raise {
  guard latent_std >= 0.0 else { fail("negative latent disturbance") }
  let episodes : Array[@native_physics.Episode] = []
  let teacher_targets : Array[Array[Array[Double]]] = []
  let latent_samples : Array[Array[Array[Double]]] = []
  let trials : Array[@native_physics.Trial] = []
  let points : Array[@temporal.TemporalPoint] = []
  for case_index, configured in collection {
    let case = configured.case
    guard case.split == "train" else {
      fail("disturbance collection accepts training families only")
    }
    for seed_index, reset in reset_seeds {
      let teacher = match teacher_parameters {
        Some(parameters) =>
          Some(
            @balance_native.NativeBalanceTeacher::new(runtime, parameters, dt),
          )
        None => None
      }
      let label_policy = teacher_factory.map(fn(factory) { factory() })
      let generator = @numeric.Rng::new(
        noise_seed + (2 * case_index + seed_index).to_uint(),
      )
      let reset_generator = @numeric.Rng::new(reset.to_uint())
      let frames : Array[Array[Double]] = []
      let targets : Array[Array[Double]] = []
      let samples : Array[Array[Double]] = []
      let captured : Array[@temporal.TemporalPoint] = []
      let mut nominal : Array[Double] = []
      let mut index = 0
      let policy = fn(
        obs : Array[Double],
        goal : Array[Double],
      ) -> Array[Double] {
        if label_policy is Some(label) {
          targets.push(label(obs, goal))
        } else if teacher is Some(teacher) {
          targets.push(try! teacher.predict(obs, goal))
        }
        if frames.is_empty() {
          nominal = Array::makei(goal.length(), fn(i) { obs[i] })
          for _ in 0..<actor.temporal.history_length {
            frames.push(obs.copy())
          }
        } else {
          frames.remove(0) |> ignore
          frames.push(obs.copy())
        }
        let future = Array::makei(actor.temporal.future_length, fn(j) {
          try! runtime.reference(
            nominal,
            case.motion,
            (index + j + 1).to_double() * dt,
            offset?=configured.offset,
            schedule?=configured.schedule,
          )
        })
        captured.push({
          history: frames.map(fn(row) { row.copy() }),
          goal: goal.copy(),
          future,
          target: [],
        })
        let tape = @numeric.Tape::new()
        let mean = actor.latent_mean(
          tape,
          tape.vector(actor.parameters()),
          frames.map(fn(row) { tape.vector(row) }),
          tape.vector(goal),
          future.map(fn(row) { tape.vector(row) }),
        )
        let latent = mean.map(fn(v) {
          v.value + latent_std * generator.normal()
        })
        samples.push(latent)
        index += 1
        actor.base
        .action_from_latent(tape, tape.vector(latent), tape.vector(goal))
        .map(fn(v) { v.value })
      }
      let (episode, trial) = runtime.rollout(
        case,
        reset,
        "policy",
        seconds,
        dt,
        fn() { reset_generator.normal() },
        policy~,
        offset?=configured.offset,
        schedule?=configured.schedule,
        fall_height~,
        fall_upright~,
      )
      let reference = fn(time : Double) {
        try! runtime.reference(
          nominal,
          case.motion,
          time,
          offset?=configured.offset,
          schedule?=configured.schedule,
        )
      }
      let extracted = episode_points(
        episode,
        actor.temporal.history_length,
        actor.temporal.future_length,
        dt,
        reference,
        targets?=if teacher.is_some() || label_policy.is_some() {
          Some(targets)
        } else {
          None
        },
      )
      for i, point in extracted {
        guard point.history == captured[i].history &&
          point.goal == captured[i].goal &&
          point.future == captured[i].future else {
          fail("disturbance offline/online causal inputs differ")
        }
        let tape = @numeric.Tape::new()
        let expected = actor.base
          .action_from_latent(
            tape,
            tape.vector(samples[i]),
            tape.vector(point.goal),
          )
          .map(fn(v) { v.value })
        guard expected == episode.steps[i].applied_action else {
          fail("stored action differs from sampled latent command")
        }
      }
      episodes.push(episode)
      teacher_targets.push(targets)
      latent_samples.push(samples)
      trials.push(trial)
      points.append(extracted)
    }
  }
  { episodes, teacher_targets, latent_samples, trials, points, }
}

///|
fn summarize(trials : Array[@native_physics.Trial]) -> @training.PhysicsSummary {
  guard !trials.is_empty() else { abort("empty temporal physical summary") }
  let mut falls = 0
  let mut survival_s = 0.0
  let mut joint_rmse_rad = 0.0
  for t in trials {
    if t.failed {
      falls += 1
    }
    survival_s += t.simulated_seconds / trials.length().to_double()
    joint_rmse_rad += t.joint_rmse_rad / trials.length().to_double()
  }
  { falls, survival_s, joint_rmse_rad, }
}

///|
pub fn select_score(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Array[ScheduledCase],
  experiment : Array[ScheduledCase],
  reset_seed : Int32,
  noise_seed : UInt32,
  selection_std : Double,
  validation_seeds : Array[Int32],
  seconds : Double,
  dt : Double,
) -> (@training.PhysicsSummary, Json) raise {
  let training = collect_labeled(
    runtime,
    actor,
    collection,
    [reset_seed],
    noise_seed,
    selection_std,
    seconds,
    dt,
    None,
  )
  let (validation, validation_trials) = evaluate_scheduled(
    runtime,
    actor,
    experiment,
    validation_seeds,
    seconds,
    dt,
    @numeric.Rng::new(noise_seed),
    "validation",
  )
  let trials = training.trials.copy()
  trials.append(validation_trials)
  let result = summarize(trials)
  (
    result,
    {
      "summary": summary_json(result),
      "training_audit": summary_json(summarize(training.trials)),
      "validation": summary_json(validation),
      "trials": trials.to_json(),
    },
  )
}

///|
pub fn audit(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Array[ScheduledCase],
  reset_seed : Int32,
  noise_seed : UInt32,
  latent_stds : Array[Double],
  seconds : Double,
  dt : Double,
  role : String,
) -> Array[Json] raise {
  latent_stds.map(fn(std) {
    let checked = collect_labeled(
      runtime,
      actor,
      collection,
      [reset_seed],
      noise_seed,
      std,
      seconds,
      dt,
      None,
    )
    {
      "role": role.to_json(),
      "latent_std": std.to_json(),
      "dataset": runtime.dataset(
        checked.episodes,
        "moonbit-temporal-disturbance",
        dt~,
      ),
      "summary": summary_json(summarize(checked.trials)),
      "trials": checked.trials.to_json(),
    }
  })
}

///|
pub(all) struct DisturbanceRunConfig {
  collection : Array[ScheduledCase]
  experiment : Array[ScheduledCase]
  teacher : @balance.FeedbackParameters
  teacher_provider_sha256 : String
  duration_s : Double
  dt : Double
  rounds : Int32
  updates_per_round : Int32
  batch_size : Int32
  recent_points : Int32
  actor_learning_rate : Double
  collection_latent_std : Double
  selection_latent_std : Double
  audit_latent_stds : Array[Double]
  collection_seed_base : Int32
  selection_seed : Int32
  audit_seed : Int32
  noise_seed : UInt32
  sampling_seed : UInt32
  validation_seeds : Array[Int32]
  test_seeds : Array[Int32]
} derive(Debug, ToJson, FromJson)

///|
/// Actual teacher-labeled student-state aggregation, with optional latent disturbance and train-audit plus validation selection. No canonical/test/audit labels enter optimization.
pub async fn run_disturbance(
  library : String,
  scene : String,
  incoming : String,
  original_path : String,
  config_path : String,
  teacher_source : String,
  output : String,
) -> Json {
  let config : DisturbanceRunConfig = @json.from_json(
    @artifacts.load_json(config_path),
  )
  let original : @temporal.TemporalDataset = @json.from_json(
    @artifacts.load_json(original_path),
  )
  guard original.split == "train" &&
    !original.points.is_empty() &&
    config.batch_size > 0 &&
    config.recent_points > 0 &&
    config.rounds >= 0 else {
    fail("invalid disturbance train corpus or optimizer config")
  }
  guard @artifacts.sha256(@fs.read_file(teacher_source).binary()) ==
    config.teacher_provider_sha256 else {
    fail("teacher provider implementation changed")
  }
  let actor = @temporal.load_temporal(incoming)
  let initial = actor.parameters()
  let runtime = @native_physics.Runtime::open(library, scene)
  let rng = @numeric.Rng::new(config.sampling_seed)
  let optimizer = @numeric.Adam::new(
    initial.length(),
    config.actor_learning_rate,
  )
  let recent : Array[@temporal.TemporalPoint] = []
  let (initial_score, initial_evidence) = select_score(
    runtime,
    actor,
    config.collection,
    config.experiment,
    config.selection_seed,
    config.noise_seed,
    config.selection_latent_std,
    config.validation_seeds,
    config.duration_s,
    config.dt,
  )
  let mut best = initial_score
  let mut best_weights = initial
  let mut selected = 0
  let mut transitions = 0
  let mut falls = 0
  let history : Array[Json] = [{ "round": 0, "selection": initial_evidence }]
  let logs : Array[Json] = []
  for round in 0..<config.rounds {
    let reset = config.collection_seed_base + 2 * round
    let fresh = collect_labeled(
      runtime,
      actor,
      config.collection,
      [reset, reset + 1],
      config.noise_seed + round.to_uint(),
      config.collection_latent_std,
      config.duration_s,
      config.dt,
      Some(config.teacher),
    )
    transitions += fresh.points.length()
    for trial in fresh.trials {
      if trial.failed {
        falls += 1
      }
    }
    recent.append(fresh.points)
    while recent.length() > config.recent_points {
      recent.remove(0) |> ignore
    }
    guard !recent.is_empty() else {
      fail("disturbance collection produced no training labels")
    }
    logs.push({
      "round": (round + 1).to_json(),
      "dataset": runtime.dataset(
        fresh.episodes,
        "moonbit-temporal-disturbance",
        dt=config.dt,
      ),
      "teacher_action_targets": fresh.teacher_targets.to_json(),
      "latent_samples": fresh.latent_samples.to_json(),
      "maximum_input_alignment_error": 0.0,
    })
    ignore(@artifacts.save_jsonl(output + ".physics.jsonl.gz", logs))
    let mut loss = 0.0
    for _ in 0..<config.updates_per_round {
      let batch = Array::makei(config.batch_size, fn(i) {
        if i < config.batch_size / 2 {
          original.points[rng.index(original.points.length())]
        } else {
          recent[rng.index(recent.length())]
        }
      })
      loss = actor.clone_update(optimizer, batch)
    }
    let (current, evidence) = select_score(
      runtime,
      actor,
      config.collection,
      config.experiment,
      config.selection_seed,
      config.noise_seed,
      config.selection_latent_std,
      config.validation_seeds,
      config.duration_s,
      config.dt,
    )
    if @training.ranks_above(current, best) {
      best = current
      best_weights = actor.parameters()
      selected = round + 1
    }
    history.push({
      "round": (round + 1).to_json(),
      "selection": evidence,
      "action_loss": loss.to_json(),
      "transitions": transitions.to_json(),
      "falls": falls.to_json(),
    })
  }
  let metadata : Json = {
    "config": config.to_json(),
    "incoming_actor": incoming.to_json(),
    "original_data_sha256": @artifacts.sha256(
      @fs.read_file(original_path).binary(),
    ).to_json(),
    "teacher_source_sha256": config.teacher_provider_sha256.to_json(),
    "selected_round": selected.to_json(),
    "physical_execution_allowed": false,
    "precision": "float64",
    "rng": "MoonBit xorshift32; not Torch-equivalent",
  }
  ignore(
    @temporal.save_temporal(output + ".latest-actor.json", actor, metadata),
  )
  actor.restore(initial)
  let (baseline, baseline_trials) = evaluate_scheduled(
    runtime,
    actor,
    config.experiment,
    config.test_seeds,
    config.duration_s,
    config.dt,
    @numeric.Rng::new(config.noise_seed),
    "test",
  )
  let baseline_audit = audit(
    runtime,
    actor,
    config.collection,
    config.audit_seed,
    config.noise_seed,
    config.audit_latent_stds,
    config.duration_s,
    config.dt,
    "incoming",
  )
  actor.restore(best_weights)
  let digest = @temporal.save_temporal(output + ".actor.json", actor, metadata)
  let restored = @temporal.load_temporal(output + ".actor.json")
  guard restored.parameters() == actor.parameters() else {
    fail("disturbance selected checkpoint reload differs")
  }
  let (candidate, candidate_trials) = evaluate_scheduled(
    runtime,
    restored,
    config.experiment,
    config.test_seeds,
    config.duration_s,
    config.dt,
    @numeric.Rng::new(config.noise_seed),
    "test",
  )
  let candidate_audit = audit(
    runtime,
    restored,
    config.collection,
    config.audit_seed,
    config.noise_seed,
    config.audit_latent_stds,
    config.duration_s,
    config.dt,
    "candidate",
  )
  ignore(
    @artifacts.save_jsonl(
      output + ".audit.jsonl.gz",
      baseline_audit + candidate_audit,
    ),
  )
  let report : Json = {
    "format": "moonrobo.moonbit-temporal-disturbance-fit.v1",
    "selected_round": selected.to_json(),
    "history": history.to_json(),
    "training_transitions": transitions.to_json(),
    "training_falls": falls.to_json(),
    "baseline": summary_json(baseline),
    "baseline_trials": baseline_trials.to_json(),
    "candidate": summary_json(candidate),
    "candidate_trials": candidate_trials.to_json(),
    "checkpoint_sha256": digest.to_json(),
    "reload_matches": true,
    "physical_execution_allowed": false,
    "parity_verified": false,
  }
  ignore(@artifacts.save_json(output + ".report.json", report))
  report
}
