///|
/// Independently validate archived initializers and physical tracking metrics,
/// then emit one original-schema typed dataset per line. No policy is replayed.
pub async fn export_initialization_stream(
  study : String,
  references_path : String,
  runtime : @physics.Runtime,
  emit : (Json) -> Unit,
) -> Unit {
  let report = @artifacts.load_json(study + "/report.json")
  let manifest_sha = source_digest(references_path + "/manifest.json")
  guard manifest_sha ==
    json_text(json_field(report, "reference_manifest_sha256")) else {
    fail("reference manifest changed")
  }
  let (manifest, references) = load_references(references_path)
  let dt = json_number(json_field(json_field(manifest, "layout"), "dt_s"))
  let checks : Array[Json] = []
  for fit in json_array(json_field(report, "fits")) {
    let path = path_child(study, json_text(json_field(fit, "checkpoint")))
    let (actor, metadata) = load_reference_actor(
      path,
      expected_sha256=json_text(json_field(fit, "checkpoint_sha256")),
    )
    guard json_text(
        json_field(metadata.provenance, "reference_manifest_sha256"),
      ) ==
      manifest_sha else {
      fail("fitted actor has incompatible reference provenance")
    }
    let latent_dim = actor.goal_encoder[actor.goal_encoder.length() - 1].bias.length()
    let mut maximum = 0.0
    for row in actor.decoder[0].weight {
      for value in row[latent_dim:] {
        maximum = maximum.max(value.abs())
      }
    }
    guard !config_bool(
        json_field(report, "config"),
        "reference_only_initialization",
        false,
      ) ||
      maximum == 0.0 else {
      fail("reference-only initialization leaked observation decoder weight")
    }
    checks.push({
      "seed": json_field(fit, "seed"),
      "observation_decoder_input_max_weight": maximum,
    })
  }
  let loaded : Map[String, ReferenceArchive] = Map([])
  for reference in references {
    loaded[json_text(json_field(reference.metadata, "id"))] = reference
  }
  let evaluations = json_array(json_field(report, "evaluations")).copy()
  evaluations.push(json_field(report, "baseline"))
  for evaluation in evaluations {
    let trials : Map[String, Json] = Map([])
    for trial in json_array(json_field(evaluation, "trials")) {
      trials[json_text(json_field(trial, "episode_id"))] = trial
    }
    for record in json_array(json_field(evaluation, "records")) {
      let reference = loaded[json_text(json_field(record, "reference_id"))]
      guard json_field(reference.metadata, "sha256") ==
        json_field(record, "reference_sha256") else {
        fail("trajectory reference changed")
      }
      let arrays = load_record_arrays(study, record)
      let state = numeric_matrix(arrays, "state")
      let next = numeric_matrix(arrays, "next_state")
      let count = json_integer(json_field(record, "steps"))
      guard state.length() == count && next.length() == count && count > 0 else {
        fail("trajectory step count differs")
      }
      for i in 1..<count {
        guard state[i] == next[i - 1] else {
          fail("trajectory lost state continuity")
        }
      }
      let trial = trials[json_text(json_field(record, "episode_id"))]
      let trace = trace_trial(
        runtime, reference, record, trial, arrays, false, dt,
      )
      let replay = json_array(json_field(trace, "replay"))
      let differences : Map[String, Json] = Map([])
      for
        (metric, trace_metric) in [
          ("joint_rmse_rad", "joint_rmse_rad"),
          ("body_position_rmse_m", "body_position_error_m"),
          ("root_position_rmse_m", "root_position_error_m"),
          ("root_orientation_rmse_rad", "root_orientation_error_rad"),
        ] {
        let mut total = 0.0
        for frame in replay {
          let x = json_number(json_field(frame, trace_metric))
          total += x * x
        }
        let error = ((total / count.to_double()).sqrt() -
        json_number(json_field(trial, metric))).abs()
        guard error <= 1.0e-10 else {
          fail(
            "recorded tracking metric disagrees with saved physics: " + metric,
          )
        }
        differences[metric] = error.to_json()
      }
      for i, frame in replay {
        let body_error = json_number(json_field(frame, "body_position_error_m"))
        guard (arrays["reward"].values[i] -
          @math.exp(-body_error * body_error / 0.09)).abs() <=
          1.0e-12 else {
          fail("recorded tracking reward disagrees with saved physics")
        }
      }
      let episode = json_fields(
        representative_episode(reference, record, arrays, dt, false),
      )
      episode["case_id"] = json_field(record, "reference_id")
      let result = json_fields(
        dataset(
          runtime,
          episode.to_json(),
          manifest,
          dt,
          "Recorded physical policy trajectory; reference-control labels excluded from goal",
        ),
      )
      result["dataset_id"] = "g1-reference-initialization".to_json()
      emit({
        "label": json_field(evaluation, "label"),
        "record": record,
        "trial": trial,
        "dataset": result.to_json(),
        "model_checks": checks,
        "recomputed_metric_differences": differences.to_json(),
      })
    }
  }
}
