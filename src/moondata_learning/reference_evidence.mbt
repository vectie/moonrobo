///|
priv struct ReferenceEvidenceFile {
  file : String
  sha256 : String
} derive(FromJson)

///|
priv struct ReferenceEvidenceLog {
  records : Array[ReferenceEvidenceFile]
} derive(FromJson)

///|
priv struct ReferenceStudyEvidence {
  format : String
  reference_manifest_sha256 : String
  quality_sha256 : String
  feedback_checkpoint_sha256 : String
  provider_sha256 : String
  actor_provider_sha256 : String
  harness_sha256 : String
  evaluations : Array[ReferenceEvidenceLog]
  baseline : ReferenceEvidenceLog
} derive(FromJson)

///|
priv struct ReferenceManifestEvidence {
  format : String
  source_physics_sha256 : String
  clips : Array[ReferenceEvidenceFile]
} derive(FromJson)

///|
fn safe_reference_path(path : String, prefix : String) -> Bool {
  path.has_prefix(prefix) &&
  !path.contains("\\") &&
  path.split("/").all(part => !part.is_empty() && part != "." && part != "..")
}

///|
fn seal_reference_evidence(
  root : String,
  run_dir : String,
) -> Array[LearningPayload] raise {
  let study_path = "policy/reference-study.json"
  let manifest_path = "collection/reference/manifest.json"
  let study : ReferenceStudyEvidence = @json.from_json(
    @json.parse(@fsx.read_file_to_string(run_dir + "/" + study_path)),
  )
  let manifest : ReferenceManifestEvidence = @json.from_json(
    @json.parse(@fsx.read_file_to_string(run_dir + "/" + manifest_path)),
  )
  guard study.format == "moonrobo.g1-reference-initialization.v1" &&
    manifest.format == "moonrobo.g1-full-body-reference.v1" &&
    !manifest.clips.is_empty() else {
    fail("expected reference initialization study and motion manifest")
  }
  let result : Array[LearningPayload] = []
  let paths : Map[String, Bool] = Map([])
  let checked = fn(
    relative : String,
    kind : String,
    digest : String,
  ) -> Unit raise {
    guard !paths.contains(relative) else {
      fail("duplicate reference evidence path")
    }
    let payload = seal(root, run_dir, relative, kind)
    guard payload.data_ref.checksum == "sha256:" + digest else {
      fail("reference evidence checksum mismatch")
    }
    paths[relative] = true
    result.push(payload)
  }
  for
    (path, kind, digest) in [
      (
        manifest_path,
        "learning-reference-manifest",
        study.reference_manifest_sha256,
      ),
      (
        "collection/reference-quality.json",
        "learning-reference-quality",
        study.quality_sha256,
      ),
      (
        "collection/reference-feedback.pt",
        "learning-reference-feedback",
        study.feedback_checkpoint_sha256,
      ),
      (
        "collection/reference/source-physics.jsonl.gz",
        "learning-reference-source-physics",
        manifest.source_physics_sha256,
      ),
      (
        "provider-sources/reference_initialization.py",
        "learning-reference-provider",
        study.provider_sha256,
      ),
      (
        "provider-sources/reference_actor.py",
        "learning-reference-provider",
        study.actor_provider_sha256,
      ),
      (
        "provider-sources/full_body_reference.py",
        "learning-reference-provider",
        study.harness_sha256,
      ),
    ] {
    checked(path, kind, digest)
  }
  let records : Array[ReferenceEvidenceFile] = []
  for evaluation in study.evaluations + [study.baseline] {
    records.append(evaluation.records)
  }
  guard !records.is_empty() else {
    fail("reference study has no physical records")
  }
  for clip in manifest.clips {
    guard safe_reference_path(clip.file, "clips/") else {
      fail("unsafe reference clip path")
    }
    checked(
      "collection/reference/" + clip.file,
      "learning-reference-clip",
      clip.sha256,
    )
  }
  for record in records {
    guard safe_reference_path(record.file, "physics/") else {
      fail("unsafe reference physics path")
    }
    checked(record.file, "learning-reference-physics", record.sha256)
  }
  let verification = @json.parse(
    @fsx.read_file_to_string(run_dir + "/policy/reference-verification.json"),
  )
  guard verification
    is {
      "source_report_sha256": String(report_sha),
      "native_verification": {
        "all_episodes_validated": True,
        "episodes": Number(episodes, ..),
        ..
      },
      "physical_execution_allowed": False,
      ..
    } &&
    episodes == records.length().to_double() else {
    fail("missing complete native reference verification")
  }
  checked(study_path, "learning-reference-study", report_sha)
  for
    (path, kind) in [
      ("policy/reference-verification.json", "learning-reference-verification"),
      ("policy/reference-charter.json", "learning-reference-charter"),
      ("policy/actor-zero-output.pt", "learning-reference-baseline"),
      ("provider-sources/balance_features.py", "learning-reference-provider"),
      ("provider-sources/cpu_physics.py", "learning-reference-provider"),
      (
        "provider-sources/reference_initialization_export.py", "learning-reference-provider",
      ),
      (
        "provider-sources/reference_registry_export.py", "learning-reference-provider",
      ),
    ] {
    result.push(seal(root, run_dir, path, kind))
  }
  result
}
