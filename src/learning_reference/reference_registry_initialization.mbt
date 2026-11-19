///|
pub async fn export_initialization_registry(
  study : String,
  references : String,
  verification : String,
  runtime : @physics.Runtime,
  output : String,
  provider_source : String,
) -> Json {
  let report_path = study + "/report.json"
  let report = @artifacts.load_json(report_path)
  let report_sha = source_digest(report_path)
  let proof = @artifacts.load_json(verification)
  guard json_text(json_field(proof, "source_report_sha256")) == report_sha &&
    json_boolean(
      json_field(
        json_field(proof, "native_verification"),
        "all_episodes_validated",
      ),
    ) else {
    fail("reference registration needs matching complete native verification")
  }
  let manifest_sha = source_digest(references + "/manifest.json")
  guard manifest_sha ==
    json_text(json_field(report, "reference_manifest_sha256")) else {
    fail("reference manifest changed")
  }
  let (manifest, clips) = load_references(references)
  let dt = json_number(json_field(json_field(manifest, "layout"), "dt_s"))
  let loaded : Map[String, ReferenceArchive] = Map([])
  for clip in clips {
    loaded[json_text(json_field(clip.metadata, "id"))] = clip
  }
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy", recursive=true)
  }
  if !@fs.exists(output + "/collection") {
    @fs.mkdir(output + "/collection", recursive=true)
  }
  let materialized : Map[String, Array[Json]] = Map([])
  let mut representative = false
  let evaluations = json_array(json_field(report, "evaluations")).copy()
  evaluations.push(json_field(report, "baseline"))
  let mut physical_episodes = 0
  for evaluation in evaluations {
    let trials : Map[String, Json] = Map([])
    for trial in json_array(json_field(evaluation, "trials")) {
      trials[json_text(json_field(trial, "episode_id"))] = trial
    }
    let converted : Array[Json] = []
    let label = json_text(json_field(evaluation, "label"))
    for record in json_array(json_field(evaluation, "records")) {
      let arrays = load_record_arrays(study, record)
      let reference = loaded[json_text(json_field(record, "reference_id"))]
      converted.push(
        trace_trial(
          runtime,
          reference,
          record,
          trials[json_text(json_field(record, "episode_id"))],
          arrays,
          label != "zero-output",
          dt,
        ),
      )
      physical_episodes += 1
      if !representative {
        let episode = representative_episode(
          reference, record, arrays, dt, false,
        )
        ignore(
          @artifacts.save_json(
            output + "/collection/dataset.json.gz",
            dataset(
              runtime, episode, manifest, dt, "First evaluated policy episode only; fitted corpus is all source reference clips",
            ),
          ),
        )
        representative = true
      }
    }
    materialized[label] = converted
  }
  let quality = json_field(report, "quality_target")
  let protocol : Json = {
    "kind": "reference-remainder",
    "clip_duration_s": 30,
    "origins_s": json_field(quality, "origins_s"),
    "scope": json_field(quality, "scope"),
    "duration_semantics": "Each origin runs the remaining reference, 30/20/10 s; correlated known training clips",
  }
  let baseline = materialized["zero-output"]
  let fits = json_array(json_field(report, "fits"))
  let evaluated = json_array(json_field(report, "evaluations"))
  guard fits.length() == evaluated.length() else {
    fail("fit/evaluation count mismatch")
  }
  let runs : Array[Json] = []
  for i, fit in fits {
    let evaluation = evaluated[i]
    let seed = json_integer(json_field(fit, "seed"))
    let candidates = materialized[json_text(json_field(evaluation, "label"))]
    let physics : Json = {
      "baseline": { "summary": trial_summary(baseline), "trials": baseline },
      "candidate": {
        "summary": trial_summary(candidates),
        "trials": candidates,
        "pooled_metrics": json_field(evaluation, "summary"),
        "quality": json_field(evaluation, "quality"),
      },
      "baseline_role": "zero learned residual with the same fixed actual-minus-reference balance feedback; same 27 conditions reused for each training seed",
      "evaluation_protocol": protocol,
      "tracking_quality_target": quality,
      "replay_source": "pose/contact reconstruction from recorded states; planned reference continues to its declared end even if a policy falls",
      "physical_execution_allowed": false,
    }
    ignore(
      @artifacts.save_json(
        output + "/policy/physics-seed-\{seed}.json",
        physics,
      ),
    )
    let checkpoint = path_name(json_text(json_field(fit, "checkpoint")))
    runs.push({
      "seed": seed,
      "selected_update": json_field(fit, "updates"),
      "baseline": trial_summary(baseline),
      "candidate": trial_summary(candidates),
      "qualifies": json_field(
        json_field(evaluation, "quality"),
        "quality_passed",
      ),
      "checkpoint": checkpoint,
      "latest_checkpoint": checkpoint,
    })
  }
  let verification_sha = source_digest(verification)
  let policy : Json = {
    "format": "moonrobo.g1-reference-policy-fit.v1",
    "runs": runs,
    "experiment": { "duration_s": 30, "control_dt_s": dt },
    "evaluation_protocol": protocol,
    "checkpoint_format": config_default(
      report,
      "checkpoint_format",
      "moonrobo.g1-reference-actor.v1".to_json(),
    ),
    "qualification_scope": quality,
    "seed_semantics": "independent new reference encoder/decoder fits; shared fixed learned feedback and corpus",
    "mean_joint_rmse_semantics": "arithmetic mean of per-trial RMSE; physical report also retains pooled metrics",
    "collection_role": "first evaluated policy episode only; not fitted data. Complete fitted reference states and source-control labels in collection/reference clips",
    "physical_record_role": "all 108 saved numeric trajectories, linked by reference ID/hash and origin in reference-study.json",
    "reference_manifest_sha256": manifest_sha,
    "research_report_sha256": report_sha,
    "native_verification_sha256": verification_sha,
    "release_qualified": false,
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/policy/report.json", policy))
  let metadata : Json = {
    "format": "moonrobo.g1-reference-registry-export.v1",
    "provider_sha256": source_digest(provider_source),
    "source_report_sha256": report_sha,
    "verification_sha256": verification_sha,
    "runs": runs,
    "physical_episodes": physical_episodes,
    "reference_clips": clips.length(),
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/export.json", metadata))
  metadata
}
