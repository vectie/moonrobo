///|
fn numeric_row(value : Json) -> Array[Double] raise {
  json_array(value).map(json_double)
}

///|
fn refit_metrics_json(metrics : DynamicsMetrics) -> Json {
  let result = metrics_json(metrics)
  let beats : Bool? = match (metrics.late_mse, metrics.late_persistence_mse) {
    (Some(learned), Some(persistence)) => Some(learned < persistence)
    _ => None
  }
  match result {
    Object(fields) =>
      match fields.get("after_two_seconds") {
        Some(Object(late)) => late["beats_persistence"] = beats.to_json()
        _ => ()
      }
    _ => ()
  }
  result
}

///|
fn normalization_buffers(model : Dynamics) -> Array[Array[Double]] {
  [
    model.state_stats.mean,
    model.state_stats.scale,
    model.action_stats.mean,
    model.action_stats.scale,
    model.context_stats.mean,
    model.context_stats.scale,
  ]
}

///|
fn episode_from_json(value : Json) -> Episode raise {
  let id : String = @json.from_json(json_field(value, "id"))
  let split : String = @json.from_json(json_field(value, "split"))
  let context = numeric_row(json_field(value, "context"))
  let steps = json_array(json_field(value, "steps")).map(step => {
    time_s: json_double(json_field(step, "time_s")),
    state: numeric_row(json_field(step, "state")),
    observation: [],
    applied_action: numeric_row(json_field(step, "applied_action")),
    next_state: numeric_row(json_field(step, "next_state")),
    goal: [],
    terminated: json_bool_default(step, "terminated", false),
    truncated: json_bool_default(step, "truncated", false),
  })
  { id, split, context, steps, }
}

///|
pub struct ActualActions {
  windows : Array[Window]
  digest : String
  layout : Json
  episodes : Int32
  transitions : Int32
  sources : Array[Json]
}

///|
/// Validates each source digest, split ownership, reset boundaries, units and native chunk counts.
pub async fn load_actual_actions(manifest_path : String) -> ActualActions {
  let raw = @fs.read_file(manifest_path).binary()
  let manifest = @json.parse(@utf8.decode(raw))
  guard json_field(manifest, "format") ==
    "moonrobo.g1-actual-action-streams.v1".to_json() &&
    json_field(manifest, "split") == "train".to_json() else {
    fail("expected canonical-validated training streams")
  }
  let layout = json_field(manifest, "layout")
  let horizon = json_int(json_field(manifest, "window_length"))
  let stride = json_int(json_field(manifest, "stride"))
  let dt = json_double(json_field(layout, "dt_s"))
  let identities : Map[String, Bool] = Map([])
  let windows = []
  let sources : Array[Json] = []
  let mut episode_count = 0
  let mut transitions = 0
  for source in json_array(json_field(manifest, "sources")) {
    let path : String = @json.from_json(json_field(source, "path"))
    let stored = @fs.read_file(path).binary()
    guard @artifacts.sha256(stored).to_json() == json_field(source, "sha256") else {
      fail("actual-action source digest differs from native validation")
    }
    let datasets = []
    let kind : String = @json.from_json(json_field(source, "kind"))
    if kind == "dataset" {
      datasets.push(@json.parse(@utf8.decode(stored)))
    } else if kind == "student-jsonl-gzip" {
      let text = @utf8.decode(@artifacts.decompress(stored))
      for line in text.split("\n") {
        if line.trim_space() == "" {
          continue
        }
        datasets.push(json_field(@json.parse(line.to_owned()), "dataset"))
      }
    } else {
      fail("unknown actual-action source kind")
    }
    let expected_chunks = json_array(json_field(source, "chunks"))
    guard datasets.length() == expected_chunks.length() else {
      fail("actual-action chunk count differs from native validation")
    }
    for chunk_index in 0..<datasets.length() {
      let dataset = datasets[chunk_index]
      for
        key in [
          "model_ref", "dt_s", "frame_convention", "state_axes", "action_axes", "context_axes",
        ] {
        guard json_field(dataset, key) == json_field(layout, key) else {
          fail("actual-action layout differs: " + key)
        }
      }
      let episodes = json_array(json_field(dataset, "episodes")).map(
        episode_from_json,
      )
      let mut chunk_transitions = 0
      for episode in episodes {
        guard episode.split == "train" && !identities.contains(episode.id) else {
          fail("held-out or duplicate actual-action episode")
        }
        identities[episode.id] = true
        chunk_transitions += episode.steps.length()
        let ns = json_array(json_field(layout, "state_axes")).length()
        let na = json_array(json_field(layout, "action_axes")).length()
        let nc = json_array(json_field(layout, "context_axes")).length()
        guard episode.context.length() == nc else {
          fail("actual-action context dimension differs")
        }
        for step in episode.steps {
          guard step.state.length() == ns &&
            step.next_state.length() == ns &&
            step.applied_action.length() == na else {
            fail("actual-action numeric dimensions differ")
          }
        }
      }
      let expected = expected_chunks[chunk_index]
      guard episodes.length() == json_int(json_field(expected, "episodes")) &&
        chunk_transitions == json_int(json_field(expected, "transitions")) else {
        fail("actual-action source counts differ from native validation")
      }
      episode_count += episodes.length()
      transitions += chunk_transitions
      windows.append(
        episode_windows(episodes, horizon, dt, stride~, reject_reset=true),
      )
    }
    sources.push({
      "path": path.to_json(),
      "sha256": json_field(source, "sha256"),
      "chunks": datasets.length().to_json(),
    })
  }
  guard episode_count == json_int(json_field(manifest, "episodes")) &&
    windows.length() > 0 else {
    fail("native/numerical episode counts differ or no complete windows")
  }
  {
    windows,
    digest: @artifacts.sha256(raw),
    layout,
    episodes: episode_count,
    transitions,
    sources,
  }
}

