///|
/// Join train-only labeled collections without changing per-case/reset RNG
/// streams. Source schedules are reconstructed at each actual reset.
fn study_collect(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Json,
  resets : Array[Int32],
  noise_seed : UInt32,
  std : Double,
  parameters : @balance.FeedbackParameters?,
  config : Json,
) -> LabeledCollection raise {
  let episodes : Array[@native_physics.Episode] = []
  let teacher_targets : Array[Array[Array[Double]]] = []
  let latent_samples : Array[Array[Array[Double]]] = []
  let trials : Array[@native_physics.Trial] = []
  let points : Array[@temporal.TemporalPoint] = []
  for case_index, raw in study_cases(collection, false) {
    let case : @native_physics.Case = @json.from_json(raw)
    guard case.split == "train" else {
      fail("disturbance collection includes held-out families")
    }
    for seed_index, reset in resets {
      let (offset, schedule) = @balance_native.sample_reference(
        runtime, raw, reset,
      )
      let batch = collect_labeled(
        runtime,
        actor,
        [{ case, offset, schedule, }],
        [reset],
        noise_seed + (2 * case_index + seed_index).to_uint(),
        std,
        study_num(config, "duration_s"),
        study_num(collection, "control_dt_s"),
        parameters,
        fall_height=study_num(config, "fall_height_m"),
        fall_upright=study_num(config, "fall_upright_z"),
      )
      episodes.append(batch.episodes)
      teacher_targets.append(batch.teacher_targets)
      latent_samples.append(batch.latent_samples)
      trials.append(batch.trials)
      points.append(batch.points)
    }
  }
  { episodes, teacher_targets, latent_samples, trials, points, }
}

///|
fn study_selection(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Json,
  experiment : Json,
  config : Json,
  seed : Int32,
) -> Json raise {
  let train = study_collect(
    runtime,
    actor,
    collection,
    [study_int(config, "selection_seed_base") + 10000 * seed],
    (study_int(config, "selection_noise_seed") + 10000 * seed).to_uint(),
    study_num(config, "selection_latent_std"),
    None,
    config,
  )
  let validation_seeds : Array[Int32] = @json.from_json(
    study_field(config, "validation_seeds"),
  )
  let validation = study_evaluate(
    runtime,
    actor,
    experiment,
    validation_seeds,
    Some("validation"),
  )
  let trials = train.trials.copy()
  let held : Array[@native_physics.Trial] = @json.from_json(
    study_field(validation, "trials"),
  )
  trials.append(held)
  {
    "summary": study_summary(trials),
    "training_audit": study_summary(train.trials),
    "validation": study_field(validation, "summary"),
    "trials": trials.to_json(),
  }
}

///|
fn study_audits(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Json,
  config : Json,
  seed : Int32,
  role : String,
  records : Array[Json],
) -> Array[Json] raise {
  let levels : Array[Double] = @json.from_json(
    study_field(config, "audit_latent_stds"),
  )
  let rows : Array[Json] = []
  for std in levels {
    let checked = study_collect(
      runtime,
      actor,
      collection,
      [study_int(config, "audit_seed_base") + 10000 * seed],
      (study_int(config, "audit_noise_seed") + 10000 * seed).to_uint(),
      std,
      None,
      config,
    )
    records.push({
      "role": role.to_json(),
      "latent_std": std.to_json(),
      "dataset": study_dataset(runtime, checked.episodes, collection),
    })
    rows.push({
      "latent_std": std.to_json(),
      "summary": study_summary(checked.trials),
      "trials": checked.trials.to_json(),
    })
  }
  rows
}

///|
async fn study_save_pair(
  path : String,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  metadata : Json,
) -> String {
  guard metadata is Object(fields) else {
    fail("paired metadata must be object")
  }
  let fields = fields.copy()
  fields["temporal_value_checkpoint"] = value.checkpoint(metadata).to_json()
  @temporal.save_temporal(path, actor, Json::object(fields))
}

