///|
fn aligned_field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(value) else {
    fail("missing aligned report field: " + name)
  }
  value
}

///|
fn aligned_string(value : Json) -> String raise {
  guard value is String(value) else { fail("expected aligned report string") }
  value
}

///|
fn import_aligned_experiment(
  root : String,
  run_dir : String,
  id : String,
  now_ms : Int64,
  report : Json,
) -> LearningExperiment raise {
  let evaluation = @json.parse(
    @fsx.read_file_to_string(run_dir + "/evaluation.json"),
  )
  guard evaluation
    is { "format": "moonrobo.supermimic-full-clip-evaluation.v1", .. } else {
    fail("aligned import requires the original full-clip evaluation report")
  }
  let checksum = need(@blob.local_file_checksum(run_dir + "/checkpoint.pt"))
  guard checksum ==
    "sha256:" + aligned_string(aligned_field(report, "checkpoint_sha256")) &&
    aligned_field(report, "checkpoint_sha256") ==
    aligned_field(evaluation, "checkpoint_sha256") &&
    aligned_field(report, "identity") == aligned_field(evaluation, "identity") else {
    fail("aligned training/evaluation/checkpoint binding mismatch")
  }
  let native_export = @json.parse(
    @fsx.read_file_to_string(run_dir + "/native-export.json"),
  )
  guard native_export
    is {
      "format": "moonrobo.aligned-native-export.v1",
      "native_validation_passed": True,
      "physical_execution_allowed": False,
      ..
    } &&
    aligned_field(native_export, "checkpoint_sha256") ==
    aligned_field(report, "checkpoint_sha256") &&
    need(@blob.local_file_checksum(run_dir + "/collection/dataset.json")) ==
    "sha256:" + aligned_string(aligned_field(native_export, "dataset_sha256")) else {
    fail("aligned native dataset export is missing or changed")
  }
  let payloads = [
    seal(root, run_dir, "report.json", "learning-aligned-training-report"),
    seal(
      root, run_dir, "evaluation.json", "learning-aligned-full-clip-evaluation",
    ),
    seal(root, run_dir, "checkpoint.pt", "learning-aligned-checkpoint"),
    seal(
      root, run_dir, "collection/dataset.json", "learning-transition-dataset",
    ),
    seal(root, run_dir, "native-export.json", "learning-aligned-native-export"),
  ]
  let summary : LearningExperiment = {
    format: "moonrobo.learning-experiment.v1",
    experiment_id: id,
    source_id: source_id(id),
    imported_at_ms: now_ms,
    evidence_class: if aligned_field(report, "profile") == Json("cpu-smoke") ||
      aligned_field(report, "profile") == Json("smc-protocol-cpu-check") {
      "physics-simulation-method-smoke"
    } else {
      "physics-simulation-method-aligned"
    },
    physical_execution_allowed: false,
    // The legacy candidate contract requires a matched baseline and uses
    // different metrics. Empty means no such comparison has been registered.
    candidates: [],
    payloads,
  }
  let summary_blob = need(
    @blob.put_local_bytes(
      root,
      @utf8.encode(summary.to_json().stringify(indent=2)),
      kind="learning-summary",
      content_type="application/json",
    ),
  )
  let refs = [summary_blob.data_ref]
  for payload in payloads {
    if !refs.any(value => value.uri == payload.data_ref.uri) {
      refs.push(payload.data_ref)
    }
  }
  let identity = aligned_field(report, "identity")
  let source = @data.data_source(
    source_id(id),
    "learning-experiment",
    "Aligned learning experiment " + id,
    "g1-simulation",
    aligned_string(aligned_field(identity, "backend")),
    "file://" + run_dir,
    now_ms,
    source_refs=refs,
  )
  ignore(need(@store.write_source(root, source)))
  ignore(need(@index.rebuild_catalog(root, now_ms)))
  summary
}