///|
/// Full old-only / mixed actual-action refit experiment using frozen incoming units.
pub async fn run_refit(
  config_path : String,
  manifest_path : String,
  initial_path : String,
  validation_path : String,
  test_path : String,
  output : String,
) -> Unit {
  let config = @json.parse(@utf8.decode(@fs.read_file(config_path).binary()))
  let manifest = @json.parse(
    @utf8.decode(@fs.read_file(manifest_path).binary()),
  )
  let base = json_field(manifest, "base_batch")
  let base_path : String = @json.from_json(json_field(base, "path"))
  let original_batch = @artifacts.load_window_batch(base_path, "train")
  let initial = load_learning_checkpoint(initial_path, "residual-dynamics")
  guard original_batch.digest.to_json() == json_field(base, "sha256") &&
    original_batch.digest.to_json() ==
    json_field(initial.metadata, "training_batch_sha256") &&
    original_batch.layout == json_field(initial.metadata, "layout") else {
    fail("base replay differs from initial world-model training")
  }
  let validation_batch = @artifacts.load_window_batch(
    validation_path, "validation",
  )
  let test_batch = @artifacts.load_window_batch(test_path, "test")
  original_batch.compatible(validation_batch)
  original_batch.compatible(test_batch)
  let original = windows_from_batch(original_batch)
  let validation = windows_from_batch(validation_batch)
  let test_data = windows_from_batch(test_batch)
  let added = load_actual_actions(manifest_path)
  guard added.layout == original_batch.layout &&
    added.windows[0].action.length() == original_batch.horizon else {
    fail("new replay differs from original schema")
  }
  let fit_config : DynamicsFitConfig = {
    updates: json_int(json_field(config, "updates")),
    batch_size: json_int(json_field(config, "batch_size")),
    evaluate_every: json_int(json_field(config, "evaluate_every")),
    learning_rate: json_double(json_field(config, "learning_rate")),
    late_window_fraction: 0,
    late_validation_weight: json_double_default(
      config, "late_validation_weight", 0,
    ),
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  for mixed in [false, true] {
    let arm = if mixed { "mixed" } else { "old-only" }
    let directory = output + "/" + arm
    if !@fs.exists(directory) {
      @fs.mkdir(directory)
    }
    let input_spec : Json = {
      "format": "moonrobo.moonbit-dynamics-refit-input.v1",
      "arm": arm.to_json(),
      "base_batch_sha256": original_batch.digest.to_json(),
      "parent_dynamics_training_batch_sha256": json_field(
        initial.metadata,
        "training_batch_sha256",
      ),
      "added_streams_manifest_sha256": (if mixed {
        Some(added.digest)
      } else {
        None
      }).to_json(),
      "initial_dynamics_sha256": @artifacts.sha256(
        @fs.read_file(initial_path).binary(),
      ).to_json(),
      "config": config,
    }
    let training_sha = @artifacts.save_json(
      directory + "/training-input.json",
      input_spec,
    )
    let runs : Array[Json] = []
    for seed_json in json_array(json_field(config, "seeds")) {
      let seed = json_int(seed_json)
      let model = dynamics_from_checkpoint(initial)
      let frozen_normalization = normalization_buffers(model).map(values => {
        values.copy()
      })
      let start_time = @async.now()
      let result = refit_dynamics(
        model,
        original,
        added.windows,
        validation,
        test_data,
        fit_config,
        @numeric.Rng::new(
          (json_int(json_field(config, "sampling_seed")) + seed).to_uint(),
        ),
        mixed,
      )
      let training_seconds = (@async.now() - start_time).to_double() / 1000
      let metadata : Json = {
        "config": config,
        "seed": seed.to_json(),
        "selected_update": result.selected_update.to_json(),
        "refit_arm": arm.to_json(),
        "training_batch_sha256": training_sha.to_json(),
        "parent_training_batch_sha256": original_batch.digest.to_json(),
        "added_streams_manifest_sha256": added.digest.to_json(),
        "layout": original_batch.layout,
        "normalization_source": "unchanged incoming sustained training normalization",
      }
      let name = "dynamics-seed-" + seed.to_string() + ".moon.json"
      let sha = @artifacts.save_checkpoint(
        directory + "/" + name,
        model.checkpoint(metadata),
      )
      restore_parameters(model.network, result.latest_parameters)
      let latest = "latest-dynamics-seed-" + seed.to_string() + ".moon.json"
      let latest_metadata = match metadata {
        Object(fields) => {
          let fields = fields.copy()
          fields["selected_update"] = fit_config.updates.to_json()
          Json::object(fields)
        }
        _ => metadata
      }
      ignore(
        @artifacts.save_checkpoint(
          directory + "/" + latest,
          model.checkpoint(latest_metadata),
        ),
      )
      let restored = dynamics_from_checkpoint(
        load_learning_checkpoint(
          directory + "/" + name,
          "residual-dynamics",
          expected_sha256=sha,
        ),
      )
      guard normalization_buffers(model) == frozen_normalization &&
        normalization_buffers(restored) == frozen_normalization else {
        fail("dynamic refit changed incoming normalization")
      }
      let test_metrics = restored.evaluate(test_data)
      guard refit_metrics_json(test_metrics) ==
        refit_metrics_json(result.test_metrics) else {
        fail("refit checkpoint reload differs")
      }
      let old_train_metrics = restored.evaluate(original)
      let added_train_metrics = restored.evaluate(added.windows)
      let parameters_before_probe = restored.network.parameters.copy()
      let probe = restored.gradient_probe(validation[0])
      guard restored.network.parameters == parameters_before_probe &&
        normalization_buffers(restored) == frozen_normalization else {
        fail(
          "dynamic refit gradient probe changed frozen model weights or normalization",
        )
      }
      let gradient_probe : Json = {
        "passed": probe.passed.to_json(),
        "horizon": validation[0].action.length().to_json(),
        "action_gradient_norm": probe.action_gradient_norm.to_json(),
        "state_gradient_norm": probe.state_gradient_norm.to_json(),
        "analytic_directional": probe.analytic_directional.to_json(),
        "finite_difference_directional": probe.finite_difference_directional.to_json(),
        "frozen_parameter_gradients": true,
      }
      let metrics : Json = {
        "old_train": refit_metrics_json(old_train_metrics),
        "added_train": refit_metrics_json(added_train_metrics),
        "validation": refit_metrics_json(result.validation),
        "test": refit_metrics_json(test_metrics),
      }
      let history = result.history.map(row => {
        "update": row.update.to_json(),
        "loss": row.training_loss.to_json(),
        "validation": refit_metrics_json(row.validation),
        "selection_score": row.selection_score.to_json(),
      })
      runs.push({
        "seed": seed.to_json(),
        "selected_update": result.selected_update.to_json(),
        "training_seconds": training_seconds.to_json(),
        "checkpoint": name.to_json(),
        "latest_checkpoint": latest.to_json(),
        "normalization_unchanged": true,
        "reload_matches": true,
        "history": history.to_json(),
        "metrics": metrics,
        "gradient_probe": gradient_probe,
        "training_input_sha256": training_sha.to_json(),
        "validation": refit_metrics_json(result.validation),
        "test": refit_metrics_json(test_metrics),
      })
    }
    let late_windows = added.windows.filter(w => w.start_time_s >= 2).length()
    let report : Json = {
      "format": "moonrobo.moonbit-dynamics-refit.v1",
      "arm": arm.to_json(),
      "config": config,
      "runs": runs.to_json(),
      "horizon": original_batch.horizon.to_json(),
      "normalization_source": "unchanged incoming sustained training normalization",
      "selection_source": "canonical validation only, including update zero",
      "added_dataset": {
        "episodes": added.episodes.to_json(),
        "transitions": added.transitions.to_json(),
        "windows": added.windows.length().to_json(),
        "late_windows": late_windows.to_json(),
        "manifest_sha256": added.digest.to_json(),
        "sources": added.sources.to_json(),
      },
      "canonical_inputs": {
        "validation": validation_batch.digest.to_json(),
        "test": test_batch.digest.to_json(),
      },
      "initial_dynamics_sha256": json_field(
        input_spec, "initial_dynamics_sha256",
      ),
      "base_batch_sha256": original_batch.digest.to_json(),
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }
    @fs.write_file(
      directory + "/report.json",
      @utf8.encode(report.stringify(indent=2)),
      create_mode=CreateOrTruncate,
    )
  }
}
