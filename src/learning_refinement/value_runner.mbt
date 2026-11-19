///|
async fn refresh(
  runtime : @native_physics.Runtime,
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  optimizer : @numeric.Adam,
  collection : Json,
  cases : Map[String, Json],
  config : Json,
  rollout_config : @training.RolloutConfig,
  seed : Int32,
  update : Int32,
  output : String,
  incoming_sha : String,
  rng : @numeric.Rng,
  records : Array[Json],
  calibrations : Array[Json],
) -> Array[@temporal.ValuePoint] {
  let reset = integer(config, "critic_collect_seed_base") +
    10000 * seed +
    update / integer(config, "critic_refresh_every")
  let actor_sha = @artifacts.sha256(
    @utf8.encode(actor.parameters().to_json().stringify()),
  )
  let data = collect_value_data(
    runtime,
    actor,
    collection,
    config,
    reset,
    update == 0,
  )
  let dataset = data_json(runtime, data, collection)
  let record : Json = {
    "role": "critic-training",
    "actor_update": update.to_json(),
    "reset_seed": reset.to_json(),
    "actor_state_sha256": actor_sha.to_json(),
    "dataset": dataset,
    "soft_return_targets": data.points.map(p => p.target).to_json(),
    "tail_at_original_task_end": 0,
  }
  let audit = if update == 0 {
    Some(
      collect_value_data(
        runtime,
        actor,
        collection,
        config,
        integer(config, "initial_audit_seed") + 10000 * seed,
        false,
      ),
    )
  } else {
    None
  }
  let audit_before = match audit {
    Some(a) => Some(value_error(value, a.points))
    None => None
  }
  let training = fit_value(value, optimizer, data.points, config, rng)
  let mut falls = 0
  let mut time_limits = 0
  for episode in data.episodes {
    let last = episode.steps[episode.steps.length() - 1]
    if last.terminated {
      falls += 1
    }
    if last.truncated {
      time_limits += 1
    }
  }
  let row : Json = {
    "actor_update": update.to_json(),
    "reset_seed": reset.to_json(),
    "actor_state_sha256": actor_sha.to_json(),
    "dataset_sha256": @artifacts.sha256(@utf8.encode(dataset.stringify())).to_json(),
    "episodes": data.episodes.length().to_json(),
    "transitions": data.points.length().to_json(),
    "falls": falls.to_json(),
    "time_limits": time_limits.to_json(),
    "training": training,
    "optimizer_steps": field(config, "critic_fit_steps"),
  }
  if audit is Some(audit) {
    let probe = direction_probe(
      runtime,
      model,
      actor,
      value,
      data.origins,
      config,
      rollout_config,
      output + "/initial-direction-seed-" + seed.to_string() + ".moon.json",
    )
    match row {
      Object(fields) => {
        fields["independent_audit_before"] = audit_before.unwrap()
        fields["independent_audit_after"] = value_error(value, audit.points)
        fields["initial_direction"] = probe
      }
      _ => ()
    }
    match record {
      Object(fields) => {
        fields["independent_audit"] = {
          "reset_seed": (integer(config, "initial_audit_seed") + 10000 * seed).to_json(),
          "dataset": data_json(runtime, audit, collection),
          "soft_return_targets": audit.points.map(p => p.target).to_json(),
        }
        fields["probe_origins"] = data.origins.to_json()
      }
      _ => ()
    }
    ignore(
      @temporal.save_value(
        output + "/initial-value-seed-" + seed.to_string() + ".moon.json",
        value,
        {
          "actor_checkpoint_sha256": incoming_sha.to_json(),
          "critic_actor_update": 0,
          "calibrated": true,
          "config": config,
        },
      ),
    )
  }
  records.push(record)
  calibrations.push(row)
  ignore(
    @artifacts.save_jsonl(
      output + "/critic-physics-seed-" + seed.to_string() + ".jsonl.gz",
      records,
    ),
  )
  replay_points(runtime, data.raw, cases, actor, config, true)
}

