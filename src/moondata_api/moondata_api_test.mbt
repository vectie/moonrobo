///|
test "status summarizes catalog entries for suite consumers" {
  let catalog = @moondata_core.moondata_catalog("moondata", 60L, [
    @moondata_core.catalog_entry(
      "dataset", "ds-1", "datasets/canonical/ds-1.json",
    ),
    @moondata_core.catalog_entry("quality-run", "qr-1", "quality/qr-1.json"),
    @moondata_core.catalog_entry(
      "transform-run", "tr-1", "transforms/tr-1.json",
    ),
    @moondata_core.catalog_entry(
      "dataset-version", "ver-1", "versions/ver-1.json",
    ),
    @moondata_core.catalog_entry(
      "annotation-set", "ann-1", "annotations/ann-1.json",
    ),
    @moondata_core.catalog_entry(
      "replay-artifact", "replay-1", "replays/replay-1.json",
    ),
    @moondata_core.catalog_entry(
      "export-manifest", "export-1", "exports/export-1.json",
    ),
    @moondata_core.catalog_entry(
      "validation-report",
      "validation-1",
      "validations/validation-1.json",
      status="passed",
    ),
  ])
  let status = @moondata_api.status_from_catalog("moondata", catalog)
  assert_true(status.ready)
  assert_eq(status.dataset_count, 1)
  assert_eq(status.curation_count, 2)
  assert_eq(status.export_count, 1)
  assert_eq(status.validation_count, 1)
  assert_eq(status.latest_validation_report_id, "validation-1")
  assert_eq(status.latest_validation_status, "passed")
  assert_eq(status.refs.length(), 8)
}

///|
test "context carries bounded refs and compact summary" {
  let catalog = @moondata_core.moondata_catalog("moondata", 61L, [
    @moondata_core.catalog_entry(
      "export-manifest", "export-1", "exports/export-1.json",
    ),
  ])
  let context = @moondata_api.context_from_status(
    @moondata_api.status_from_catalog("moondata", catalog),
  )
  assert_eq(context.status, "unvalidated")
  assert_true(context.summary.contains("1 cataloged artifact"))
  assert_true(context.summary.contains("validation unvalidated"))
  assert_eq(context.refs[0].artifact_kind, "export-manifest")
}

///|
test "context reports blocked latest validation status" {
  let catalog = @moondata_core.moondata_catalog("moondata", 62L, [
    @moondata_core.catalog_entry(
      "dataset", "ds-1", "datasets/canonical/ds-1.json",
    ),
    @moondata_core.catalog_entry(
      "validation-report",
      "validation-1",
      "validations/validation-1.json",
      status="passed",
    ),
    @moondata_core.catalog_entry(
      "validation-report",
      "validation-2",
      "validations/validation-2.json",
      status="blocked",
    ),
  ])
  let status = @moondata_api.status_from_catalog("moondata", catalog)
  let context = @moondata_api.context_from_status(status)
  assert_false(status.ready)
  assert_eq(status.validation_count, 2)
  assert_eq(status.latest_validation_report_id, "validation-2")
  assert_eq(context.status, "blocked")
}

///|
test "dataset slice reads version quality gates and exports from MoonData root" {
  let root = "target/moondata-api-slice-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-slice-curated",
    "curated",
    "accepted",
    70L,
    episode_ids=["ep-slice-1"],
  )
  let version = @moondata_core.dataset_version(
    "version-slice",
    dataset.dataset_id,
    "accepted",
    71L,
    accepted_episode_ids=dataset.episode_ids,
    quality_run_ids=["qr-slice"],
    summary="accepted slice version",
  )
  let quality = @moondata_core.quality_run(
    "qr-slice",
    dataset.dataset_id,
    dataset.episode_ids,
    72L,
    [],
  )
  let output = @moondata_core.data_ref(
    "export-slice-output",
    "export-jsonl",
    "moondata://exports/export-slice.jsonl",
    content_type="application/jsonl",
    byte_count=20L,
    checksum="text-sum-v1:20:123",
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-slice",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    73L,
    quality_run_ids=version.quality_run_ids,
  )
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write version failed")
  }
  let quality_persisted = match
    @moondata_store.write_quality_run(root, quality) {
    Ok(value) => value
    Err(_) => fail("write quality failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 74L, [
        @moondata_core.catalog_entry(
          dataset_persisted.artifact_kind,
          dataset_persisted.artifact_id,
          dataset_persisted.path,
          status=dataset.status,
        ),
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=version.status,
        ),
        @moondata_core.catalog_entry(
          quality_persisted.artifact_kind,
          quality_persisted.artifact_id,
          quality_persisted.path,
          status=quality.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=export_manifest.status,
        ),
      ]),
    ),
  )
  let slice = match @moondata_api.read_dataset_slice(root, version.version_id) {
    Ok(value) => value
    Err(_) => fail("read dataset slice failed")
  }
  assert_eq(slice.status, "ready")
  assert_eq(slice.accepted_episode_count, 1)
  assert_eq(slice.quality_gates[0].status, "passed")
  assert_eq(slice.exports[0].output_refs[0].checksum, "text-sum-v1:20:123")
  assert_eq(slice.refs.length(), 4)
}