///|
/// Full disturbance study schema, including independent audit and physical
/// data registries. All report values derive from actual collection/evaluation.
pub async fn run_disturbance_study(
  args : Array[String],
  library : String,
  scene : String,
  provider_source : String,
) -> Unit {
  let config = @artifacts.load_json(study_arg(args, "--config"))
  let collection = @artifacts.load_json(study_arg(args, "--collection"))
  let experiment = @artifacts.load_json(study_arg(args, "--experiment"))
  let teacher = @artifacts.load_json(study_arg(args, "--teacher"))
  guard study_text(teacher, "provider_sha256") ==
    @artifacts.sha256(@fs.read_file(provider_source).binary()) else {
    fail("disturbance teacher implementation changed")
  }
  let parameters = @balance_native.parameters_from_json(
    study_field(teacher, "parameters"),
  )
  let runtime = @native_physics.Runtime::open(library, scene)
  let original = study_points(
    runtime,
    @artifacts.load_json(study_arg(args, "--data")),
    collection,
    study_int(config, "history_length"),
    study_int(config, "future_length"),
  )
  let output = study_arg(args, "--output")
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy", recursive=true)
  }
  if !@fs.exists(output + "/collection") {
    @fs.mkdir(output + "/collection", recursive=true)
  }
  let seeds : Array[Int32] = @json.from_json(study_field(config, "seeds"))
  let test_seeds : Array[Int32] = @json.from_json(
    study_field(config, "test_seeds"),
  )
  let runs : Array[Json] = []
  for seed in seeds {
    let incoming = study_checkpoint(
      study_arg(args, "--policies"),
      "actor",
      seed,
    )
    let actor = @temporal.load_temporal(incoming)
    let parent_metadata = temporal_parent_metadata(incoming)
    guard actor.temporal.history_length == study_int(config, "history_length") &&
      actor.temporal.future_length == study_int(config, "future_length") else {
      fail("incoming temporal shape differs")
    }
    let initial = actor.parameters()
    let buffers = [
      actor.temporal.obs_mean.copy(),
      actor.temporal.obs_scale.copy(),
      actor.temporal.goal_mean.copy(),
      actor.temporal.goal_scale.copy(),
    ]
    let rng = @numeric.Rng::new(
      (study_int(config, "sampling_seed") + seed).to_uint(),
    )
    let optimizer = @numeric.Adam::new(
      initial.length(),
      study_num(config, "actor_learning_rate"),
    )
    let mut best = study_selection(
      runtime, actor, collection, experiment, config, seed,
    )
    let mut selected = 0
    let mut best_weights = initial
    let history : Array[Json] = [
      {
        "round": 0,
        "selection": best,
        "transitions": 0,
        "episodes": 0,
        "falls": 0,
      },
    ]
    let logs : Array[Json] = []
    let recent : Array[@temporal.TemporalPoint] = []
    let mut transitions = 0
    let mut episodes = 0
    let mut falls = 0
    let started = @async.now()
    let rounds = study_int(config, "rounds")
    let updates = study_int(config, "updates_per_round")
    let batch_size = study_int(config, "batch_size")
    let capacity = study_int(config, "recent_points")
    guard rounds >= 0 && updates > 0 && batch_size > 0 && capacity > 0 else {
      fail("invalid disturbance optimization budget")
    }
    for round in 0..<rounds {
      let reset = study_int(config, "collection_seed_base") +
        10000 * seed +
        2 * round
      let state_sha = @artifacts.sha256(
        @artifacts.encode_npy([actor.parameters().length()], actor.parameters()),
      )
      let batch = study_collect(
        runtime,
        actor,
        collection,
        [reset, reset + 1],
        (study_int(config, "noise_seed") + 10000 * seed + 100 * round).to_uint(),
        study_num(config, "collection_latent_std"),
        Some(parameters),
        config,
      )
      recent.append(batch.points)
      while recent.length() > capacity {
        ignore(recent.remove(0))
      }
      guard !recent.is_empty() else { fail("empty disturbance labels") }
      let suffix = "-" + study_text(config, "arm") + "-round-\{round}"
      let renamed = batch.episodes.map(fn(e) { { ..e, id: e.id + suffix, } })
      let dataset = study_dataset(runtime, renamed, collection)
      if seed == 0 && round == 0 {
        ignore(
          @artifacts.save_json(output + "/collection/dataset.json.gz", dataset),
        )
      }
      logs.push({
        "round": (round + 1).to_json(),
        "behavior_state_sha256": state_sha.to_json(),
        "reset_seeds": [reset, reset + 1].to_json(),
        "latent_std": study_field(config, "collection_latent_std"),
        "dataset": dataset,
        "teacher_action_targets": batch.teacher_targets.to_json(),
        "latent_samples": batch.latent_samples.to_json(),
        "target_order": "Separate teacher labels; applied_action remains actual noisy student control.",
        "maximum_input_alignment_error": 0,
      })
      let mut loss = 0.0
      for _ in 0..<updates {
        loss = actor.clone_update(
          optimizer,
          Array::makei(batch_size, fn(i) {
            if i < batch_size / 2 {
              original[rng.index(original.length())]
            } else {
              recent[rng.index(recent.length())]
            }
          }),
        )
        guard @numeric.finite(loss) else { fail("nonfinite disturbance loss") }
      }
      transitions += batch.points.length()
      episodes += batch.episodes.length()
      falls += batch.trials.filter(fn(t) { t.failed }).length()
      let current = study_selection(
        runtime, actor, collection, experiment, config, seed,
      )
      history.push({
        "round": (round + 1).to_json(),
        "selection": current,
        "action_loss": loss.to_json(),
        "transitions": transitions.to_json(),
        "episodes": episodes.to_json(),
        "falls": falls.to_json(),
        "collection": study_summary(batch.trials),
        "maximum_input_alignment_error": 0,
      })
      if study_better(current, best) {
        best = current
        selected = round + 1
        best_weights = actor.parameters()
      }
    }
    let training_seconds = (@async.now() - started).to_double() / 1000
    let log_name = "disturbance-physics-seed-\{seed}.jsonl.gz"
    let log_sha = @artifacts.save_jsonl(output + "/policy/" + log_name, logs)
    let evidence : Json = {
      "algorithm": "teacher-supervised-disturbance-initialization",
      "checkpoint": incoming.to_json(),
      "sha256": @artifacts.sha256(@fs.read_file(incoming).binary()).to_json(),
      "teacher_sha256": @artifacts.sha256(
        @fs.read_file(study_arg(args, "--teacher")).binary(),
      ).to_json(),
      "student_physics_sha256": log_sha.to_json(),
      "config": config,
    }
    let name = "actor-seed-\{seed}.moon.json"
    let latest = "latest-actor-seed-\{seed}.moon.json"
    ignore(
      @temporal.save_temporal(
        output + "/policy/" + latest,
        actor,
        temporal_metadata(
          parent_metadata,
          config,
          actor,
          rounds * updates,
          evidence,
        ),
      ),
    )
    actor.restore(best_weights)
    ignore(
      @temporal.save_temporal(
        output + "/policy/" + name,
        actor,
        temporal_metadata(
          parent_metadata,
          config,
          actor,
          selected * updates,
          evidence,
        ),
      ),
    )
    let restored = @temporal.load_temporal(output + "/policy/" + name)
    guard restored.parameters() == actor.parameters() else {
      fail("disturbance reload differs")
    }
    guard buffers ==
      [
        actor.temporal.obs_mean,
        actor.temporal.obs_scale,
        actor.temporal.goal_mean,
        actor.temporal.goal_scale,
      ] else {
      fail("disturbance normalization changed")
    }
    let incoming_actor = @temporal.load_temporal(incoming)
    let baseline = study_evaluate(
      runtime,
      incoming_actor,
      experiment,
      test_seeds,
      None,
    )
    let candidate = study_evaluate(
      runtime,
      restored,
      experiment,
      test_seeds,
      None,
    )
    ignore(
      @artifacts.save_json(output + "/policy/physics-seed-\{seed}.json", {
        "baseline": baseline,
        "candidate": candidate,
      }),
    )
    let audits : Array[Json] = []
    let before = study_audits(
      runtime, incoming_actor, collection, config, seed, "incoming-independent-audit",
      audits,
    )
    let after = study_audits(
      runtime, restored, collection, config, seed, "selected-independent-audit",
      audits,
    )
    let audit_name = "disturbance-audit-seed-\{seed}.jsonl.gz"
    let audit_sha = @artifacts.save_jsonl(
      output + "/policy/" + audit_name,
      audits,
    )
    runs.push({
      "seed": seed.to_json(),
      "selected_update": (selected * updates).to_json(),
      "selected_round": selected.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest.to_json(),
      "baseline": study_field(baseline, "summary"),
      "candidate": study_field(candidate, "summary"),
      "qualifies": study_qualifies(
        study_field(candidate, "summary"),
        config,
        study_num(experiment, "duration_s"),
      ).to_json(),
      "history": history.to_json(),
      "training_seconds": training_seconds.to_json(),
      "training_transitions": transitions.to_json(),
      "training_episodes": episodes.to_json(),
      "training_falls": falls.to_json(),
      "optimizer_steps": (rounds * updates).to_json(),
      "normalization_unchanged": true,
      "reload_matches": true,
      "initialization": evidence,
      "incoming_audit": before.to_json(),
      "selected_audit": after.to_json(),
      "physics_log": { "file": log_name.to_json(), "sha256": log_sha.to_json() },
      "audit_log": {
        "file": audit_name.to_json(),
        "sha256": audit_sha.to_json(),
      },
    })
  }
  let source = "src/learning_temporal/physics/study_adapters.mbt"
  ignore(
    @artifacts.save_json(output + "/policy/report.json", {
      "format": "moonrobo.g1-temporal-disturbance-fit.v1",
      "algorithm": "teacher-supervised-disturbance-initialization",
      "config": config,
      "experiment": experiment,
      "collection_experiment": collection,
      "runs": runs.to_json(),
      "checkpoint_selection": "fixed train-family disturbance audit plus held-out sway; audit episodes never fit weights",
      "shared_teacher_data_sha256": @artifacts.sha256(
        @fs.read_file(study_arg(args, "--data")).binary(),
      ).to_json(),
      "provider_sha256": @artifacts.sha256(@fs.read_file(source).binary()).to_json(),
      "provider_source": source.to_json(),
      "source_language": "moonbit",
      "any_qualified": runs
      .any(fn(row) { try! @json.from_json(study_field(row, "qualifies")) })
      .to_json(),
      "learned_transition_model_used": false,
      "critic_status": "not-trained",
      "physical_execution_allowed": false,
      "numerical_parity_verified": false,
    }),
  )
}

