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
fn remove_file_if_exists(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    @fsx.remove_file(path) catch {
      _ => fail("failed to remove stale test file: " + path)
    }
  }
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
  remove_file_if_exists(
    @moondata_store.validation_report_path(root, "validation-32"),
  )
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
test "catalog validation blocks noncanonical manifest paths" {
  let root = "target/moondata-validate-canonical-path-test"
  ignore(@moondata_store.initialize_root(root))
  let quality = @moondata_core.quality_run(
    "quality-canonical-path",
    "dataset-canonical-path",
    [],
    6L,
    [],
  )
  let persisted = match @moondata_store.write_quality_run(root, quality) {
    Ok(value) => value
    Err(_) => fail("write quality failed")
  }
  let catalog = @moondata_core.moondata_catalog(root, 7L, [
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      "quality-canonical-path-alias",
      persisted.path,
      status=quality.status,
    ),
  ])
  ignore(@moondata_store.write_catalog(root, catalog))
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "catalog-entry-noncanonical-path", "quality-run"),
  )
}

///|
test "root validation blocks stored manifests missing from catalog" {
  let root = "target/moondata-validate-catalog-completeness-test"
  ignore(@moondata_store.initialize_root(root))
  let source = @moondata_core.data_source(
    "source-uncataloged", "import", "uncataloged source", "robot-validate", "bridge-validate",
    "file:///tmp/uncataloged.csv", 6L,
  )
  ignore(@moondata_store.write_source(root, source))
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 7L, []),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "manifest-missing-catalog-entry", "source"))
}

///|
test "catalog validation blocks annotation target indexes without annotation set" {
  let root = "target/moondata-validate-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let index = @moondata_core.annotation_target_index(
    "annotation-target-validate",
    "missing-annotation-set",
    [],
    "reviewer-validate",
    "accepted",
    9L,
  )
  let persisted = match
    @moondata_store.write_annotation_target_index(root, index) {
    Ok(value) => value
    Err(_) => fail("write annotation target index failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 10L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=index.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=11L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(
      report, "moondata-ref-missing-catalog-entry", "annotation-target-index",
    ),
  )
}

///|
test "catalog validation blocks annotation sets without target indexes" {
  let root = "target/moondata-validate-missing-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let annotation = @moondata_core.annotation_set(
    "annotation-missing-index",
    [],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-validate-test",
      ),
    ],
    "reviewer-validate",
    12L,
    status="accepted",
  )
  let persisted = match @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 13L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=annotation.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=14L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "annotation-target-index-missing", "annotation-set"),
  )
}

///|
test "catalog validation blocks stale annotation target indexes" {
  let root = "target/moondata-validate-stale-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let annotation = @moondata_core.annotation_set(
    "annotation-stale-index",
    [],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-validate-test",
      ),
    ],
    "reviewer-validate",
    12L,
    status="accepted",
  )
  let index = @moondata_core.annotation_target_index(
    "annotation-target-stale",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["rejected"],
  )
  let annotation_persisted = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  let index_persisted = match
    @moondata_store.write_annotation_target_index(root, index) {
    Ok(value) => value
    Err(_) => fail("write annotation target index failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 13L, [
        @moondata_core.catalog_entry(
          annotation_persisted.artifact_kind,
          annotation_persisted.artifact_id,
          annotation_persisted.path,
          status=annotation.status,
        ),
        @moondata_core.catalog_entry(
          index_persisted.artifact_kind,
          index_persisted.artifact_id,
          index_persisted.path,
          status=index.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=14L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(
      report, "annotation-target-index-stale", "annotation-target-index",
    ),
  )
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
test "catalog validation checks signal series storage refs" {
  let root = "target/moondata-validate-signal-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let signal = @moondata_core.signal_series(
    "signal-missing-payload",
    "dataset-signal",
    "episode-signal",
    "joint.position",
    "rad",
    1,
    "unix-ms",
    @moondata_core.data_ref(
      "signal-payload-missing",
      "raw-file",
      "moondata://media/imports/dataset-signal/missing.csv",
      content_type="text/csv",
    ),
  )
  let persisted = match @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 26L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=27L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "data-ref-missing-local-payload", "signal-series"),
  )
}

