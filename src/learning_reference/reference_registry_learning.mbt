///|
pub async fn export_learning_registry(
  study : String,
  verification : String,
  runtime : @physics.Runtime,
  method_name : String,
  output : String,
) -> Json {
  let report_path = study + "/report.json"
  let report = @artifacts.load_json(report_path)
  let report_sha = source_digest(report_path)
  let proof = @artifacts.load_json(verification)
  guard json_text(json_field(proof, "source_report_sha256")) == report_sha &&
    json_boolean(
      json_field(
        json_field(proof, "native_verification"),
        "all_records_validated",
      ),
    ) else {
    fail("reference RL export requires complete matching native verification")
  }
  let charter = @artifacts.load_json(study + "/charter.json")
  let refs = json_text(json_field(charter, "references"))
  let manifest_sha = source_digest(refs + "/manifest.json")
  guard manifest_sha ==
    json_text(json_field(report, "reference_manifest_sha256")) else {
    fail("reference changed")
  }
  let (manifest, clips) = load_references(refs)
  let dt = json_number(json_field(json_field(manifest, "layout"), "dt_s"))
  let loaded : Map[String, ReferenceArchive] = Map([])
  for clip in clips {
    loaded[json_text(json_field(clip.metadata, "id"))] = clip
  }
  let records : Map[String, Json] = Map([])
  for record in json_array(json_field(report, "physical_records")) {
    records[json_text(json_field(record, "episode_id"))] = record
  }
  let traces : Map[(String, Bool), Json] = Map([])
  let materialize = async fn(trials : Array[Json], planned : Bool) {
    let result : Array[Json] = []
    for trial in trials {
      let episode_id = json_text(json_field(trial, "episode_id"))
      let key = (episode_id, planned)
      if !traces.contains(key) {
        let record = records[episode_id]
        let arrays = load_record_arrays(study, record)
        traces[key] = trace_trial(
          runtime,
          loaded[json_text(json_field(record, "reference_id"))],
          record,
          trial,
          arrays,
          planned,
          dt,
        )
      }
      result.push(traces[key])
    }
    result
  }
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy", recursive=true)
  }
  if !@fs.exists(output + "/collection") {
    @fs.mkdir(output + "/collection", recursive=true)
  }
  let quality = json_field(report, "quality_target")
  let protocol : Json = {
    "kind": "reference-remainder",
    "clip_duration_s": 30,
    "origins_s": json_field(quality, "origins_s"),
    "scope": json_field(quality, "scope"),
    "duration_semantics": "Remaining 30/20/10 s from known reference origins",
  }
  let runs : Array[Json] = []
  for candidate in json_array(json_field(report, "runs")) {
    if json_text(json_field(candidate, "method")) != method_name {
      continue
    }
    let seed = json_integer(json_field(candidate, "seed"))
    let (baseline, baseline_role) = comparison_baseline(
      report, method_name, seed,
    )
    let base = materialize(json_array(json_field(baseline, "trials")), false)
    let selected = materialize(
      json_array(json_field(candidate, "trials")),
      true,
    )
    let cycles = json_array(json_field(candidate, "cycles"))
    guard !cycles.is_empty() else {
      fail("candidate needs at least one training cycle")
    }
    let model = json_fields(json_field(cycles[cycles.length() - 1], "model"))
    let physics : Json = {
      "baseline": { "summary": trial_summary(base), "trials": base },
      "candidate": {
        "summary": trial_summary(selected),
        "trials": selected,
        "pooled_metrics": json_field(candidate, "summary"),
        "quality": json_field(candidate, "quality"),
      },
      "baseline_role": baseline_role,
      "evaluation_protocol": protocol,
      "tracking_quality_target": quality,
      "training": {
        "method": method_name,
        "actor_origin_sampling": if method_name == "prefix-only" {
          "reset-starts"
        } else {
          "trajectory-states"
        },
        "cycles": cycles.length(),
        "model_replay_mode": model
        .get("replay_mode")
        .unwrap_or("recent-fifo".to_json()),
        "model_replay_window_capacity": json_field(
          json_field(report, "config"),
          "model_replay_windows",
        ),
        "initial_anchor_windows": model.get("anchor_windows").unwrap_or(Json(0)),
        "shared_initial_actor_sha256": json_field(
          report, "initialization_sha256",
        ),
        "source_study_sha256": report_sha,
        "physical_records_new": json_field(report, "new_physical_records"),
        "physical_records_reused": json_field(report, "reused_physical_records"),
      },
      "replay_source": "MuJoCo pose/contact reconstruction of original numeric archives (historical Float32 or native Float64); original scalar quality retained",
      "physical_execution_allowed": false,
    }
    ignore(
      @artifacts.save_json(
        output + "/policy/physics-seed-\{seed}.json",
        physics,
      ),
    )
    runs.push({
      "seed": seed,
      "selected_update": json_field(candidate, "actor_optimizer_steps"),
      "baseline": trial_summary(base),
      "candidate": trial_summary(selected),
      "qualifies": json_field(
        json_field(candidate, "quality"),
        "quality_passed",
      ),
      "checkpoint": if config_default(
          report,
          "checkpoint_format",
          "moonrobo.g1-reference-actor.v1".to_json(),
        ) ==
        "moonrobo.g1-reference-actor.moonbit.v1".to_json() {
        "actor-seed-\{seed}.json"
      } else {
        "actor-seed-\{seed}.pt"
      },
      "latest_checkpoint": if config_default(
          report,
          "checkpoint_format",
          "moonrobo.g1-reference-actor.v1".to_json(),
        ) ==
        "moonrobo.g1-reference-actor.moonbit.v1".to_json() {
        "actor-seed-\{seed}.json"
      } else {
        "actor-seed-\{seed}.pt"
      },
    })
  }
  guard !runs.is_empty() else { fail("selected method has no runs") }
  let mut representative : Json? = None
  for record in records.values() {
    if json_text(json_field(record, "role")) == "common-first-collection" {
      representative = Some(record)
      break
    }
  }
  guard representative is Some(record) else {
    fail("common first collection record absent")
  }
  let arrays = load_record_arrays(study, record)
  let reference = loaded[json_text(json_field(record, "reference_id"))]
  let episode = representative_episode(reference, record, arrays, dt, true)
  ignore(
    @artifacts.save_json(
      output + "/collection/dataset.json.gz",
      dataset(
        runtime, episode, manifest, dt, "One common training episode only; all paired physical archives are separately registered",
      ),
    ),
  )
  let policy : Json = {
    "format": "moonrobo.g1-reference-learning-fit.v1",
    "runs": runs,
    "experiment": { "duration_s": 30, "control_dt_s": dt },
    "evaluation_protocol": protocol,
    "qualification_scope": quality,
    "method": method_name,
    "checkpoint_format": config_default(
      report,
      "checkpoint_format",
      "moonrobo.g1-reference-actor.v1".to_json(),
    ),
    "training_scope": "Shared inherited actor prior; independent seeded learning; known reference coverage",
    "mean_joint_rmse_semantics": "Arithmetic mean of trial RMSEs; pooled source metrics retained separately",
    "collection_role": "One common training episode, not the entire fitting corpus; all \{records.length()} paired numeric archives are registered",
    "release_qualified": false,
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/policy/report.json", policy))
  let metadata : Json = {
    "format": "moonrobo.g1-reference-learning-registry-export.v1",
    "method": method_name,
    "source_report_sha256": report_sha,
    "verification_sha256": source_digest(verification),
    "physical_episodes": records.length(),
    "reference_clips": clips.length(),
    "runs": runs,
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/export.json", metadata))
  metadata
}
