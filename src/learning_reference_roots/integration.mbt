///|
/// Paired identical-tensor model fits use only common-first-collection records. Model-diagnostic records are evaluated separately and never appended to replay.
pub async fn run_integration(
  source : String,
  library : String,
  scene : String,
  output : String,
  provider_source : String,
) -> Json {
  let started = @async.now()
  let config = @artifacts.load_json(output + "/config.json")
  guard digest(source + "/report.json") == text(config, "source_report_sha256") else {
    fail("wrong source study")
  }
  let source_report = @artifacts.load_json(source + "/report.json")
  let source_charter = @artifacts.load_json(source + "/charter.json")
  let learning = field(source_report, "config")
  let initial_path = checkpoint_path(output + "/initial/actor-zero-output")
  guard digest(initial_path) == text(source_report, "initialization_sha256") else {
    fail("incoming prior changed")
  }
  let (actor, metadata) = @ref.load_reference_actor(initial_path)
  let geometry = @ref.kinematics_from_spec(metadata.kinematics)
  let references_path = text(source_charter, "references")
  let (manifest, references) = @ref.load_references(references_path)
  ignore(manifest)
  guard digest(references_path + "/manifest.json") ==
    text(source_report, "reference_manifest_sha256") else {
    fail("reference manifest changed")
  }
  let schedule = @ref.ReferenceSchedule::new(
    references.map(fn(r) { r.clip() }),
    geometry,
    [0],
    metadata.dt_s,
  )
  let runtime = @physics.Runtime::open(library, scene)
  let base = actor.parameters()
  let clips : Array[Int32] = @json.from_json(
    field(config, "probe_clip_indices"),
  )
  guard !clips.is_empty() &&
    clips.all(fn(i) { i >= 0 && i < references.length() }) else {
    fail("invalid root probe clips")
  }
  let initial_relative = if initial_path.has_prefix(output + "/") {
    initial_path[output.length() + 1:].to_owned()
  } else {
    initial_path
  }
  let behavior : Json = {
    "checkpoint": initial_relative.to_json(),
    "sha256": digest(initial_path).to_json(),
  }
  let baseline = @ref.physical_group(
    runtime,
    references,
    schedule,
    actor,
    geometry,
    learning,
    0,
    0,
    "baseline",
    output,
    output,
    behavior,
    [0],
    clips,
    "root",
  )
  let baseline_returns = returns_by_episode(
    baseline.batch,
    clips,
    number(learning, "gamma"),
  )
  let records = baseline.records.copy()
  let runs : Array[Json] = []
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let variants : Array[String] = @json.from_json(field(config, "variants"))
  let all_records = rows(source_report, "physical_records")
  for seed in seeds {
    let training_records = all_records.filter(fn(r) {
      integer(r, "seed") == seed && text(r, "role") == "common-first-collection"
    })
    let diagnostic_records = all_records.filter(fn(r) {
      integer(r, "seed") == seed && text(r, "role") == "model-diagnostic"
    })
    let training = archived_batch(
      source,
      training_records,
      actor,
      schedule,
      number(learning, "gamma"),
    )
    let diagnostic = archived_batch(
      source,
      diagnostic_records,
      actor,
      schedule,
      number(learning, "gamma"),
    )
    let training_ids = training_records.map(fn(r) { text(r, "episode_id") })
    guard diagnostic_records.all(fn(r) {
      !training_ids.contains(text(r, "episode_id"))
    }) else {
      fail("diagnostic episodes overlap training corpus")
    }
    let first = first_points(training)
    guard clips.all(fn(i) { i < first.length() }) else {
      fail("probe clips absent from common first collection")
    }
    let probe_starts = clips.map(fn(i) { first[i] })
    let (value, value_source) = load_value(source, seed, source_report)
    let floor = number(learning, "model_normalization_floor")
    let state_stats = @numeric.fit_normalization(
      training.points.map(fn(p) { p.state }),
      floor,
    )
    let action_stats = @numeric.fit_normalization(training.actions, floor)
    let context_stats = @numeric.fit_normalization(
      training.points.map(fn(p) { p.context }),
      floor,
    )
    let initial_model = @training.Dynamics::new(
      state_stats,
      action_stats,
      context_stats,
      integer(learning, "model_width"),
      @numeric.Rng::new((integer(config, "model_seed_base") + seed).to_uint()),
      translation_invariant=true,
    )
    let initial_weights = initial_model.network.parameters.copy()
    let initial_hash = model_digest(initial_model)
    let replay = @ref.ReferenceModelReplay::new(
      integer(learning, "model_replay_windows"),
      integer(learning, "model_window"),
    )
    @ref.append_replay(replay, training)
    let settings = @ref.settings_for_method(learning, "model-based")
    let settings : @ref.ReferenceLearningConfig = {
      ..settings,
      model_updates: integer(config, "model_updates"),
    }
    let mut paired_sample_sha : String? = None
    for variant in variants {
      guard ["root-integrated", "residual", "baseline", "base", "free"].contains(
        variant,
      ) else {
        fail("unknown root integration hypothesis variant")
      }
      actor.set_parameters(base)
      let model = @training.Dynamics::new(
        state_stats,
        action_stats,
        context_stats,
        integer(learning, "model_width"),
        @numeric.Rng::new(1U),
        translation_invariant=true,
        root_integration_dt=if variant == "root-integrated" {
          Some(schedule.dt)
        } else {
          None
        },
      )
      for i in 0..<initial_weights.length() {
        model.network.parameters[i] = initial_weights[i]
      }
      guard model_digest(model) == initial_hash else {
        fail("paired initial model tensors differ")
      }
      let optimizer = @numeric.Adam::new(
        initial_weights.length(),
        number(learning, "model_learning_rate"),
      )
      let sampler = @numeric.Rng::new((70000 + seed).to_uint())
      let samples : Array[Array[Int32]] = []
      let fit_started = @async.now()
      let loss = @ref.fit_model_updates(
        model,
        optimizer,
        replay,
        settings,
        sampler,
        sample_indices=fn(ids) { samples.push(ids.copy()) },
      )
      let samples_sha = @ref.sample_indices_digest(samples)
      match paired_sample_sha {
        Some(expected) => {
          guard samples_sha == expected else {
            fail("paired model fits sampled different minibatches")
          }
        }
        None => paired_sample_sha = Some(samples_sha)
      }
      let fit : Json = {
        "updates": settings.model_updates.to_json(),
        "windows": replay.windows().length().to_json(),
        "loss": loss.to_json(),
        "seconds": ((@async.now() - fit_started).to_double() / 1000.0).to_json(),
        "replay_mode": "recent-fifo",
        "anchor_windows": 0,
        "recent_windows": replay.windows().length().to_json(),
        "anchor_samples": 0,
        "sample_indices_sha256": @ref.sample_indices_digest(samples).to_json(),
      }
      let checkpoint_name = variant + "-seed-" + seed.to_string() + ".moon.json"
      let checkpoint = model.checkpoint({
        "training_episode_ids": training_ids.to_json(),
        "source_report_sha256": field(config, "source_report_sha256"),
        "diagnostic_records_fitted": false,
        "numeric_precision": "float64",
      })
      let checkpoint_sha = @artifacts.save_checkpoint(
        output + "/" + checkpoint_name,
        checkpoint,
      )
      let (restored, _) = @ref.load_reference_dynamics(
        output + "/" + checkpoint_name,
      )
      let mut start = 0
      for n in training.episode_lengths {
        guard restored.predict(
            training.points[start].state,
            training.actions[start],
            training.points[start].context,
          ) ==
          model.predict(
            training.points[start].state,
            training.actions[start],
            training.points[start].context,
          ) else {
          fail("root model checkpoint reload differs")
        }
        start += n
      }
      let metrics = prediction_metrics(model, diagnostic)
      let frozen_model = model_digest(model)
      let frozen_value = value_digest(value)
      let tape = @numeric.Tape::new()
      let bound = tape.vector(actor.parameters())
      let (objective_value, _) = @ref.imagined_objective(
        tape,
        model,
        actor,
        bound,
        Some(value),
        first,
        geometry,
        schedule,
        integer(learning, "imagination_horizon"),
        number(learning, "gamma"),
        critic_tail=true,
      )
      tape.backward(objective_value)
      let gradient = bound.map(fn(p) { tape.gradient(p) })
      let norm = gradient.fold(init=0.0, fn(total, g) { total + g * g }).sqrt()
      guard gradient.all(@numeric.finite) && norm > 0.0 else {
        fail("invalid root model actor direction")
      }
      let direction = gradient.map(fn(g) { g / norm })
      let initial_mean = raw_means(actor, training.points, schedule)
      apply_direction(actor, base, direction, 0.001)
      let response = rms_difference(
          raw_means(actor, training.points, schedule),
          initial_mean,
        ) /
        0.001
      actor.set_parameters(base)
      guard response >= 1.0e-8 else {
        fail("direction has no calibration response")
      }
      let direction_name = "direction-" +
        variant +
        "-seed-" +
        seed.to_string() +
        ".moon.json"
      let saved = @artifacts.Checkpoint::new(
        "moonrobo.g1-reference-parameter-direction.moonbit.v1",
        {
          "base_actor_sha256": field(behavior, "sha256"),
          "parameter_names": actor.parameter_names().to_json(),
          "gradient_norm": norm.to_json(),
          "calibration_response": response.to_json(),
        },
      )
      saved.put("direction", [direction.length()], direction)
      let direction_sha = @artifacts.save_checkpoint(
        output + "/" + direction_name,
        saved,
      )
      let predicted_before = objective(
          model,
          actor,
          Some(value),
          probe_starts,
          geometry,
          schedule,
          learning,
        ).0
      let amplitudes : Array[Double] = @json.from_json(
        field(config, "logit_rms_steps"),
      )
      let signs : Array[Double] = @json.from_json(field(config, "probe_signs"))
      let outcomes : Array[Json] = []
      for amplitude in amplitudes {
        for sign in signs {
          let amount = sign * amplitude / response
          apply_direction(actor, base, direction, amount)
          let achieved = rms_difference(
            raw_means(actor, training.points, schedule),
            initial_mean,
          )
          let predicted_after = objective(
              model,
              actor,
              Some(value),
              probe_starts,
              geometry,
              schedule,
              learning,
            ).0
          let role = variant +
            "-amp-" +
            amplitude.to_string() +
            "-sign-" +
            sign.to_string()
          let fields : Map[String, Json] = match behavior {
            Object(fields) => fields.copy()
            _ => abort("behavior is not object")
          }
          fields["direction_file"] = direction_name.to_json()
          fields["direction_sha256"] = direction_sha.to_json()
          fields["coefficient"] = amount.to_json()
          let fresh = @ref.physical_group(
            runtime,
            references,
            schedule,
            actor,
            geometry,
            learning,
            seed,
            0,
            role,
            output,
            output,
            Json::object(fields),
            [0],
            clips,
            "root",
          )
          records.append(fresh.records)
          let returns = returns_by_episode(
            fresh.batch,
            clips,
            number(learning, "gamma"),
          )
          let mut prefix_change = 0.0
          let mut full_change = 0.0
          for i, r in returns {
            prefix_change += (
                number(r, "prefix_return") -
                number(baseline_returns[i], "prefix_return")
              ) /
              returns.length().to_double()
            full_change += (
                number(r, "full_return") -
                number(baseline_returns[i], "full_return")
              ) /
              returns.length().to_double()
          }
          outcomes.push({
            "logit_rms_target": amplitude.to_json(),
            "sign": sign.to_json(),
            "coefficient": amount.to_json(),
            "achieved_logit_rms": achieved.to_json(),
            "predicted_return_before": predicted_before.to_json(),
            "predicted_return_after": predicted_after.to_json(),
            "predicted_change": (predicted_after - predicted_before).to_json(),
            "trials": fresh.trials.to_json(),
            "returns": returns.to_json(),
            "prefix_change_mean": prefix_change.to_json(),
            "full_change_mean": full_change.to_json(),
          })
        }
      }
      guard model_digest(model) == frozen_model &&
        value_digest(value) == frozen_value else {
        fail("physics direction probe mutated frozen model/value")
      }
      actor.set_parameters(base)
      runs.push({
        "seed": seed.to_json(),
        "variant": variant.to_json(),
        "initial_model_state_sha256": initial_hash.to_json(),
        "fit": fit,
        "checkpoint": checkpoint_name.to_json(),
        "checkpoint_sha256": checkpoint_sha.to_json(),
        "critic": value_source,
        "training_records": training_records.to_json(),
        "diagnostic_records": diagnostic_records.to_json(),
        "diagnostics": metrics.to_json(),
        "direction_file": direction_name.to_json(),
        "direction_sha256": direction_sha.to_json(),
        "gradient_norm": norm.to_json(),
        "calibration_response": response.to_json(),
        "outcomes": outcomes.to_json(),
      })
    }
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-root-integration.v1",
    "config": config,
    "source_study": source.to_json(),
    "references": references_path.to_json(),
    "reference_manifest_sha256": field(
      source_report, "reference_manifest_sha256",
    ),
    "baseline_trials": baseline.trials.to_json(),
    "baseline_returns": baseline_returns.to_json(),
    "runs": runs.to_json(),
    "physical_records": records.to_json(),
    "provider_sha256": digest(provider_source).to_json(),
    "provider_seconds": ((@async.now() - started).to_double() / 1000.0).to_json(),
    "physical_execution_allowed": false,
    "release_qualified": false,
    "scope": "Paired offline fitting and local physical direction diagnostics; not policy training, qualification or cost-to-target",
    "numerical_backend": "moonbit-float64",
    "rng": "xorshift32; not Torch-identical",
    "parity_verified": false,
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