///|
test "catalog validation blocks dangling signal dataset and episode references" {
  let root = "target/moondata-validate-signal-reference-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-signal-ref") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-signal-ref/payload.csv",
    "t,x\n1,2\n",
  ) catch {
    _ => fail("write signal payload failed")
  }
  let signal = @moondata_core.signal_series(
    "signal-dangling-ref",
    "dataset-signal-missing",
    "episode-signal-missing",
    "joint.velocity",
    "rad/s",
    1,
    "unix-ms",
    @moondata_core.data_ref(
      "signal-payload-ref",
      "raw-file",
      "moondata://media/imports/dataset-signal-ref/payload.csv",
      content_type="text/csv",
      byte_count=8L,
      checksum=@moondata_core.text_checksum("t,x\n1,2\n"),
    ),
  )
  let persisted = match @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 28L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=29L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "signal-series"),
  )
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

///|
test "catalog validation blocks cross-dataset handoff references" {
  let root = "target/moondata-validate-dataset-graph-test"
  ignore(@moondata_store.initialize_root(root))
  let owner = @moondata_core.dataset_manifest(
    "dataset-owner", "curated", "active", 40L,
  )
  let other = @moondata_core.dataset_manifest(
    "dataset-other", "curated", "active", 41L,
  )
  let other_episode = @moondata_core.episode_manifest(
    "episode-other",
    other.dataset_id,
    "robot-graph",
    "bridge-graph",
    "session-graph",
    "stopped",
    42L,
    stopped_at_ms=Some(43L),
  )
  let other_quality = @moondata_core.quality_run(
    "quality-other",
    other.dataset_id,
    [other_episode.episode_id],
    44L,
    [],
  )
  let owner_version = @moondata_core.dataset_version(
    "version-owner",
    owner.dataset_id,
    "accepted",
    45L,
    accepted_episode_ids=[other_episode.episode_id],
    quality_run_ids=[other_quality.quality_run_id],
  )
  let owner_export = @moondata_core.export_manifest(
    "export-owner",
    owner_version.version_id,
    owner.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [],
    46L,
    quality_run_ids=[other_quality.quality_run_id],
  )
  let owner_persisted = match @moondata_store.write_dataset(root, owner) {
    Ok(value) => value
    Err(_) => fail("write owner dataset failed")
  }
  let other_persisted = match @moondata_store.write_dataset(root, other) {
    Ok(value) => value
    Err(_) => fail("write other dataset failed")
  }
  let episode_persisted = match
    @moondata_store.write_episode(root, other_episode) {
    Ok(value) => value
    Err(_) => fail("write other episode failed")
  }
  let quality_persisted = match
    @moondata_store.write_quality_run(root, other_quality) {
    Ok(value) => value
    Err(_) => fail("write other quality failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, owner_version) {
    Ok(value) => value
    Err(_) => fail("write owner version failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, owner_export) {
    Ok(value) => value
    Err(_) => fail("write owner export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 47L, [
        @moondata_core.catalog_entry(
          owner_persisted.artifact_kind,
          owner_persisted.artifact_id,
          owner_persisted.path,
          status=owner.status,
        ),
        @moondata_core.catalog_entry(
          other_persisted.artifact_kind,
          other_persisted.artifact_id,
          other_persisted.path,
          status=other.status,
        ),
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=other_episode.status,
        ),
        @moondata_core.catalog_entry(
          quality_persisted.artifact_kind,
          quality_persisted.artifact_id,
          quality_persisted.path,
          status=other_quality.status,
        ),
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=owner_version.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=owner_export.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=48L) {
    Ok(value) => value
    Err(_) => fail("validate graph failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-dataset-mismatch", "dataset-version"),
  )
  assert_true(
    has_finding(report, "moondata-ref-dataset-mismatch", "export-manifest"),
  )
}
