///|
fn predicted_return(
  model : @training.Dynamics,
  actor : ReferenceActor,
  points : Array[LearningPoint],
  geometry : @balance.Kinematics,
  schedule : ReferenceSchedule,
  config : Json,
) -> Json raise {
  let tape = @numeric.Tape::new()
  let (objective, active) = imagined_objective(
    tape,
    model,
    actor,
    tape.vector(actor.parameters()),
    None,
    points,
    geometry,
    schedule,
    json_integer(json_field(config, "imagination_horizon")),
    json_number(json_field(config, "gamma")),
    critic_tail=false,
  )
  {
    "return_mean": objective.value,
    "active_imagined_steps": active,
    "origins": points.length(),
  }
}

///|
pub async fn run_last_cycle(
  source : String,
  output : String,
  runtime : @physics.Runtime,
  provider_source : String,
  legacy_indices? : (Int64, Array[(Int32, Int32)]) -> Array[Array[Int32]] raise,
) -> Json {
  let source = @fs.realpath(source)
  let output = @fs.realpath(output)
  let started = @async.now()
  let charter = @artifacts.load_json(output + "/config.json")
  guard source_digest(source + "/report.json") ==
    json_text(json_field(charter, "source_report_sha256")) else {
    fail("last-cycle source study changed")
  }
  let previous = @artifacts.load_json(source + "/report.json")
  let original_charter = @artifacts.load_json(source + "/charter.json")
  let learning = json_field(previous, "config")
  let merged = json_fields(learning)
  for key, value in json_fields(charter) {
    merged[key] = value
  }
  let config = merged.to_json()
  let refs_path = json_text(json_field(original_charter, "references"))
  guard source_digest(refs_path + "/manifest.json") ==
    json_text(json_field(previous, "reference_manifest_sha256")) else {
    fail("reference manifest changed")
  }
  let (_, references) = load_references(refs_path)
  let (_, metadata) = load_reference_actor(
    output + "/initial/actor-zero-output.pt",
  )
  let geometry = kinematics_from_spec(metadata.kinematics)
  let schedule = ReferenceSchedule::new(
    references.map(reference => reference.clip()),
    geometry,
    [0, 500, 1000],
    metadata.dt_s,
  )
  let by_id : Map[String, Json] = Map([])
  for record in json_array(json_field(previous, "physical_records")) {
    by_id[json_text(json_field(record, "episode_id"))] = record
  }
  let records : Array[Json] = []
  let runs : Array[Json] = []
  let native = json_text(
    config_default(previous, "rng_semantics", "".to_json()),
  ).contains("native xorshift32")
  for method_json in json_array(json_field(charter, "methods")) {
    let method_name = json_text(method_json)
    for seed_json in json_array(json_field(charter, "seeds")) {
      let seed = json_integer(seed_json)
      let original = select_run(previous, method_name, seed)
      let cycles : Map[Int32, Json] = Map([])
      for cycle in json_array(json_field(original, "cycles")) {
        cycles[json_integer(json_field(cycle, "cycle"))] = cycle
      }
      let before_cycle = json_integer(json_field(charter, "before_cycle"))
      let after_cycle = json_integer(json_field(charter, "after_cycle"))
      let before_metadata = json_field(cycles[before_cycle], "checkpoint")
      let after_metadata = json_field(cycles[after_cycle], "checkpoint")
      let before_path = path_child(
        source,
        json_text(json_field(before_metadata, "checkpoint")),
      )
      let after_path = path_child(
        source,
        json_text(json_field(after_metadata, "checkpoint")),
      )
      let (before, _) = load_reference_actor(
        before_path,
        expected_sha256=json_text(json_field(before_metadata, "sha256")),
      )
      let (after, _) = load_reference_actor(
        after_path,
        expected_sha256=json_text(json_field(after_metadata, "sha256")),
      )
      let model_path = sibling_checkpoint(after_path, "dynamics", after_cycle)
      let (model, _) = load_reference_dynamics(model_path)
      let frozen_before = before.to_json()
      let frozen_after = after.to_json()
      let frozen_model = model.checkpoint(Json::null()).to_json()
      let train_ids : Array[String] = @json.from_json(
        json_field(cycles[after_cycle], "training_episode_ids"),
      )
      let training = restore_record_group(
        source,
        train_ids.map(id => by_id[id]),
        before,
        schedule,
        json_number(json_field(learning, "gamma")),
      )
      let sample_count = json_integer(
        json_field(charter, "training_origin_samples"),
      )
      let seed_base = json_integer(
          json_field(charter, "training_origin_seed_base"),
        ) +
        seed
      let ids = if native {
        let rng = @numeric.Rng::new(seed_base.reinterpret_as_uint())
        Array::makei(sample_count, _ => rng.index(training.points.length()))
      } else {
        guard legacy_indices is Some(generate) else {
          fail(
            "Torch training-origin sampling requires MOONROBO_TORCH_RNG_ADAPTER",
          )
        }
        generate(seed_base.to_int64(), [
          (training.points.length(), sample_count),
        ])[0]
      }
      let sampled = ids.map(index => training.points[index])
      let predicted_before_training = predicted_return(
        model, before, sampled, geometry, schedule, learning,
      )
      let predicted_after_training = predicted_return(
        model, after, sampled, geometry, schedule, learning,
      )
      let distinct : Map[Int32, Bool] = Map([])
      for id in ids {
        distinct[id] = true
      }
      let on_training : Json = {
        "before": predicted_before_training,
        "after": predicted_after_training,
        "episode_ids": train_ids,
        "origin_indices_sha256": sample_indices_digest([ids]),
        "distinct_origins": distinct.length(),
        "origins_after_reset": sampled
        .filter(point => point.step > point.origin)
        .length(),
        "predicted_change": json_number(
          json_field(predicted_after_training, "return_mean"),
        ) -
        json_number(json_field(predicted_before_training, "return_mean")),
      }
      let comparisons : Array[Json] = []
      let trials : Array[Json] = []
      for clip_json in json_array(json_field(charter, "probe_clip_indices")) {
        let clip = json_integer(clip_json)
        let origin = json_integer(json_field(charter, "reference_origin_step"))
        let case_id = json_field(
          json_field(references[clip].metadata, "case"),
          "id",
        )
        let mut old_trial = Json::null()
        for trial in json_array(json_field(original, "trials")) {
          if json_field(trial, "case_id") == case_id &&
            json_integer(json_field(trial, "reference_start_step")) == origin {
            old_trial = trial
            break
          }
        }
        let final_record = inherited_record(
          by_id[json_text(json_field(old_trial, "episode_id"))],
          source,
        )
        guard json_field(json_field(final_record, "behavior"), "sha256") ==
          json_field(after_metadata, "sha256") else {
          fail("reused final physics belongs to another actor")
        }
        let final_batch = restore_record_group(
          output,
          [final_record],
          after,
          schedule,
          json_number(json_field(learning, "gamma")),
        )
        let behavior : Json = {
          "checkpoint": before_path,
          "sha256": source_digest(before_path),
        }
        let group = physical_group(
          runtime,
          references,
          schedule,
          before,
          geometry,
          learning,
          seed,
          before_cycle,
          "last-cycle-before",
          output + "/" + method_name + "/seed-\{seed}",
          output,
          behavior,
          [origin],
          [clip],
          method_name,
        )
        let first = group.batch.points[0]
        let last = final_batch.points[0]
        let precision = (values : Array[Double]) => {
          if native {
            values
          } else {
            values.map(value => value.to_float().to_double())
          }
        }
        guard precision(first.state) == precision(last.state) &&
          first.history.map(precision) == last.history.map(precision) &&
          precision(first.actual_features) == precision(last.actual_features) &&
          precision(first.reference_features) ==
          precision(last.reference_features) else {
          fail("paired initial state or controller memory differs")
        }
        let predicted_before = predicted_return(
          model,
          before,
          [first],
          geometry,
          schedule,
          learning,
        )
        let predicted_after = predicted_return(
          model,
          after,
          [first],
          geometry,
          schedule,
          learning,
        )
        let actual_before = discounted_returns(
          group.batch.reward,
          json_number(json_field(learning, "gamma")),
          json_integer(json_field(learning, "imagination_horizon")),
        )
        let actual_after = discounted_returns(
          final_batch.reward,
          json_number(json_field(learning, "gamma")),
          json_integer(json_field(learning, "imagination_horizon")),
        )
        let horizons : Array[Int32] = @json.from_json(
          json_field(charter, "prediction_horizons"),
        )
        let metrics = (batch : CollectedBatch) => {
          prediction_metrics(
            batch.points.map(point => point.state),
            batch.actions,
            batch.next_states,
            batch.points[0].context,
            model.state_stats.scale,
            horizons,
            (state, action, context) => model.predict(state, action, context),
          ).to_json()
        }
        comparisons.push({
          "clip_index": clip,
          "reference_id": json_field(references[clip].metadata, "id"),
          "before_episode_id": json_field(group.records[0], "episode_id"),
          "after_episode_id": json_field(final_record, "episode_id"),
          "predicted_before": predicted_before,
          "predicted_after": predicted_after,
          "predicted_prefix_change": json_number(
            json_field(predicted_after, "return_mean"),
          ) -
          json_number(json_field(predicted_before, "return_mean")),
          "actual_before": actual_before.to_json(),
          "actual_after": actual_after.to_json(),
          "actual_prefix_change": actual_after.prefix_return -
          actual_before.prefix_return,
          "actual_full_change": actual_after.full_return -
          actual_before.full_return,
          "before_prediction": metrics(group.batch),
          "after_prediction": metrics(final_batch),
          "before_trial": group.trials[0],
          "after_trial": old_trial,
          "paired_initial_state_and_memory": true,
        })
        records.append(group.records)
        records.push(final_record)
        trials.append(group.trials)
        trials.push(old_trial)
      }
      guard frozen_before == before.to_json() &&
        frozen_after == after.to_json() &&
        frozen_model == model.checkpoint(Json::null()).to_json() else {
        fail("diagnostic changed frozen learned tensors")
      }
      let row : Json = {
        "method": method_name,
        "seed": seed,
        "before_checkpoint": before_path,
        "before_sha256": source_digest(before_path),
        "after_checkpoint": after_path,
        "after_sha256": source_digest(after_path),
        "model_checkpoint": model_path,
        "model_sha256": source_digest(model_path),
        "training_origin_prediction": on_training,
        "comparisons": comparisons,
        "trials": trials,
        "frozen_weights_unchanged": true,
      }
      runs.push(row)
      println(row.stringify())
    }
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-last-cycle.v1",
    "config": config,
    "source_study": source,
    "source_report_sha256": source_digest(source + "/report.json"),
    "reference_manifest_sha256": json_field(
      previous, "reference_manifest_sha256",
    ),
    "references": json_field(original_charter, "references"),
    "initial": { "trials": [] },
    "runs": runs,
    "physical_records": records,
    "new_physical_records": records.length() / 2,
    "reused_physical_records": records.length() / 2,
    "provider_sha256": source_digest(provider_source),
    "provider_seconds": (@async.now() - started).to_double() / 1000.0,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "scope": json_field(charter, "selection"),
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