///|
/// Actual finite-task PPO with independently seeded noise and optimizer
/// streams. No world model, learned reward or bootstrap enters its targets.
pub async fn run_ppo_study(
  args : Array[String],
  library : String,
  scene : String,
) -> Unit {
  let config = @artifacts.load_json(study_arg(args, "--config"))
  let collection = @artifacts.load_json(study_arg(args, "--collection"))
  let experiment = @artifacts.load_json(study_arg(args, "--experiment"))
  let output = study_arg(args, "--output")
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy", recursive=true)
  }
  if !@fs.exists(output + "/collection") {
    @fs.mkdir(output + "/collection", recursive=true)
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let seeds : Array[Int32] = @json.from_json(study_field(config, "seeds"))
  let validation : Array[Int32] = @json.from_json(
    study_field(config, "validation_seeds"),
  )
  let test_seeds : Array[Int32] = @json.from_json(
    study_field(config, "test_seeds"),
  )
  let runs : Array[Json] = []
  let dt = study_num(collection, "control_dt_s")
  let seconds = study_num(config, "duration_s")
  let gamma = study_num(config, "gamma")
  let target_height = study_num(config, "target_height_m")
  for seed in seeds {
    let incoming = study_checkpoint(
      study_arg(args, "--policies"),
      "actor",
      seed,
    )
    let actor = @temporal.load_temporal(incoming)
    let parent_metadata = temporal_parent_metadata(incoming)
    let actor_sha = @artifacts.sha256(@fs.read_file(incoming).binary())
    let value_folder = study_arg(args, "--values")
    let explicit_value = value_folder + "/initial-value-seed-\{seed}.moon.json"
    let value_path = if @fs.exists(explicit_value) {
      explicit_value
    } else {
      let legacy = value_folder + "/actor-seed-\{seed}.pt"
      guard @fs.exists(legacy) else {
        fail(
          "PPO requires the incoming actor's saved initial calibrated value; selected-output values are not interchangeable",
        )
      }
      legacy
    }
    let value = @temporal.load_paired_value(value_path, actor_sha)
    guard value.dt == dt && value.gamma == gamma && value.duration == seconds else {
      fail("PPO calibrated finite-task parameters differ")
    }
    let buffers = [
      actor.temporal.obs_mean.copy(),
      actor.temporal.obs_scale.copy(),
      actor.temporal.goal_mean.copy(),
      actor.temporal.goal_scale.copy(),
      value.state_mean.copy(),
      value.state_scale.copy(),
      value.obs_mean.copy(),
      value.obs_scale.copy(),
      value.goal_mean.copy(),
      value.goal_scale.copy(),
      value.context_mean.copy(),
      value.context_scale.copy(),
    ]
    let actor_optimizer = @numeric.Adam::new(
      actor.parameters().length(),
      study_num(config, "actor_learning_rate"),
    )
    let value_optimizer = @numeric.Adam::new(
      value.net.parameters.length(),
      study_num(config, "critic_learning_rate"),
    )
    let noise_rng = @numeric.Rng::new(
      (study_int(config, "noise_seed") + seed).to_uint(),
    )
    let optimizer_rng = @numeric.Rng::new(
      (study_int(config, "optimizer_seed") + seed).to_uint(),
    )
    let mut best = study_evaluate(
      runtime,
      actor,
      experiment,
      validation,
      Some("validation"),
    )
    let mut best_actor = actor.parameters()
    let mut best_value = value.net.parameters.copy()
    let mut selected = 0
    let history : Array[Json] = [
      {
        "iteration": 0,
        "transitions": 0,
        "actor_steps": 0,
        "critic_steps": 0,
        "validation": study_field(best, "summary"),
      },
    ]
    let logs : Array[Json] = []
    let mut transitions = 0
    let mut episodes = 0
    let mut falls = 0
    let mut actor_steps = 0
    let mut critic_steps = 0
    let started = @async.now()
    let iterations = study_int(config, "iterations")
    for iteration in 0..<iterations {
      let reset = study_int(config, "collect_seed_base") +
        10000 * seed +
        iteration
      let batch : Array[@temporal.TemporalPPOSample] = []
      let collected : Array[@native_physics.Episode] = []
      let episode_json : Array[Json] = []
      let rewards : Array[Double] = []
      let continuation : Array[Double] = []
      let mut batch_falls = 0
      for raw in study_cases(collection, false) {
        let case : @native_physics.Case = @json.from_json(raw)
        guard case.split == "train" else {
          fail("PPO collection includes held-out families")
        }
        let (offset, schedule) = @balance_native.sample_reference(
          runtime, raw, reset,
        )
        let (samples, episode, trial) = collect_ppo(
          runtime,
          actor,
          value,
          case,
          reset,
          seconds,
          dt,
          gamma,
          target_height,
          study_num(config, "raw_action_std"),
          noise_rng,
          offset?,
          schedule?,
          fall_height=study_num(config, "fall_height_m"),
          fall_upright=study_num(config, "fall_upright_z"),
        )
        batch.append(samples)
        collected.push(episode)
        guard episode.to_json() is Object(fields) else {
          fail("invalid episode serialization")
        }
        fields["reference_offset_rad"] = offset.to_json()
        fields["reference_schedule"] = schedule.to_json()
        episode_json.push(Json::object(fields))
        if trial.failed {
          batch_falls += 1
        }
        for i, step in episode.steps {
          let tape = @numeric.Tape::new()
          let last = samples[i].point.history[9]
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
        }
      }
      guard !batch.is_empty() else {
        fail("PPO produced no finite-task samples")
      }
      let dataset = runtime.dataset(
        collected,
        study_text(collection, "source_revision"),
        dt~,
        episode_json~,
      )
      if seed == 0 && iteration == 0 {
        ignore(
          @artifacts.save_json(output + "/collection/dataset.json.gz", dataset),
        )
      }
      logs.push({
        "iteration": (iteration + 1).to_json(),
        "reset_seed": reset.to_json(),
        "dataset": dataset,
        "latent_samples": batch.map(fn(s) { s.latent }).to_json(),
        "behavior_latent_means": batch.map(fn(s) { s.old_mean }).to_json(),
        "objective_rewards": rewards.to_json(),
        "soft_continuation": continuation.to_json(),
        "finite_return_targets": batch.map(fn(s) { s.point.target }).to_json(),
        "discounted_visitation": batch.map(fn(s) { s.weight }).to_json(),
      })
      let mut maximum_latent_error = 0.0
      for sample in batch {
        let point = sample.point
        let history = point.history[point.history.length() -
        actor.temporal.history_length:].to_owned()
        let future = Array::makei(actor.temporal.future_length, fn(i) {
          point.goals[i + 1]
        })
        let tape = @numeric.Tape::new()
        let actual = actor.latent_mean(
          tape,
          tape.vector(actor.parameters()),
          history.map(fn(row) { tape.vector(row) }),
          tape.vector(point.goals[0]),
          future.map(fn(row) { tape.vector(row) }),
        )
        for i, value in actual {
          let error = (value.value - sample.old_mean[i]).abs()
          guard error <= 2.0e-5 + 2.0e-6 * sample.old_mean[i].abs() else {
            fail("PPO reconstructed behavior latent differs")
          }
          maximum_latent_error = maximum_latent_error.max(error)
        }
      }
      let losses = @temporal.optimize(
        actor,
        value,
        actor_optimizer,
        value_optimizer,
        batch,
        {
          epochs: study_int(config, "epochs"),
          minibatch_size: study_int(config, "minibatch_size"),
          raw_action_std: study_num(config, "raw_action_std"),
          target_kl: study_num(config, "target_kl"),
          clip_ratio: study_num(config, "clip_ratio"),
        },
        optimizer_rng,
      )
      transitions += batch.length()
      episodes += collected.length()
      falls += batch_falls
      actor_steps += losses.actor_steps
      critic_steps += losses.critic_steps
      let current = study_evaluate(
        runtime,
        actor,
        experiment,
        validation,
        Some("validation"),
      )
      history.push({
        "iteration": (iteration + 1).to_json(),
        "transitions": transitions.to_json(),
        "episodes": episodes.to_json(),
        "falls": falls.to_json(),
        "collection_transitions": batch.length().to_json(),
        "collection_falls": batch_falls.to_json(),
        "maximum_input_alignment_error": 0,
        "maximum_latent_reconstruction_error": maximum_latent_error.to_json(),
        "validation": study_field(current, "summary"),
        "actor_steps": losses.actor_steps.to_json(),
        "critic_steps": losses.critic_steps.to_json(),
        "actor_early_stopped": losses.actor_early_stopped.to_json(),
        "maximum_full_batch_kl": losses.maximum_full_batch_kl.to_json(),
        "final_policy_loss": losses.final_policy_loss.to_json(),
        "value_before": losses.value_before_rmse.to_json(),
        "value_after": losses.value_after_rmse.to_json(),
        "total_actor_steps": actor_steps.to_json(),
        "total_critic_steps": critic_steps.to_json(),
      })
      if study_better(current, best) {
        best = current
        selected = iteration + 1
        best_actor = actor.parameters()
        best_value = value.net.parameters.copy()
      }
    }
    let training_seconds = (@async.now() - started).to_double() / 1000
    let evidence : Json = {
      "algorithm": "temporal-ppo-physics",
      "actor_sha256": actor_sha.to_json(),
      "value_checkpoint_sha256": @artifacts.sha256(
        @fs.read_file(value_path).binary(),
      ).to_json(),
      "inherited_initial_value_actor_update": 0,
      "optimizer_state_restored": false,
      "learned_transition_model_used": false,
      "config": config,
    }
    let name = "actor-seed-\{seed}.moon.json"
    let latest = "latest-actor-seed-\{seed}.moon.json"
    ignore(
      study_save_pair(
        output + "/policy/" + latest,
        actor,
        value,
        temporal_metadata(
          parent_metadata,
          config,
          actor,
          iterations,
          evidence,
          critic_status="finite-horizon-physical-return",
        ),
      ),
    )
    actor.restore(best_actor)
    for i in 0..<best_value.length() {
      value.net.parameters[i] = best_value[i]
    }
    ignore(
      study_save_pair(
        output + "/policy/" + name,
        actor,
        value,
        temporal_metadata(
          parent_metadata,
          config,
          actor,
          selected,
          evidence,
          critic_status="finite-horizon-physical-return",
        ),
      ),
    )
    let restored = @temporal.load_temporal(output + "/policy/" + name)
    let restored_value = @temporal.load_value(output + "/policy/" + name)
    guard restored.parameters() == actor.parameters() &&
      restored_value.net.parameters == value.net.parameters else {
      fail("PPO paired checkpoint reload differs")
    }
    guard buffers ==
      [
        actor.temporal.obs_mean,
        actor.temporal.obs_scale,
        actor.temporal.goal_mean,
        actor.temporal.goal_scale,
        value.state_mean,
        value.state_scale,
        value.obs_mean,
        value.obs_scale,
        value.goal_mean,
        value.goal_scale,
        value.context_mean,
        value.context_scale,
      ] else {
      fail("PPO normalization changed")
    }
    let baseline = study_evaluate(
      runtime,
      @temporal.load_temporal(incoming),
      experiment,
      test_seeds,
      None,
    )
    let candidate = study_evaluate(
      runtime,
      restored,
      experiment,
      test_seeds,
      None,
    )
    if selected == 0 {
      guard study_field(baseline, "trials") == study_field(candidate, "trials") else {
        fail("PPO update-zero physical trace changed")
      }
    }
    ignore(
      @artifacts.save_json(output + "/policy/physics-seed-\{seed}.json", {
        "baseline": baseline,
        "candidate": candidate,
      }),
    )
    let log_name = "ppo-physics-seed-\{seed}.jsonl.gz"
    let log_sha = @artifacts.save_jsonl(output + "/policy/" + log_name, logs)
    runs.push({
      "seed": seed.to_json(),
      "selected_update": selected.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest.to_json(),
      "baseline": study_field(baseline, "summary"),
      "candidate": study_field(candidate, "summary"),
      "qualifies": study_qualifies(
        study_field(candidate, "summary"),
        config,
        seconds,
      ).to_json(),
      "history": history.to_json(),
      "training_seconds": training_seconds.to_json(),
      "training_transitions": transitions.to_json(),
      "training_episodes": episodes.to_json(),
      "training_falls": falls.to_json(),
      "actor_optimizer_steps": actor_steps.to_json(),
      "critic_optimizer_steps": critic_steps.to_json(),
      "normalization_unchanged": true,
      "reload_matches": true,
      "initialization": evidence,
      "physics_log": { "file": log_name.to_json(), "sha256": log_sha.to_json() },
    })
  }
  let source = "src/learning_temporal/physics/study_adapters.mbt"
  ignore(
    @artifacts.save_json(output + "/policy/report.json", {
      "format": "moonrobo.g1-temporal-ppo-fit.v1",
      "algorithm": "temporal-ppo-physics",
      "config": config,
      "experiment": experiment,
      "collection_experiment": collection,
      "runs": runs.to_json(),
      "checkpoint_selection": "validation-physics-only",
      "evidence_class": "physics-simulation",
      "baseline_role": "incoming supervised temporal actor",
      "learned_transition_model_used": false,
      "provider_sha256": @artifacts.sha256(@fs.read_file(source).binary()).to_json(),
      "provider_source": source.to_json(),
      "source_language": "moonbit",
      "any_qualified": runs
      .any(fn(row) { try! @json.from_json(study_field(row, "qualifies")) })
      .to_json(),
      "physical_execution_allowed": false,
      "numerical_parity_verified": false,
      "rng": "xorshift32/Box-Muller; explicit noise and optimizer streams; not Torch-equivalent",
    }),
  )
}
