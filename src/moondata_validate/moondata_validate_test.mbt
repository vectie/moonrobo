///|
fn has_finding(
  report : @moondata_core.ValidationReport,
  rule_id : String,
  artifact_kind : String,
) -> Bool {
  for finding in report.findings {
    if finding.rule_id == rule_id && finding.artifact_kind == artifact_kind {
      return true
    }
  }
  false
}

///|
test "catalog validation passes complete local catalog" {
  let root = "target/moondata-validate-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-validate", "canonical", "active", 1L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  let catalog = @moondata_core.moondata_catalog(root, 2L, [
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      persisted.artifact_id,
      persisted.path,
      status="active",
    ),
  ])
  ignore(@moondata_store.write_catalog(root, catalog))
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=3L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "passed")
  assert_eq(report.finding_count, 0)
  assert_eq(report.catalog_entry_count, 1)
}

///|
test "root validation persists and catalogs validation report" {
  let root = "target/moondata-validate-stored-report-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-stored-validation", "canonical", "active", 30L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 31L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let result = match
    @moondata_validate.validate_and_write_root(root, generated_at_ms=32L) {
    Ok(value) => value
    Err(_) => fail("stored validate root failed")
  }
  assert_eq(result.validation_report_id, "validation-32")
  assert_eq(result.status, "passed")
  assert_true(@fsx.path_exists(result.report_path))
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_eq(catalog.entry_count, 2)
  assert_true(catalog.entries[1].artifact_kind == "validation-report")
}

///|
test "catalog validation blocks duplicate and missing manifests" {
  let catalog = @moondata_core.moondata_catalog("moondata", 4L, [
    @moondata_core.catalog_entry("dataset", "dataset-a", "moondata://missing"),
    @moondata_core.catalog_entry(
      "dataset", "dataset-a", "moondata://missing-again",
    ),
  ])
  let report = @moondata_validate.validate_catalog(
    "moondata",
    catalog,
    generated_at_ms=5L,
    check_files=true,
  )
  assert_eq(report.status, "blocked")
  assert_true(report.blocker_count > 0)
  assert_true(report.warning_count > 0)
}

///|
test "catalog validation blocks missing local data ref payloads" {
  let root = "target/moondata-validate-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-missing-payload",
    "raw",
    "imported",
    6L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-missing",
        "raw-file",
        "moondata://media/imports/dataset-missing-payload/missing.json",
        content_type="application/json",
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 7L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status="imported",
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_eq(report.findings[0].rule_id, "data-ref-missing-local-payload")
}

///|
test "catalog validation checks export manifest output refs" {
  let root = "target/moondata-validate-export-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-export-validate",
    "dataset-export-validate",
    "accepted",
    9L,
    accepted_episode_ids=["episode-export-validate"],
    quality_run_ids=["qr-export-validate"],
  )
  let output = @moondata_core.data_ref(
    "export-output-validate",
    "export-jsonl",
    "moondata://exports/export-output-validate.jsonl",
    content_type="application/jsonl",
  )
  let manifest = @moondata_core.export_manifest(
    "export-validate",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    10L,
    quality_run_ids=version.quality_run_ids,
  )
  let persisted = match @moondata_store.write_export_manifest(root, manifest) {
    Ok(value) => value
    Err(_) => fail("write export manifest failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 11L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=12L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_eq(report.findings[0].artifact_kind, "export-manifest")
  assert_eq(report.findings[0].rule_id, "data-ref-missing-local-payload")
}

///|
test "catalog validation blocks local payload checksum drift" {
  let root = "target/moondata-validate-checksum-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-checksum") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-checksum/payload.json",
    "{\"t\":2}",
  ) catch {
    _ => fail("write payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-checksum",
    "raw",
    "imported",
    20L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-checksum",
        "raw-file",
        "moondata://media/imports/dataset-checksum/payload.json",
        content_type="application/json",
        byte_count=7L,
        checksum=@moondata_core.text_checksum("{\"t\":1}"),
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 21L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=22L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-checksum-mismatch", "dataset"))
}

///|
test "catalog validation blocks local payload byte count drift" {
  let root = "target/moondata-validate-byte-count-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-byte-count") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-byte-count/payload.json",
    "{\"t\":3}",
  ) catch {
    _ => fail("write payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-byte-count",
    "raw",
    "imported",
    23L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-byte-count",
        "raw-file",
        "moondata://media/imports/dataset-byte-count/payload.json",
        content_type="application/json",
        byte_count=99L,
        checksum=@moondata_core.text_checksum("{\"t\":3}"),
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 24L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=25L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-byte-count-mismatch", "dataset"))
}

///|
test "catalog validation blocks dangling dataset and episode references" {
  let root = "target/moondata-validate-reference-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-dangling-ref",
    "canonical",
    "active",
    13L,
    source_ids=["source-missing"],
    capture_ids=["capture-missing"],
    episode_ids=["episode-missing"],
    lineage_id="lineage-missing",
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 14L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=15L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "dataset"),
  )
}

///|
test "catalog validation blocks dangling version and export references" {
  let root = "target/moondata-validate-handoff-reference-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-dangling",
    "dataset-missing",
    "accepted",
    16L,
    parent_version_ids=["version-parent-missing"],
    accepted_episode_ids=["episode-missing"],
    quality_run_ids=["quality-missing"],
  )
  let manifest = @moondata_core.export_manifest(
    "export-dangling",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [],
    17L,
    quality_run_ids=version.quality_run_ids,
  )
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write version failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, manifest) {
    Ok(value) => value
    Err(_) => fail("write export manifest failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 18L, [
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=version.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=19L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "dataset-version"),
  )
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "export-manifest"),
  )
}
