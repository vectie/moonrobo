///|
test "quality run status follows blocker and warning counts" {
  let findings = [
    @moondata_core.quality_finding(
      "find-1", "missing-frame", "blocker", "episode", "ep-1", "missing frame",
    ),
    @moondata_core.quality_finding(
      "find-2", "timestamp-gap", "warning", "frame", "frame-2", "large gap",
    ),
  ]
  let run = @moondata_core.quality_run("qr-1", "ds-1", ["ep-1"], 10L, findings)
  assert_eq(run.status, "blocked")
  assert_eq(run.finding_count, 2)
  assert_eq(run.blocker_count, 1)
  assert_eq(run.warning_count, 1)
}

///|
test "manifest json exposes stable ids" {
  let dataset = @moondata_core.dataset_manifest(
    "ds-noetix-1",
    "canonical",
    "active",
    42L,
    source_ids=["src-1"],
    capture_ids=["cap-1"],
    episode_ids=["ep-1"],
  )
  let text = @moondata_core.dataset_json(dataset)
  assert_true(text.contains("\"dataset_id\": \"ds-noetix-1\""))
  assert_true(text.contains("\"episode_ids\""))
}

///|
test "version transform and export contracts share ids" {
  let version = @moondata_core.dataset_version(
    "version-a",
    "dataset-curated",
    "accepted",
    42L,
    parent_version_ids=["version-parent"],
    accepted_episode_ids=["episode-a"],
    quality_run_ids=["quality-a"],
    summary="accepted for evaluation",
  )
  let step = @moondata_core.transform_step(
    "step-a",
    "drop-rejected",
    "{}",
    summary="keep accepted episodes",
  )
  let run = @moondata_core.transform_run(
    "transform-a",
    "dataset-raw",
    version.dataset_id,
    42L,
    [step],
    quality_run_ids=version.quality_run_ids,
    lineage_id="lineage-a",
  )
  let output = @moondata_core.data_ref(
    "export-a-ref",
    "dataset-export",
    "moondata://exports/export-a.jsonl",
    content_type="application/jsonl",
  )
  let manifest = @moondata_core.export_manifest(
    "export-a",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"frame\":\"payload\"}",
    [output],
    43L,
    quality_run_ids=version.quality_run_ids,
  )
  assert_eq(run.output_dataset_id, manifest.dataset_id)
  assert_eq(manifest.input_version_id, version.version_id)
  assert_eq(run.step_count, 1)
}

///|
test "catalog exposes bounded moondata refs" {
  let entry = @moondata_core.catalog_entry(
    "dataset",
    "dataset-a",
    "datasets/canonical/dataset-a.json",
    status="active",
    summary="canonical dataset",
  )
  let catalog = @moondata_core.moondata_catalog("moondata", 50L, [entry])
  let refs = @moondata_core.catalog_refs(catalog)
  assert_eq(catalog.entry_count, 1)
  assert_eq(refs[0].artifact_kind, "dataset")
  assert_eq(refs[0].artifact_id, "dataset-a")
}

///|
test "text checksum is stable for payload refs" {
  assert_eq(
    @moondata_core.text_checksum("{\"t\":1}"),
    "text-sum-v1:7:193761392",
  )
}
