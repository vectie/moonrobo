///|
priv struct ReferenceLearningAsset {
  file : String
  sha256 : String
  kind : String
  episode_id : String
} derive(FromJson)

///|
priv struct ReferenceLearningManifest {
  format : String
  files : Array[ReferenceLearningAsset]
} derive(FromJson)

///|
priv struct ReferenceLearningRecord {
  episode_id : String
  sha256 : String
} derive(FromJson)

///|
priv struct ReferenceLearningStudy {
  format : String
  reference_manifest_sha256 : String
  physical_records : Array[ReferenceLearningRecord]
  runs : Array[Json]
  provider_sha256 : String
  learning_provider_sha256 : String
  task_provider_sha256 : String
  actor_provider_sha256 : String
} derive(FromJson)

///|
priv struct ReferenceLearningCycleEvidence {
  cycle : Int32
  checkpoint : ReferenceLearningCheckpointEvidence
} derive(FromJson)

///|
priv struct ReferenceLearningCheckpointEvidence {
  sha256 : String
} derive(FromJson)

///|
fn seal_reference_learning_evidence(
  root : String,
  run_dir : String,
) -> Array[LearningPayload] raise {
  let manifest_path = "policy/reference-learning-evidence.json"
  let manifest : ReferenceLearningManifest = @json.from_json(
    @json.parse(@fsx.read_file_to_string(run_dir + "/" + manifest_path)),
  )
  let study_path = "policy/reference-study.json"
  let study : ReferenceLearningStudy = @json.from_json(
    @json.parse(@fsx.read_file_to_string(run_dir + "/" + study_path)),
  )
  guard manifest.format == "moonrobo.g1-reference-learning-evidence.v1" &&
    study.format == "moonrobo.g1-reference-learning-comparison.v1" &&
    !study.physical_records.is_empty() else {
    fail("expected reference learning evidence and complete study")
  }
  let records : Map[String, String] = Map([])
  for record in study.physical_records {
    guard !records.contains(record.episode_id) else {
      fail("duplicate study episode")
    }
    records[record.episode_id] = record.sha256
  }
  let paths : Map[String, String] = Map([])
  let physics : Map[String, Bool] = Map([])
  let payloads : Array[LearningPayload] = []
  for file in manifest.files {
    guard safe_reference_path(file.file, "") && !paths.contains(file.file) else {
      fail("unsafe or duplicate learning evidence path")
    }
    let payload = seal(root, run_dir, file.file, file.kind)
    guard payload.data_ref.checksum == "sha256:" + file.sha256 else {
      fail("reference learning evidence checksum mismatch")
    }
    paths[file.file] = file.sha256
    if file.kind == "learning-reference-physics" {
      guard !physics.contains(file.episode_id) &&
        records.get(file.episode_id) == Some(file.sha256) else {
        fail("learning physics does not match study episode")
      }
      physics[file.episode_id] = true
    }
    payloads.push(payload)
  }
  guard physics.length() == records.length() &&
    paths.get("collection/reference/manifest.json") ==
    Some(study.reference_manifest_sha256) else {
    fail("missing full learning physics or reference manifest")
  }
  let reference : ReferenceManifestEvidence = @json.from_json(
    @json.parse(
      @fsx.read_file_to_string(run_dir + "/collection/reference/manifest.json"),
    ),
  )
  guard reference.format == "moonrobo.g1-full-body-reference.v1" &&
    paths.get("collection/reference/source-physics.jsonl.gz") ==
    Some(reference.source_physics_sha256) else {
    fail("missing reference source physics")
  }
  for clip in reference.clips {
    guard safe_reference_path(clip.file, "clips/") &&
      paths.get("collection/reference/" + clip.file) == Some(clip.sha256) else {
      fail("missing reference clip")
    }
  }
  for run in study.runs {
    guard run
      is {
        "method": String(algorithm),
        "seed": Number(seed, ..),
        "cycles": Array(cycles),
        ..
      } &&
      valid_id(algorithm) else {
      fail("invalid learning method")
    }
    for value in cycles {
      let cycle : ReferenceLearningCycleEvidence = @json.from_json(value)
      let prefix = "evidence/checkpoints/" +
        algorithm +
        "/seed-\{seed.to_int()}/"
      guard paths.get(prefix + "actor-cycle-\{cycle.cycle}.pt") ==
        Some(cycle.checkpoint.sha256) &&
        paths.contains(prefix + "dynamics-cycle-\{cycle.cycle}.pt") &&
        paths.contains(prefix + "value-cycle-\{cycle.cycle}.pt") else {
        fail("missing cycle policy/model/value evidence")
      }
    }
  }
  for
    (file, digest) in [
      ("reference_learning_study.py", study.provider_sha256),
      ("reference_learning.py", study.learning_provider_sha256),
      ("reference_task.py", study.task_provider_sha256),
      ("reference_actor.py", study.actor_provider_sha256),
    ] {
    guard paths.get("provider-sources/" + file) == Some(digest) else {
      fail("missing bound learning provider")
    }
  }
  let verification = @json.parse(
    @fsx.read_file_to_string(run_dir + "/policy/reference-verification.json"),
  )
  guard verification
    is {
      "source_report_sha256": String(study_sha),
      "native_verification": {
        "all_records_validated": True,
        "episodes": Number(count, ..),
        ..
      },
      "physical_execution_allowed": False,
      ..
    } &&
    paths.get(study_path) == Some(study_sha) &&
    count == records.length().to_double() &&
    paths.contains("policy/reference-verification.json") &&
    paths.contains("policy/reference-charter.json") &&
    paths.contains("collection/reference-quality.json") &&
    paths.contains("policy/actor-zero-output.pt") else {
    fail("missing matching native reference learning verification")
  }
  payloads.push(
    seal(root, run_dir, manifest_path, "learning-reference-learning-manifest"),
  )
  payloads
}
