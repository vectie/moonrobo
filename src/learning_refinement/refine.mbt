///|
/// Full finite-horizon temporal actor refinement with a frozen learned dynamics model.
pub async fn run_refinement(
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
  guard !boolean(config, "actor_critic_bootstrap", false) else {
    fail(
      "finite-horizon refinement has no calibrated tail; use value-training command",
    )
  }
  let checkpoint = @training.load_learning_checkpoint(
    dynamics_path, "residual-dynamics",
  )
  let model = @training.dynamics_from_checkpoint(checkpoint)
  let initial_model = model.network.parameters.copy()
  for
    key in [
      "model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention",
    ] {
    guard field(raw, key) == field(field(checkpoint.metadata, "layout"), key) else {
      fail("temporal replay differs from dynamics physical schema: " + key)
    }
  }
  let dt = number(collection, "control_dt_s")
  guard dt == 0.02 else {
    fail("temporal replay and value feature convention requires dt_s=0.02")
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
    bootstrap: false,
  }
  let dynamics_sha = @artifacts.sha256(@fs.read_file(dynamics_path).binary())
  let data_sha = @artifacts.sha256(@fs.read_file(data_path).binary())
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let runs : Array[Json] = []
  let mut shared : Array[@temporal.ValuePoint]? = None
  for seed in seeds {
    let incoming = actor_path(policies_directory, seed)
    let parent_metadata = incoming_temporal_metadata(incoming)
    let actor = @temporal.load_temporal(incoming)
    let initial_actor = actor.parameters()
    let points = match shared {
      Some(points) => points
      None => {
        let points = replay_points(
          runtime,
          array(raw, "episodes"),
          cases,
          actor,
          config,
          false,
        )
        shared = Some(points)
        points
      }
    }
    let optimizer = @numeric.Adam::new(
      actor.parameters().length(),
      number(config, "actor_learning_rate"),
    )
    let rng = @numeric.Rng::new(
      (integer(config, "sampling_seed") + seed).to_uint(),
    )
    let initial = evaluate(
      runtime, actor, experiment, validation_seeds, "validation",
    )
    let mut best = initial.summary
    let mut selected = 0
    let mut best_parameters = initial_actor.copy()
    let history : Array[Json] = [
      { "update": 0, "validation": summary_json(best) },
    ]
    let start_time = @async.now()
    for update in 1..<=integer(config, "updates") {
      let mini = Array::makei(integer(config, "batch_size"), _ => {
        points[rng.index(points.length())]
      })
      let (objective, norm) = refinement_update(
        model, actor, optimizer, mini, rollout_config,
      )
      if evaluation_updates.contains(update) {
        let current = evaluate(
          runtime, actor, experiment, validation_seeds, "validation",
        )
        history.push({
          "update": update.to_json(),
          "validation": summary_json(current.summary),
          "imagined_return": objective.to_json(),
          "gradient_norm": norm.to_json(),
        })
        if @training.ranks_above(current.summary, best) {
          best = current.summary
          selected = update
          best_parameters = actor.parameters()
        }
      }
    }
    let training_seconds = (@async.now() - start_time).to_double() / 1000
    guard model.network.parameters == initial_model else {
      fail("temporal refinement changed frozen dynamics")
    }
    let evidence : Json = {
      "checkpoint": incoming.to_json(),
      "sha256": @artifacts.sha256(@fs.read_file(incoming).binary()).to_json(),
      "dynamics_sha256": dynamics_sha.to_json(),
      "replay_dataset_sha256": data_sha.to_json(),
    }
    let latest_name = "latest-actor-seed-" + seed.to_string() + ".moon.json"
    ignore(
      @temporal.save_temporal(
        output + "/" + latest_name,
        actor,
        inherit_temporal_metadata(parent_metadata, {
          "config": config,
          "selected_update": field(config, "updates"),
          "initialization": evidence,
        }),
      ),
    )
    actor.restore(best_parameters)
    let name = "actor-seed-" + seed.to_string() + ".moon.json"
    let sha = @temporal.save_temporal(
      output + "/" + name,
      actor,
      inherit_temporal_metadata(parent_metadata, {
        "config": config,
        "selected_update": selected.to_json(),
        "initialization": evidence,
      }),
    )
    let restored = @temporal.load_temporal(output + "/" + name)
    for i in 0..<points.length().min(8) {
      let p = points[i]
      let future = Array::makei(actor.temporal.future_length, j => {
        p.goals[j + 1]
      })
      guard restored.predict(p.history, p.goals[0], future) ==
        actor.predict(p.history, p.goals[0], future) else {
        fail("refined temporal checkpoint reload differs")
      }
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
        fail("selected update-zero temporal actor differs from incoming")
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
      "history": history.to_json(),
      "training_seconds": training_seconds.to_json(),
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
    })
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-temporal-refinement.v1",
      "training_kind": "temporal-finite-horizon-model-refinement",
      "config": config,
      "experiment": experiment,
      "runs": runs.to_json(),
      "dynamics_sha256": dynamics_sha.to_json(),
      "dynamics_training_batch_sha256": field(
        checkpoint.metadata,
        "training_batch_sha256",
      ),
      "replay_dataset_sha256": data_sha.to_json(),
      "checkpoint_selection": "validation-physics-only",
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }),
  )
}