///|
async fn save_pair(
  path : String,
  value_path : String,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  metadata : Json,
  critic_update : Int32,
) -> String {
  let embedded = value.checkpoint({
    "critic_actor_update": critic_update.to_json(),
    "calibrated": true,
  })
  let actor_metadata = match metadata {
    Object(fields) => {
      let fields = fields.copy()
      fields["temporal_value_checkpoint"] = embedded.to_json()
      Json::object(fields)
    }
    _ => metadata
  }
  let sha = @temporal.save_temporal(path, actor, actor_metadata)
  ignore(
    @temporal.save_value(value_path, value, {
      "actor_checkpoint_sha256": sha.to_json(),
      "critic_actor_update": critic_update.to_json(),
      "calibrated": true,
      "training": metadata,
    }),
  )
  sha
}

///|
/// Matched temporal finite-task value calibration and actor refinement. Audit targets never enter fitting or checkpoint selection.
pub async fn run_value_training(
  library : String,
  scene : String,
  config_path : String,
  experiment_path : String,
  collection_path : String,
  data_path : String,
  policies_directory : String,
  dynamics_path : String,
  output : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(experiment_path)
  let collection = @artifacts.load_json(collection_path)
  let raw = @artifacts.load_json(data_path)
  let checkpoint = @training.load_learning_checkpoint(
    dynamics_path, "residual-dynamics",
  )
  let model = @training.dynamics_from_checkpoint(checkpoint)
  let model_initial = model.network.parameters.copy()
  for
    key in [
      "model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention",
    ] {
    guard field(raw, key) == field(field(checkpoint.metadata, "layout"), key) else {
      fail("temporal finite-value replay schema differs: " + key)
    }
  }
  guard number(collection, "control_dt_s") == 0.02 else {
    fail("finite-task value convention requires dt=0.02")
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let cases : Map[String, Json] = Map([])
  for case in array(collection, "cases") {
    if text(case, "split") == "train" {
      cases[text(case, "id")] = case
    }
  }
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let validation_seeds : Array[Int32] = @json.from_json(
    field(config, "validation_seeds"),
  )
  let test_seeds : Array[Int32] = @json.from_json(field(config, "test_seeds"))
  let evaluation_updates : Array[Int32] = @json.from_json(
    field(config, "evaluation_updates"),
  )
  let rollout_config : @training.RolloutConfig = {
    horizon: integer(config, "horizon"),
    gamma: number(config, "gamma"),
    target_height: number(config, "target_height_m"),
    bootstrap: boolean(config, "actor_critic_bootstrap", false),
  }
  let dynamics_sha = @artifacts.sha256(@fs.read_file(dynamics_path).binary())
  let data_sha = @artifacts.sha256(@fs.read_file(data_path).binary())
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let mut shared : Array[@temporal.ValuePoint]? = None
  let runs : Array[Json] = []
  for seed in seeds {
    let incoming = actor_path(policies_directory, seed)
    let parent_metadata = incoming_temporal_metadata(incoming)
    let incoming_sha = @artifacts.sha256(@fs.read_file(incoming).binary())
    let actor = @temporal.load_temporal(incoming)
    guard actor.temporal.history_length <= 10 &&
      actor.temporal.future_length <= 10 else {
      fail(
        "finite value convention requires at most ten actor history/preview frames",
      )
    }
    let shared_points = match shared {
      Some(points) => points
      None => {
        let points = replay_points(
          runtime,
          array(raw, "episodes"),
          cases,
          actor,
          config,
          true,
        )
        shared = Some(points)
        points
      }
    }
    let value = @temporal.make_value(
      model,
      actor,
      integer(config, "critic_width"),
      number(config, "gamma"),
      number(config, "duration_s"),
      @numeric.Rng::new(
        (integer(config, "critic_initial_seed") + seed).to_uint(),
      ),
      fall_height=number(config, "fall_height_m"),
      fall_upright=number(config, "fall_upright_z"),
    )
    let value_optimizer = @numeric.Adam::new(
      value.net.parameters.length(),
      number(config, "critic_learning_rate"),
    )
    let actor_optimizer = @numeric.Adam::new(
      actor.parameters().length(),
      number(config, "actor_learning_rate"),
    )
    let actor_rng = @numeric.Rng::new(
      (integer(config, "sampling_seed") + seed).to_uint(),
    )
    let extra_rng = @numeric.Rng::new(
      (integer(config, "sampling_seed") + seed + 1000000).to_uint(),
    )
    let value_rng = @numeric.Rng::new(
      (integer(config, "critic_sampling_seed") + seed).to_uint(),
    )
    let initial = evaluate(
      runtime, actor, experiment, validation_seeds, "validation",
    )
    let mut best = initial.summary
    let mut selected = 0
    let mut selected_critic_update = 0
    let mut best_actor = actor.parameters()
    let history : Array[Json] = [
      { "update": 0, "validation": summary_json(best) },
    ]
    let calibrations : Array[Json] = []
    let records : Array[Json] = []
    let start_time = @async.now()
    let mut recent = refresh(
      runtime, model, actor, value, value_optimizer, collection, cases, config, rollout_config,
      seed, 0, output, incoming_sha, value_rng, records, calibrations,
    )
    let mut best_value = value.net.parameters.copy()
    let mut critic_update = 0
    for update in 1..<=integer(config, "updates") {
      if update > 1 &&
        (update - 1) % integer(config, "critic_refresh_every") == 0 {
        critic_update = update - 1
        recent = refresh(
          runtime, model, actor, value, value_optimizer, collection, cases, config,
          rollout_config, seed, critic_update, output, incoming_sha, value_rng, records,
          calibrations,
        )
      }
      let size = integer(config, "batch_size")
      let half = size / 2
      let old = Array::makei(half, _ => actor_rng.index(shared_points.length()))
      let fresh = Array::makei(size - half, _ => {
        actor_rng.index(recent.length())
      })
      let mode = match config {
        Object(fields) =>
          match fields.get("actor_replay_distribution") {
            Some(v) => @json.from_json(v)
            None => "mixed"
          }
        _ => "mixed"
      }
      guard mode == "mixed" || mode == "teacher" else {
        fail("unknown temporal actor replay distribution")
      }
      let points = old.map(i => shared_points[i])
      if mode == "teacher" {
        for _ in 0..<(size - half) {
          points.push(shared_points[extra_rng.index(shared_points.length())])
        }
      } else {
        for i in fresh {
          points.push(recent[i])
        }
      }
      let value_before = value.net.parameters.copy()
      let (objective, norm) = @temporal.imagination_update(
        model, actor, value, actor_optimizer, points, rollout_config,
      )
      guard value.net.parameters == value_before else {
        fail("actor update changed frozen temporal value weights")
      }
      if evaluation_updates.contains(update) {
        let current = evaluate(
          runtime, actor, experiment, validation_seeds, "validation",
        )
        history.push({
          "update": update.to_json(),
          "validation": summary_json(current.summary),
          "imagined_return": objective.to_json(),
          "gradient_norm": norm.to_json(),
          "critic_actor_update": critic_update.to_json(),
        })
        if @training.ranks_above(current.summary, best) {
          best = current.summary
          selected = update
          best_actor = actor.parameters()
          best_value = value.net.parameters.copy()
          selected_critic_update = critic_update
        }
      }
    }
    let training_seconds = (@async.now() - start_time).to_double() / 1000
    let evidence : Json = {
      "checkpoint": incoming.to_json(),
      "sha256": incoming_sha.to_json(),
      "dynamics_sha256": dynamics_sha.to_json(),
      "teacher_replay_sha256": data_sha.to_json(),
      "selected_critic_actor_update": selected_critic_update.to_json(),
    }
    let latest_name = "latest-actor-seed-" + seed.to_string() + ".moon.json"
    ignore(
      save_pair(
        output + "/" + latest_name,
        output + "/latest-value-seed-" + seed.to_string() + ".moon.json",
        actor,
        value,
        inherit_temporal_metadata(parent_metadata, {
          "config": config,
          "selected_update": field(config, "updates"),
          "initialization": evidence,
          "critic_status": "finite-horizon-physical-return",
        }),
        critic_update,
      ),
    )
    actor.restore(best_actor)
    @training.restore_parameters(value.net, best_value)
    let name = "actor-seed-" + seed.to_string() + ".moon.json"
    let sha = save_pair(
      output + "/" + name,
      output + "/value-seed-" + seed.to_string() + ".moon.json",
      actor,
      value,
      inherit_temporal_metadata(parent_metadata, {
        "config": config,
        "selected_update": selected.to_json(),
        "initialization": evidence,
        "critic_status": "finite-horizon-physical-return",
      }),
      selected_critic_update,
    )
    let restored = @temporal.load_temporal(output + "/" + name)
    let restored_value = @temporal.load_value(output + "/" + name)
    for i in 0..<shared_points.length().min(8) {
      let p = shared_points[i]
      let h = Array::makei(actor.temporal.history_length, j => {
        p.history[p.history.length() - actor.temporal.history_length + j]
      })
      let future = Array::makei(actor.temporal.future_length, j => {
        p.goals[j + 1]
      })
      guard restored.predict(h, p.goals[0], future) ==
        actor.predict(h, p.goals[0], future) else {
        fail("value-refined actor checkpoint reload differs")
      }
      guard restored_value.predict(
          p.state,
          p.history,
          Array::makei(11, j => p.goals[j]),
          p.context,
          p.remaining,
        ) ==
        value.predict(
          p.state,
          p.history,
          Array::makei(11, j => p.goals[j]),
          p.context,
          p.remaining,
        ) else {
        fail("temporal value checkpoint reload differs")
      }
    }
    let final_data = collect_value_data(
      runtime,
      restored,
      collection,
      config,
      integer(config, "selected_audit_seed") + 10000 * seed,
      false,
    )
    let final_audit = value_error(restored_value, final_data.points)
    records.push({
      "role": "selected-value-audit",
      "actor_update": selected.to_json(),
      "reset_seed": (integer(config, "selected_audit_seed") + 10000 * seed).to_json(),
      "dataset": data_json(runtime, final_data, collection),
      "soft_return_targets": final_data.points.map(p => p.target).to_json(),
    })
    let log_name = "critic-physics-seed-" + seed.to_string() + ".jsonl.gz"
    let log_sha = @artifacts.save_jsonl(output + "/" + log_name, records)
    guard model.network.parameters == model_initial else {
      fail("temporal value training changed frozen dynamics")
    }
    let candidate = evaluate(runtime, restored, experiment, test_seeds, "all")
    let baseline = evaluate(
      runtime,
      @temporal.load_temporal(incoming),
      experiment,
      test_seeds,
      "all",
    )
    if selected == 0 {
      guard baseline.trials == candidate.trials else {
        fail("selected update-zero finite-value temporal actor differs")
      }
    }
    ignore(
      @artifacts.save_json(
        output + "/physics-seed-" + seed.to_string() + ".json",
        {
          "baseline": {
            "summary": summary_json(
              baseline.summary,
              trials=baseline.trials.length(),
            ),
            "trials": baseline.trials.to_json(),
          },
          "candidate": {
            "summary": summary_json(
              candidate.summary,
              trials=candidate.trials.length(),
            ),
            "trials": candidate.trials.to_json(),
          },
        },
      ),
    )
    runs.push({
      "seed": seed.to_json(),
      "selected_update": selected.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest_name.to_json(),
      "checkpoint_sha256": sha.to_json(),
      "training_seconds": training_seconds.to_json(),
      "history": history.to_json(),
      "initialization": evidence,
      "dynamics_unchanged": true,
      "reload_matches": true,
      "baseline": summary_json(
        baseline.summary,
        trials=baseline.trials.length(),
      ),
      "candidate": summary_json(
        candidate.summary,
        trials=candidate.trials.length(),
      ),
      "qualifies": @training.qualifies(
        candidate.summary,
        number(config, "max_mean_joint_rmse_rad"),
      ).to_json(),
      "temporal_value": {
        "selected_critic_actor_update": selected_critic_update.to_json(),
        "selected_audit": final_audit,
      },
      "critic_physics": {
        "file": log_name.to_json(),
        "sha256": log_sha.to_json(),
        "batches": calibrations.to_json(),
      },
    })
  }
  let shared_digest = @artifacts.sha256(
    @utf8.encode(shared.unwrap().to_json().stringify()),
  )
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-temporal-value-refinement.v1",
      "training_kind": "temporal-physical-finite-value-model-refinement",
      "config": config,
      "experiment": experiment,
      "runs": runs.to_json(),
      "checkpoint_selection": "validation-physics-only",
      "dynamics_sha256": dynamics_sha.to_json(),
      "dynamics_training_batch_sha256": field(
        checkpoint.metadata,
        "training_batch_sha256",
      ),
      "shared_teacher_sha256": data_sha.to_json(),
      "shared_teacher_points_sha256": shared_digest.to_json(),
      "shared_teacher_actor_starts": shared.unwrap().length().to_json(),
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }),
  )
}
