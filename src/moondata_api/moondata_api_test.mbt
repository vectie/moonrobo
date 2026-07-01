///|
test "status summarizes catalog entries for suite consumers" {
  let catalog = @moondata_core.moondata_catalog("moondata", 60L, [
    @moondata_core.catalog_entry("source", "src-1", "sources/src-1.json"),
    @moondata_core.catalog_entry("capture", "cap-1", "captures/cap-1.json"),
    @moondata_core.catalog_entry(
      "dataset", "ds-1", "datasets/canonical/ds-1.json",
    ),
    @moondata_core.catalog_entry("episode", "ep-1", "episodes/ep-1.json"),
    @moondata_core.catalog_entry("frame", "frame-1", "frames/frame-1.json"),
    @moondata_core.catalog_entry("signal-series", "sig-1", "signals/sig-1.json"),
    @moondata_core.catalog_entry(
      "robot-model", "model-1", "robot_models/model-1.json",
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
      "annotation-target-index", "ann-index-1", "annotation_indexes/ann-index-1.json",
    ),
    @moondata_core.catalog_entry(
      "replay-artifact", "replay-1", "replays/replay-1.json",
    ),
    @moondata_core.catalog_entry(
      "export-manifest", "export-1", "exports/export-1.json",
    ),
    @moondata_core.catalog_entry(
      "lineage", "lineage-1", "lineage/lineage-1.json",
    ),
    @moondata_core.catalog_entry(
      "validation-report",
      "validation-1",
      "validations/validation-1.json",
      status="passed",
    ),
    @moondata_core.catalog_entry(
      "repair-run",
      "repair-1",
      "repairs/repair-1.json",
      status="blocked",
    ),
    @moondata_core.catalog_entry(
      "repair-receipt",
      "repair-receipt-1",
      "repair_receipts/repair-receipt-1.json",
      status="applied",
    ),
  ])
  let status = @moondata_api.status_from_catalog("moondata", catalog)
  assert_false(status.ready)
  assert_eq(status.source_count, 1)
  assert_eq(status.capture_count, 1)
  assert_eq(status.dataset_count, 1)
  assert_eq(status.episode_count, 1)
  assert_eq(status.frame_count, 1)
  assert_eq(status.signal_count, 1)
  assert_eq(status.robot_model_count, 1)
  assert_eq(status.quality_count, 1)
  assert_eq(status.transform_count, 1)
  assert_eq(status.version_count, 1)
  assert_eq(status.curation_count, 2)
  assert_eq(status.annotation_count, 1)
  assert_eq(status.annotation_index_count, 1)
  assert_eq(status.replay_count, 1)
  assert_eq(status.export_count, 1)
  assert_eq(status.lineage_count, 1)
  assert_eq(status.validation_count, 1)
  assert_eq(status.repair_count, 1)
  assert_eq(status.repair_receipt_count, 1)
  assert_eq(status.repair_work_count, 0)
  assert_eq(status.repair_open_count, 0)
  assert_eq(status.repair_applied_count, 0)
  assert_eq(status.repair_applied_unvalidated_count, 0)
  assert_eq(status.repair_failed_count, 0)
  assert_eq(status.repair_pending_count, 0)
  assert_eq(status.handoff_count, 0)
  assert_eq(status.latest_validation_report_id, "validation-1")
  assert_eq(status.latest_validation_status, "catalog-only")
  assert_eq(status.latest_validation_generated_at_ms, 0L)
  assert_eq(status.latest_validation_catalog_entry_count, 0)
  assert_false(status.latest_validation_covers_catalog)
  assert_eq(status.latest_validation_finding_count, 0)
  assert_eq(status.latest_validation_blocker_count, 0)
  assert_eq(status.latest_validation_warning_count, 0)
  assert_eq(status.refs.length(), 18)
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
  assert_false(context.ready)
  assert_eq(context.validation_report_id, "")
  assert_eq(context.validation_status, "unvalidated")
  assert_eq(context.validation_generated_at_ms, 0L)
  assert_eq(context.validation_catalog_entry_count, 0)
  assert_false(context.validation_covers_catalog)
  assert_eq(context.validation_finding_count, 0)
  assert_eq(context.validation_blocker_count, 0)
  assert_eq(context.validation_warning_count, 0)
  assert_eq(context.repair_work_count, 0)
  assert_eq(context.repair_open_count, 0)
  assert_eq(context.repair_applied_count, 0)
  assert_eq(context.repair_applied_unvalidated_count, 0)
  assert_eq(context.repair_failed_count, 0)
  assert_eq(context.repair_pending_count, 0)
  assert_true(context.summary.contains("1 cataloged artifact"))
  assert_true(context.summary.contains("0 capture"))
  assert_true(context.summary.contains("0 episode"))
  assert_true(context.summary.contains("0 frame"))
  assert_true(context.summary.contains("0 robot model"))
  assert_true(context.summary.contains("validation unvalidated"))
  assert_true(context.summary.contains("0 handoff dossier"))
  assert_true(context.summary.contains("0 blocker"))
  assert_true(context.summary.contains("repair work 0 action"))
  assert_eq(context.refs[0].artifact_kind, "export-manifest")
}

///|
test "context reports blocked latest validation status" {
  let root = "target/moondata-api-blocked-validation-status-test"
  ignore(@moondata_store.initialize_root(root))
  let passed = @moondata_core.validation_report(
    "validation-1",
    root,
    61L,
    "passed",
    3,
    0,
    0,
    0,
    [],
  )
  let blocked = @moondata_core.validation_report(
    "validation-2",
    root,
    62L,
    "blocked",
    3,
    1,
    1,
    0,
    [
      @moondata_core.validation_finding(
        "blocked-status-test", "blocker", "dataset", "ds-1", "blocked report should drive status",
      ),
    ],
  )
  let passed_persisted = match
    @moondata_store.write_validation_report(root, passed) {
    Ok(value) => value
    Err(_) => fail("write passed validation failed")
  }
  let blocked_persisted = match
    @moondata_store.write_validation_report(root, blocked) {
    Ok(value) => value
    Err(_) => fail("write blocked validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 62L, [
        @moondata_core.catalog_entry(
          "dataset", "ds-1", "datasets/canonical/ds-1.json",
        ),
        @moondata_core.catalog_entry(
          passed_persisted.artifact_kind,
          passed_persisted.artifact_id,
          passed_persisted.path,
          status="passed",
        ),
        @moondata_core.catalog_entry(
          blocked_persisted.artifact_kind,
          blocked_persisted.artifact_id,
          blocked_persisted.path,
          status="blocked",
        ),
      ]),
    ),
  )
  let status = match @moondata_api.read_status(root) {
    Ok(value) => value
    Err(_) => fail("read blocked status failed")
  }
  let context = @moondata_api.context_from_status(status)
  assert_false(status.ready)
  assert_eq(status.validation_count, 2)
  assert_eq(status.latest_validation_report_id, "validation-2")
  assert_eq(status.latest_validation_status, "blocked")
  assert_eq(status.latest_validation_generated_at_ms, 62L)
  assert_eq(status.latest_validation_catalog_entry_count, 3)
  assert_true(status.latest_validation_covers_catalog)
  assert_eq(status.latest_validation_finding_count, 1)
  assert_eq(status.latest_validation_blocker_count, 1)
  assert_eq(status.latest_validation_warning_count, 0)
  assert_eq(context.status, "blocked")
  assert_false(context.ready)
  assert_eq(context.validation_report_id, "validation-2")
  assert_eq(context.validation_status, "blocked")
  assert_eq(context.validation_generated_at_ms, 62L)
  assert_eq(context.validation_catalog_entry_count, 3)
  assert_true(context.validation_covers_catalog)
  assert_eq(context.validation_finding_count, 1)
  assert_eq(context.validation_blocker_count, 1)
  assert_eq(context.validation_warning_count, 0)
  assert_true(context.summary.contains("1 blocker"))
  let handoff = match @moondata_api.read_handoff(root) {
    Ok(value) => value
    Err(_) => fail("read blocked handoff failed")
  }
  assert_false(handoff.ready)
  assert_eq(handoff.readiness_status, "blocked")
  assert_eq(handoff.validation_findings.length(), 1)
  assert_eq(handoff.validation_findings[0].rule_id, "blocked-status-test")
  assert_eq(handoff.validation_findings[0].artifact_id, "ds-1")
}

///|
test "read status marks passed validation stale after catalog changes" {
  let root = "target/moondata-api-stale-validation-test"
  ignore(@moondata_store.initialize_root(root))
  let report = @moondata_core.validation_report(
    "validation-stale",
    root,
    70L,
    "passed",
    1,
    0,
    0,
    0,
    [],
  )
  let persisted = match @moondata_store.write_validation_report(root, report) {
    Ok(value) => value
    Err(_) => fail("write stale validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 71L, [
        @moondata_core.catalog_entry(
          "dataset", "ds-stale-validation", "datasets/canonical/ds-stale-validation.json",
        ),
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status="passed",
        ),
      ]),
    ),
  )
  let status = match @moondata_api.read_status(root) {
    Ok(value) => value
    Err(_) => fail("read status failed")
  }
  let context = @moondata_api.context_from_status(status)
  assert_false(status.ready)
  assert_eq(status.latest_validation_status, "stale")
  assert_eq(status.latest_validation_generated_at_ms, 70L)
  assert_eq(status.latest_validation_catalog_entry_count, 1)
  assert_false(status.latest_validation_covers_catalog)
  assert_eq(status.latest_validation_finding_count, 0)
  assert_eq(status.latest_validation_blocker_count, 0)
  assert_eq(status.latest_validation_warning_count, 0)
  assert_eq(context.status, "stale")
}

///|
test "read status chooses latest validation by report timestamp not catalog order" {
  let root = "target/moondata-api-validation-order-test"
  ignore(@moondata_store.initialize_root(root))
  let older = @moondata_core.validation_report(
    "validation-9",
    root,
    9L,
    "passed",
    2,
    0,
    0,
    0,
    [],
  )
  let newer = @moondata_core.validation_report(
    "validation-10",
    root,
    10L,
    "blocked",
    2,
    1,
    1,
    0,
    [
      @moondata_core.validation_finding(
        "validation-order-test", "blocker", "dataset", "ds-validation-order", "newer report must win over catalog order",
      ),
    ],
  )
  let older_persisted = match
    @moondata_store.write_validation_report(root, older) {
    Ok(value) => value
    Err(_) => fail("write older validation failed")
  }
  let newer_persisted = match
    @moondata_store.write_validation_report(root, newer) {
    Ok(value) => value
    Err(_) => fail("write newer validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 10L, [
        @moondata_core.catalog_entry(
          "dataset", "ds-validation-order", "datasets/canonical/ds-validation-order.json",
        ),
        @moondata_core.catalog_entry(
          newer_persisted.artifact_kind,
          newer_persisted.artifact_id,
          newer_persisted.path,
          status="blocked",
        ),
        @moondata_core.catalog_entry(
          older_persisted.artifact_kind,
          older_persisted.artifact_id,
          older_persisted.path,
          status="passed",
        ),
      ]),
    ),
  )
  let status = match @moondata_api.read_status(root) {
    Ok(value) => value
    Err(_) => fail("read status failed")
  }
  assert_false(status.ready)
  assert_eq(status.latest_validation_report_id, "validation-10")
  assert_eq(status.latest_validation_status, "blocked")
  assert_eq(status.latest_validation_generated_at_ms, 10L)
  assert_eq(status.latest_validation_catalog_entry_count, 2)
  assert_true(status.latest_validation_covers_catalog)
  assert_eq(status.latest_validation_finding_count, 1)
  assert_eq(status.latest_validation_blocker_count, 1)
  assert_eq(status.latest_validation_warning_count, 0)
}

///|
test "read status marks validation stale when report does not cover catalog count" {
  let root = "target/moondata-api-validation-count-coverage-test"
  ignore(@moondata_store.initialize_root(root))
  let report = @moondata_core.validation_report(
    "validation-count-coverage",
    root,
    80L,
    "passed",
    1,
    0,
    0,
    0,
    [],
  )
  let persisted = match @moondata_store.write_validation_report(root, report) {
    Ok(value) => value
    Err(_) => fail("write validation coverage report failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 80L, [
        @moondata_core.catalog_entry(
          "dataset", "ds-validation-count-a", "datasets/canonical/ds-validation-count-a.json",
        ),
        @moondata_core.catalog_entry(
          "dataset", "ds-validation-count-b", "datasets/canonical/ds-validation-count-b.json",
        ),
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status="passed",
        ),
      ]),
    ),
  )
  let status = match @moondata_api.read_status(root) {
    Ok(value) => value
    Err(_) => fail("read validation count coverage status failed")
  }
  let context = @moondata_api.context_from_status(status)
  assert_false(status.ready)
  assert_eq(status.latest_validation_report_id, "validation-count-coverage")
  assert_eq(status.latest_validation_status, "stale")
  assert_eq(status.latest_validation_generated_at_ms, 80L)
  assert_eq(status.latest_validation_catalog_entry_count, 1)
  assert_false(status.latest_validation_covers_catalog)
  assert_eq(context.status, "stale")
  assert_eq(context.validation_catalog_entry_count, 1)
  assert_false(context.validation_covers_catalog)
  assert_true(context.summary.contains("covered 1/3 catalog artifact"))
}

///|
test "artifact query lists catalog entries by kind status id and summary" {
  let root = "target/moondata-api-artifact-query-test"
  ignore(@moondata_store.initialize_root(root))
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 63L, [
        @moondata_core.catalog_entry(
          "dataset",
          "ds-artifact-active",
          "datasets/canonical/ds-artifact-active.json",
          status="active",
          summary="accepted canonical dataset",
        ),
        @moondata_core.catalog_entry(
          "dataset-version",
          "version-artifact-accepted",
          "versions/version-artifact-accepted.json",
          status="accepted",
          summary="accepted dataset version",
        ),
        @moondata_core.catalog_entry(
          "validation-report",
          "validation-artifact-passed",
          "validations/validation-artifact-passed.json",
          status="passed",
          summary="handoff validation report",
        ),
      ]),
    ),
  )
  let by_kind = match
    @moondata_api.list_artifacts(
      root,
      query=@moondata_api.artifact_query(artifact_kind="dataset"),
    ) {
    Ok(value) => value
    Err(_) => fail("list artifacts by kind failed")
  }
  assert_eq(by_kind.artifact_count, 1)
  assert_eq(by_kind.artifacts[0].artifact_id, "ds-artifact-active")
  let by_status = match
    @moondata_api.list_artifacts(
      root,
      query=@moondata_api.artifact_query(status="accepted"),
    ) {
    Ok(value) => value
    Err(_) => fail("list artifacts by status failed")
  }
  assert_eq(by_status.artifacts[0].artifact_kind, "dataset-version")
  let by_id = match
    @moondata_api.list_artifacts(
      root,
      query=@moondata_api.artifact_query(artifact_id_contains="artifact-passed"),
    ) {
    Ok(value) => value
    Err(_) => fail("list artifacts by id failed")
  }
  assert_eq(by_id.artifacts[0].artifact_id, "validation-artifact-passed")
  let by_summary = match
    @moondata_api.list_artifacts(
      root,
      query=@moondata_api.artifact_query(summary_contains="canonical"),
    ) {
    Ok(value) => value
    Err(_) => fail("list artifacts by summary failed")
  }
  assert_eq(by_summary.refs[0].artifact_kind, "dataset")
}

///|
test "dataset query lists cataloged datasets by kind status refs and data kind" {
  let root = "target/moondata-api-dataset-query-test"
  ignore(@moondata_store.initialize_root(root))
  let raw = @moondata_core.dataset_manifest(
    "ds-query-raw",
    "raw",
    "imported",
    63L,
    source_ids=["source-query"],
    capture_ids=["capture-query"],
    episode_ids=["episode-query"],
    data_refs=[
      @moondata_core.data_ref(
        "dataset-query-payload",
        "raw-file",
        "moondata://media/imports/ds-query-raw/payload.json",
        byte_count=17L,
      ),
    ],
  )
  let curated = @moondata_core.dataset_manifest(
    "ds-query-curated",
    "curated",
    "active",
    64L,
    episode_ids=["episode-query"],
  )
  let raw_persisted = match @moondata_store.write_dataset(root, raw) {
    Ok(value) => value
    Err(_) => fail("write raw dataset failed")
  }
  let curated_persisted = match @moondata_store.write_dataset(root, curated) {
    Ok(value) => value
    Err(_) => fail("write curated dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 65L, [
        @moondata_core.catalog_entry(
          raw_persisted.artifact_kind,
          raw_persisted.artifact_id,
          raw_persisted.path,
          status=raw.status,
        ),
        @moondata_core.catalog_entry(
          curated_persisted.artifact_kind,
          curated_persisted.artifact_id,
          curated_persisted.path,
          status=curated.status,
        ),
      ]),
    ),
  )
  let by_kind = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(kind="raw"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by kind failed")
  }
  assert_eq(by_kind.dataset_count, 1)
  assert_eq(by_kind.source_ref_count, 1)
  assert_eq(by_kind.capture_ref_count, 1)
  assert_eq(by_kind.episode_count, 1)
  assert_eq(by_kind.data_ref_count, 1)
  assert_eq(by_kind.total_data_byte_count, 17L)
  assert_eq(by_kind.latest_dataset_id, "ds-query-raw")
  assert_eq(by_kind.latest_dataset_status, "imported")
  assert_eq(by_kind.latest_dataset_created_at_ms, 63L)
  assert_eq(by_kind.datasets[0].dataset_id, "ds-query-raw")
  let by_status = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(status="active"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by status failed")
  }
  assert_eq(by_status.datasets[0].dataset_id, "ds-query-curated")
  assert_eq(by_status.latest_dataset_status, "active")
  let by_source = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(source_id="source-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by source failed")
  }
  assert_eq(by_source.dataset_count, 1)
  let by_capture = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(capture_id="capture-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by capture failed")
  }
  assert_eq(by_capture.dataset_count, 1)
  let by_episode = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(episode_id="episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by episode failed")
  }
  assert_eq(by_episode.dataset_count, 2)
  assert_eq(by_episode.episode_count, 2)
  assert_eq(by_episode.data_ref_count, 1)
  assert_eq(by_episode.latest_dataset_id, "ds-query-curated")
  let by_data_kind = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(data_kind="raw-file"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "dataset")
  assert_eq(by_data_kind.total_data_byte_count, 17L)
}

///|
test "source query lists cataloged sources by id kind robot bridge origin label and data kind" {
  let root = "target/moondata-api-source-query-test"
  ignore(@moondata_store.initialize_root(root))
  let source = @moondata_core.data_source(
    "source-query-local",
    "local-files",
    "bench capture source",
    "robot-source-query",
    "bridge-source-query",
    "file:///bench/source-query",
    66L,
    source_refs=[
      @moondata_core.data_ref(
        "source-query-ref",
        "raw-file",
        "moondata://media/imports/source-query.csv",
        byte_count=43L,
        checksum="text-sum-v1:43:430",
      ),
    ],
  )
  let persisted = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write source failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 67L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=source.kind,
          summary=source.label,
        ),
      ]),
    ),
  )
  let by_id = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(source_id_contains="query-local"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by id failed")
  }
  assert_eq(by_id.source_count, 1)
  assert_eq(by_id.source_ref_count, 1)
  assert_eq(by_id.total_source_byte_count, 43L)
  assert_eq(by_id.source_checksums[0], "text-sum-v1:43:430")
  assert_eq(by_id.latest_source_id, "source-query-local")
  assert_eq(by_id.latest_source_created_at_ms, 66L)
  assert_eq(by_id.sources[0].source_id, "source-query-local")
  let by_kind = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(kind="local-files"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by kind failed")
  }
  assert_eq(by_kind.source_count, 1)
  let by_robot = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(robot_id="robot-source-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by robot failed")
  }
  assert_eq(by_robot.source_count, 1)
  let by_bridge = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(bridge_id="bridge-source-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by bridge failed")
  }
  assert_eq(by_bridge.source_count, 1)
  let by_origin = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(origin_contains="bench"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by origin failed")
  }
  assert_eq(by_origin.source_count, 1)
  let by_label = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(label_contains="capture"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by label failed")
  }
  assert_eq(by_label.source_count, 1)
  let by_data_kind = match
    @moondata_api.list_sources(
      root,
      query=@moondata_api.source_query(data_kind="raw-file"),
    ) {
    Ok(value) => value
    Err(_) => fail("list source by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "source")
  assert_eq(by_data_kind.total_source_byte_count, 43L)
}

///|
test "data ref query projects embedded payload refs across cataloged manifests" {
  let root = "target/moondata-api-data-ref-query-test"
  ignore(@moondata_store.initialize_root(root))
  if !@fsx.path_exists(root + "/media/imports/data-ref") {
    @fsx.create_dir(root + "/media/imports/data-ref") catch {
      _ => fail("create data-ref payload dir failed")
    }
  }
  @fsx.write_string_to_file(
    root + "/media/imports/data-ref/source.csv",
    "present",
  ) catch {
    _ => fail("write present source payload failed")
  }
  @fsx.write_string_to_file(root + "/exports/data-ref.jsonl", "present export") catch {
    _ => fail("write present export payload failed")
  }
  @fsx.write_string_to_file(
    root + "/exports/data-ref-handoff.jsonl",
    "present handoff",
  ) catch {
    _ => fail("write present handoff payload failed")
  }
  let source_ref = @moondata_core.data_ref(
    "data-ref-source",
    "raw-file",
    "moondata://media/imports/data-ref/source.csv",
    content_type="text/csv",
    byte_count=7L,
    checksum="text-sum-v1:7:101",
  )
  let dataset_ref = @moondata_core.data_ref(
    "data-ref-dataset",
    "dataset-json",
    "moondata://datasets/raw/data-ref.json",
    content_type="application/json",
    byte_count=11L,
    checksum="text-sum-v1:11:102",
  )
  let payload_ref = @moondata_core.data_ref(
    "data-ref-payload",
    "telemetry-frame",
    "moondata://media/imports/data-ref/payload.json",
    content_type="application/json",
    byte_count=13L,
    checksum="text-sum-v1:13:103",
  )
  let frame_signal_ref = @moondata_core.data_ref(
    "data-ref-frame-signal",
    "signal-chunk",
    "moondata://media/imports/../data-ref-frame.bin",
    byte_count=17L,
    checksum="text-sum-v1:17:104",
  )
  let frame_media_ref = @moondata_core.data_ref(
    "data-ref-frame-media",
    "image",
    "moondata://media/imports/data-ref/frame.png",
    content_type="image/png",
    byte_count=19L,
    checksum="text-sum-v1:19:105",
  )
  let signal_storage_ref = @moondata_core.data_ref(
    "data-ref-signal-storage",
    "columnar",
    "file:///signals/data-ref-series.parquet",
    content_type="application/parquet",
    byte_count=23L,
    checksum="text-sum-v1:23:106",
  )
  let replay_ref = @moondata_core.data_ref(
    "data-ref-replay",
    "replay-payload",
    "moondata://media/replays/data-ref.json",
    content_type="application/json",
    byte_count=29L,
    checksum="text-sum-v1:29:107",
  )
  let export_ref = @moondata_core.data_ref(
    "data-ref-export",
    "export-jsonl",
    "moondata://exports/data-ref.jsonl",
    content_type="application/jsonl",
    byte_count=31L,
    checksum="text-sum-v1:31:108",
  )
  let handoff_ref = @moondata_core.data_ref(
    "data-ref-handoff-output",
    "export-jsonl",
    "moondata://exports/data-ref-handoff.jsonl",
    content_type="application/jsonl",
    byte_count=37L,
    checksum="text-sum-v1:37:109",
  )
  let source = @moondata_core.data_source(
    "source-data-ref",
    "local-files",
    "data ref source",
    "robot-data-ref",
    "bridge-data-ref",
    "file:///data-ref",
    76L,
    source_refs=[source_ref],
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-data-ref",
    "raw",
    "imported",
    77L,
    data_refs=[dataset_ref],
  )
  let frame = @moondata_core.frame_ref(
    "frame-data-ref",
    "ep-data-ref",
    "robot-data-ref",
    "bridge-data-ref",
    0,
    78L,
    payload_ref=Some(payload_ref),
    signal_refs=[frame_signal_ref],
    media_refs=[frame_media_ref],
  )
  let signal = @moondata_core.signal_series(
    "signal-data-ref",
    dataset.dataset_id,
    "ep-data-ref",
    "joint.velocity",
    "rad/s",
    3,
    "unix-ms",
    signal_storage_ref,
  )
  let replay = @moondata_core.replay_artifact(
    "replay-data-ref",
    dataset.dataset_id,
    ["ep-data-ref"],
    79L,
    generated_refs=[replay_ref],
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-data-ref",
    "version-data-ref",
    dataset.dataset_id,
    "jsonl",
    "{}",
    [export_ref],
    80L,
  )
  let export_moondata_ref = @moondata_core.moondata_ref(
    "export-manifest",
    export_manifest.export_manifest_id,
    @moondata_store.export_manifest_path(
      root,
      export_manifest.export_manifest_id,
    ),
    "data ref export",
  )
  let handoff_dossier = @moondata_core.handoff_dossier(
    "handoff-data-ref",
    "version-data-ref",
    true,
    "ready",
    "",
    "unvalidated",
    0L,
    0,
    false,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    [handoff_ref],
    [export_moondata_ref],
    [],
    81L,
    "data ref handoff",
  )
  let source_persisted = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write source failed")
  }
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  let frame_persisted = match @moondata_store.write_frame(root, frame) {
    Ok(value) => value
    Err(_) => fail("write frame failed")
  }
  let signal_persisted = match
    @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  let replay_persisted = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(_) => fail("write replay failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write export failed")
  }
  let handoff_persisted = match
    @moondata_store.write_handoff_dossier(root, handoff_dossier) {
    Ok(value) => value
    Err(_) => fail("write handoff failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 81L, [
        @moondata_core.catalog_entry(
          source_persisted.artifact_kind,
          source_persisted.artifact_id,
          source_persisted.path,
        ),
        @moondata_core.catalog_entry(
          dataset_persisted.artifact_kind,
          dataset_persisted.artifact_id,
          dataset_persisted.path,
        ),
        @moondata_core.catalog_entry(
          frame_persisted.artifact_kind,
          frame_persisted.artifact_id,
          frame_persisted.path,
        ),
        @moondata_core.catalog_entry(
          signal_persisted.artifact_kind,
          signal_persisted.artifact_id,
          signal_persisted.path,
        ),
        @moondata_core.catalog_entry(
          replay_persisted.artifact_kind,
          replay_persisted.artifact_id,
          replay_persisted.path,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
        ),
        @moondata_core.catalog_entry(
          handoff_persisted.artifact_kind,
          handoff_persisted.artifact_id,
          handoff_persisted.path,
        ),
      ]),
    ),
  )
  let all = match @moondata_api.list_data_refs(root) {
    Ok(value) => value
    Err(_) => fail("list data refs failed")
  }
  assert_eq(all.data_ref_count, 9)
  assert_eq(all.total_byte_count, 187L)
  assert_eq(all.checksums.length(), 9)
  assert_eq(all.checksums[0], "text-sum-v1:7:101")
  assert_eq(all.checksums[8], "text-sum-v1:37:109")
  assert_eq(all.present_count, 3)
  assert_eq(all.missing_count, 3)
  assert_eq(all.non_payload_count, 1)
  assert_eq(all.unsafe_count, 1)
  assert_eq(all.external_count, 1)
  let by_payload = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(
        artifact_kind="frame",
        artifact_id="frame-data-ref",
        ref_role="payload",
        data_kind="telemetry-frame",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list data refs by frame payload failed")
  }
  assert_eq(by_payload.data_ref_count, 1)
  assert_eq(by_payload.total_byte_count, 13L)
  assert_eq(by_payload.checksums[0], "text-sum-v1:13:103")
  assert_eq(by_payload.data_refs[0].data_ref.ref_id, "data-ref-payload")
  assert_eq(by_payload.data_refs[0].local_status, "missing")
  assert_eq(by_payload.data_refs[0].payload_root, "media/imports")
  let by_storage = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(
        ref_role="storage",
        data_kind="columnar",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list data refs by storage failed")
  }
  assert_eq(by_storage.refs[0].artifact_kind, "signal-series")
  assert_eq(by_storage.data_refs[0].local_status, "external")
  let by_export = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(
        uri_contains="exports",
        content_type="application/jsonl",
        checksum="text-sum-v1:31:108",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list data refs by export failed")
  }
  assert_eq(by_export.data_refs[0].artifact_kind, "export-manifest")
  assert_eq(by_export.total_byte_count, 31L)
  assert_eq(by_export.checksums[0], "text-sum-v1:31:108")
  assert_eq(by_export.data_refs[0].local_status, "present")
  let by_missing = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(local_status="missing"),
    ) {
    Ok(value) => value
    Err(_) => fail("list data refs by local status failed")
  }
  assert_eq(by_missing.data_ref_count, 3)
  assert_eq(by_missing.missing_count, 3)
  let by_handoff = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(
        artifact_kind="handoff-dossier",
        ref_role="output",
        checksum="text-sum-v1:37:109",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list data refs by handoff failed")
  }
  assert_eq(by_handoff.data_ref_count, 1)
  assert_eq(by_handoff.data_refs[0].artifact_id, "handoff-data-ref")
  assert_eq(by_handoff.data_refs[0].data_ref.ref_id, "data-ref-handoff-output")
  assert_eq(by_handoff.total_byte_count, 37L)
}

///|
test "payload query groups unique URIs and reports owner metadata conflicts" {
  let root = "target/moondata-api-payload-query-test"
  ignore(@moondata_store.initialize_root(root))
  if !@fsx.path_exists(root + "/media/imports/payload-query") {
    @fsx.create_dir(root + "/media/imports/payload-query") catch {
      _ => fail("create payload query dir failed")
    }
  }
  @fsx.write_string_to_file(
    root + "/media/imports/payload-query/shared.json",
    "{\"t\":1}",
  ) catch {
    _ => fail("write shared payload failed")
  }
  let uri = "moondata://media/imports/payload-query/shared.json"
  let source_ref = @moondata_core.data_ref(
    "payload-query-source-ref",
    "telemetry-frame",
    uri,
    byte_count=7L,
    checksum="text-sum-v1:7:101",
  )
  let capture_ref = @moondata_core.data_ref(
    "payload-query-capture-ref",
    "telemetry-frame",
    uri,
    byte_count=8L,
    checksum="text-sum-v1:8:999",
  )
  let source = @moondata_core.data_source(
    "source-payload-query",
    "sidecar",
    "payload query source",
    "robot-payload-query",
    "bridge-payload-query",
    "sidecar://query-session",
    91L,
    source_refs=[source_ref],
  )
  let capture = @moondata_core.capture_session(
    "capture-payload-query",
    source.source_id,
    "robot-payload-query",
    "bridge-payload-query",
    "stopped",
    92L,
    data_refs=[capture_ref],
  )
  let source_persisted = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write payload query source failed")
  }
  let capture_persisted = match @moondata_store.write_capture(root, capture) {
    Ok(value) => value
    Err(_) => fail("write payload query capture failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 93L, [
        @moondata_core.catalog_entry(
          source_persisted.artifact_kind,
          source_persisted.artifact_id,
          source_persisted.path,
        ),
        @moondata_core.catalog_entry(
          capture_persisted.artifact_kind,
          capture_persisted.artifact_id,
          capture_persisted.path,
        ),
      ]),
    ),
  )
  let payloads = match @moondata_api.list_payloads(root) {
    Ok(value) => value
    Err(_) => fail("list payloads failed")
  }
  assert_eq(payloads.payload_count, 1)
  assert_eq(payloads.owner_count, 2)
  assert_eq(payloads.present_count, 1)
  assert_eq(payloads.conflict_count, 1)
  assert_false(payloads.payloads[0].metadata_consistent)
  assert_eq(payloads.payloads[0].payload_root, "media/imports")
  assert_eq(payloads.payloads[0].owners[0].artifact_kind, "source")
  assert_eq(payloads.payloads[0].owners[1].artifact_kind, "capture")
  let conflicts = match
    @moondata_api.list_payloads(
      root,
      query=@moondata_api.payload_query(metadata_status="conflict"),
    ) {
    Ok(value) => value
    Err(_) => fail("list payload conflicts failed")
  }
  assert_eq(conflicts.payload_count, 1)
  assert_eq(conflicts.conflict_count, 1)
  let consistent = match
    @moondata_api.list_payloads(
      root,
      query=@moondata_api.payload_query(metadata_status="consistent"),
    ) {
    Ok(value) => value
    Err(_) => fail("list consistent payloads failed")
  }
  assert_eq(consistent.payload_count, 0)
}

///|
test "robot model query projects model refs and payload inventory" {
  let root = "target/moondata-api-robot-model-query-test"
  ignore(@moondata_store.initialize_root(root))
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-api-urdf",
    "urdf",
    "moondata://media/robot_models/api/robot.urdf",
    content_type="application/xml",
    byte_count=10L,
    checksum="text-sum-v1:10:501",
  )
  let mesh_ref = @moondata_core.data_ref(
    "robot-model-api-mesh",
    "stl",
    "moondata://media/robot_models/api/meshes/base.stl",
    byte_count=20L,
    checksum="text-sum-v1:20:502",
  )
  let material_ref = @moondata_core.data_ref(
    "robot-model-api-material",
    "material",
    "moondata://media/robot_models/api/materials/base.json",
    content_type="application/json",
    byte_count=30L,
    checksum="text-sum-v1:30:503",
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-api",
    "robot-api",
    "urdf",
    "active",
    urdf_ref,
    90L,
    mesh_refs=[mesh_ref],
    material_refs=[material_ref],
    link_names=["base_link", "torso"],
    joint_names=["hip_yaw"],
    provenance="api test import",
    validation_status="passed",
    summary="API robot model",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 91L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
          summary=model.summary,
        ),
      ]),
    ),
  )
  let all_models = match @moondata_api.list_robot_models(root) {
    Ok(value) => value
    Err(_) => fail("list robot models failed")
  }
  assert_eq(all_models.model_count, 1)
  assert_eq(all_models.data_ref_count, 3)
  assert_eq(all_models.total_model_byte_count, 60L)
  assert_eq(all_models.model_checksums.length(), 3)
  assert_eq(all_models.latest_model_id, "robot-model-api")
  assert_eq(all_models.refs[0].artifact_kind, "robot-model")
  let filtered = match
    @moondata_api.list_robot_models(
      root,
      query=@moondata_api.robot_model_query(
        robot_id="robot-api",
        format="urdf",
        validation_status="passed",
        data_kind="stl",
        link_name="base_link",
        joint_name="hip_yaw",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("filter robot models failed")
  }
  assert_eq(filtered.model_count, 1)
  assert_eq(filtered.models[0].model_id, "robot-model-api")
  let mesh_refs = match
    @moondata_api.list_data_refs(
      root,
      query=@moondata_api.data_ref_query(
        artifact_kind="robot-model",
        artifact_id="robot-model-api",
        ref_role="mesh",
        data_kind="stl",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list robot model data refs failed")
  }
  assert_eq(mesh_refs.data_ref_count, 1)
  assert_eq(mesh_refs.total_byte_count, 20L)
  assert_eq(mesh_refs.data_refs[0].data_ref.ref_id, "robot-model-api-mesh")
}

///|
test "quality query lists cataloged quality runs by dataset episode status severity and rule" {
  let root = "target/moondata-api-quality-query-test"
  ignore(@moondata_store.initialize_root(root))
  let finding = @moondata_core.quality_finding(
    "finding-quality-query", "timestamp-gap", "warning", "episode", "episode-quality-query",
    "timestamp gap exceeded threshold",
  )
  let run = @moondata_core.quality_run(
    "qr-quality-query",
    "ds-quality-query",
    ["episode-quality-query"],
    66L,
    [finding],
  )
  let persisted = match @moondata_store.write_quality_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write quality run failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 67L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=run.status,
          summary="quality query run",
        ),
      ]),
    ),
  )
  let by_dataset = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(dataset_id="ds-quality-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by dataset failed")
  }
  assert_eq(by_dataset.quality_count, 1)
  assert_eq(by_dataset.finding_count, 1)
  assert_eq(by_dataset.blocker_count, 0)
  assert_eq(by_dataset.warning_count, 1)
  assert_eq(by_dataset.latest_quality_run_id, "qr-quality-query")
  assert_eq(by_dataset.latest_quality_status, "review")
  assert_eq(by_dataset.latest_quality_created_at_ms, 66L)
  assert_eq(by_dataset.quality_runs[0].quality_run_id, "qr-quality-query")
  let by_episode = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(episode_id="episode-quality-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by episode failed")
  }
  assert_eq(by_episode.quality_count, 1)
  let by_status = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(status="review"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by status failed")
  }
  assert_eq(by_status.quality_count, 1)
  assert_eq(by_status.finding_count, 1)
  assert_eq(by_status.warning_count, 1)
  let by_severity = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(severity="warning"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by severity failed")
  }
  assert_eq(by_severity.quality_count, 1)
  assert_eq(by_severity.latest_quality_status, "review")
  let by_rule = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(rule_id="timestamp-gap"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by rule failed")
  }
  assert_eq(by_rule.refs[0].artifact_kind, "quality-run")
}

///|
test "version query lists cataloged versions by dataset status parent episode quality and summary" {
  let root = "target/moondata-api-version-query-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-query",
    "ds-version-query",
    "accepted",
    68L,
    parent_version_ids=["version-parent-query"],
    accepted_episode_ids=["episode-version-query"],
    quality_run_ids=["qr-version-query"],
    summary="accepted training split",
  )
  let persisted = match @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write version failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 69L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=version.status,
          summary=version.summary,
        ),
      ]),
    ),
  )
  let by_dataset = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(dataset_id="ds-version-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by dataset failed")
  }
  assert_eq(by_dataset.version_count, 1)
  assert_eq(by_dataset.accepted_episode_count, 1)
  assert_eq(by_dataset.parent_version_count, 1)
  assert_eq(by_dataset.quality_gate_count, 1)
  assert_eq(by_dataset.latest_version_id, "version-query")
  assert_eq(by_dataset.latest_version_status, "accepted")
  assert_eq(by_dataset.latest_version_created_at_ms, 68L)
  assert_eq(by_dataset.versions[0].version_id, "version-query")
  let by_status = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(status="accepted"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by status failed")
  }
  assert_eq(by_status.version_count, 1)
  let by_parent = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(
        parent_version_id="version-parent-query",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by parent failed")
  }
  assert_eq(by_parent.version_count, 1)
  let by_episode = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(episode_id="episode-version-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by episode failed")
  }
  assert_eq(by_episode.version_count, 1)
  assert_eq(by_episode.accepted_episode_count, 1)
  let by_quality = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(quality_run_id="qr-version-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by quality failed")
  }
  assert_eq(by_quality.version_count, 1)
  assert_eq(by_quality.quality_gate_count, 1)
  let by_summary = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(summary_contains="training"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by summary failed")
  }
  assert_eq(by_summary.refs[0].artifact_kind, "dataset-version")
  assert_eq(by_summary.latest_version_status, "accepted")
}

///|
test "export query lists cataloged manifests by version dataset format status quality and output" {
  let root = "target/moondata-api-export-query-test"
  ignore(@moondata_store.initialize_root(root))
  let output = @moondata_core.data_ref(
    "export-query-output",
    "jsonl",
    "moondata://exports/export-query.jsonl",
    content_type="application/jsonl",
    byte_count=42L,
    checksum="text-sum-v1:42:4242",
  )
  let manifest = @moondata_core.export_manifest(
    "export-query",
    "version-export-query",
    "ds-export-query",
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    70L,
    quality_run_ids=["qr-export-query"],
    status="ready",
    report="query export manifest",
  )
  let persisted = match @moondata_store.write_export_manifest(root, manifest) {
    Ok(value) => value
    Err(_) => fail("write export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 71L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=manifest.status,
          summary=manifest.report,
        ),
      ]),
    ),
  )
  let by_version = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(version_id="version-export-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by version failed")
  }
  assert_eq(by_version.export_count, 1)
  assert_eq(by_version.output_ref_count, 1)
  assert_eq(by_version.total_output_byte_count, 42L)
  assert_eq(by_version.output_checksums[0], "text-sum-v1:42:4242")
  assert_eq(by_version.exports[0].export_manifest_id, "export-query")
  let by_dataset = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(dataset_id="ds-export-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by dataset failed")
  }
  assert_eq(by_dataset.export_count, 1)
  let by_format = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(target_format="jsonl"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by format failed")
  }
  assert_eq(by_format.export_count, 1)
  let by_status = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(status="ready"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by status failed")
  }
  assert_eq(by_status.export_count, 1)
  let by_quality = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(quality_run_id="qr-export-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by quality failed")
  }
  assert_eq(by_quality.export_count, 1)
  let by_output = match
    @moondata_api.list_exports(
      root,
      query=@moondata_api.export_query(output_kind="jsonl"),
    ) {
    Ok(value) => value
    Err(_) => fail("list export by output failed")
  }
  assert_eq(by_output.refs[0].artifact_kind, "export-manifest")
  assert_true(by_output.summary.contains("1 output ref"))
  assert_true(by_output.summary.contains("42 byte"))
}

///|
test "transform query lists cataloged runs by datasets status quality lineage rejected refs and step" {
  let root = "target/moondata-api-transform-query-test"
  ignore(@moondata_store.initialize_root(root))
  let rejected = @moondata_core.moondata_ref(
    "frame",
    "frame-transform-rejected",
    @moondata_store.frame_path(root, "frame-transform-rejected"),
    "rejected transform frame",
  )
  let run = @moondata_core.transform_run(
    "transform-query",
    "ds-transform-input",
    "ds-transform-output",
    72L,
    [
      @moondata_core.transform_step(
        "step-transform-normalize",
        "normalize",
        "{}",
        summary="normalize source payload",
      ),
    ],
    quality_run_ids=["qr-transform-query"],
    rejected_refs=[rejected],
    lineage_id="lineage-transform-query",
    summary="query transform run",
  )
  let persisted = match @moondata_store.write_transform_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write transform failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 73L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=run.status,
          summary=run.summary,
        ),
      ]),
    ),
  )
  let by_input = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(input_dataset_id="ds-transform-input"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by input failed")
  }
  assert_eq(by_input.transform_count, 1)
  assert_eq(by_input.step_count, 1)
  assert_eq(by_input.rejected_ref_count, 1)
  assert_eq(by_input.quality_gate_count, 1)
  assert_eq(by_input.latest_transform_run_id, "transform-query")
  assert_eq(by_input.latest_transform_status, "completed")
  assert_eq(by_input.latest_transform_created_at_ms, 72L)
  assert_eq(by_input.transforms[0].transform_run_id, "transform-query")
  let by_output = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(
        output_dataset_id="ds-transform-output",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by output failed")
  }
  assert_eq(by_output.transform_count, 1)
  let by_status = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(status="completed"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by status failed")
  }
  assert_eq(by_status.transform_count, 1)
  let by_quality = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(quality_run_id="qr-transform-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by quality failed")
  }
  assert_eq(by_quality.transform_count, 1)
  let by_lineage = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(lineage_id="lineage-transform-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by lineage failed")
  }
  assert_eq(by_lineage.transform_count, 1)
  let by_rejected = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(
        rejected_artifact_kind="frame",
        rejected_artifact_id="frame-transform-rejected",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by rejected ref failed")
  }
  assert_eq(by_rejected.transform_count, 1)
  assert_eq(by_rejected.rejected_ref_count, 1)
  let by_step = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(step_kind="normalize"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by step failed")
  }
  assert_eq(by_step.transform_count, 1)
  assert_eq(by_step.step_count, 1)
  let by_summary = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(summary_contains="query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by summary failed")
  }
  assert_eq(by_summary.refs[0].artifact_kind, "transform-run")
  assert_eq(by_summary.latest_transform_status, "completed")
}

///|
test "validation query lists cataloged reports by status and findings" {
  let root = "target/moondata-api-validation-query-test"
  ignore(@moondata_store.initialize_root(root))
  let finding = @moondata_core.validation_finding(
    "manifest-missing", "blocker", "dataset", "ds-validation-query", "dataset manifest is missing",
  )
  let report = @moondata_core.validation_report(
    "validation-query",
    root,
    76L,
    "blocked",
    0,
    1,
    1,
    0,
    [finding],
  )
  let persisted = match @moondata_store.write_validation_report(root, report) {
    Ok(value) => value
    Err(_) => fail("write validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 75L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=report.status,
          summary="blocked validation report",
        ),
      ]),
    ),
  )
  let by_status = match
    @moondata_api.list_validations(
      root,
      query=@moondata_api.validation_query(status="blocked"),
    ) {
    Ok(value) => value
    Err(_) => fail("list validation by status failed")
  }
  assert_eq(by_status.validation_count, 1)
  assert_eq(by_status.finding_count, 1)
  assert_eq(by_status.blocker_count, 1)
  assert_eq(by_status.warning_count, 0)
  assert_eq(by_status.latest_validation_report_id, "validation-query")
  assert_eq(by_status.latest_validation_status, "blocked")
  assert_eq(by_status.latest_validation_generated_at_ms, 76L)
  assert_eq(by_status.latest_validation_catalog_entry_count, 0)
  assert_eq(by_status.latest_validation_covers_catalog, true)
  assert_eq(by_status.validations[0].validation_report_id, "validation-query")
  let by_severity = match
    @moondata_api.list_validations(
      root,
      query=@moondata_api.validation_query(severity="blocker"),
    ) {
    Ok(value) => value
    Err(_) => fail("list validation by severity failed")
  }
  assert_eq(by_severity.validation_count, 1)
  assert_eq(by_severity.finding_count, 1)
  assert_eq(by_severity.blocker_count, 1)
  let by_rule = match
    @moondata_api.list_validations(
      root,
      query=@moondata_api.validation_query(rule_id="manifest-missing"),
    ) {
    Ok(value) => value
    Err(_) => fail("list validation by rule failed")
  }
  assert_eq(by_rule.validation_count, 1)
  assert_eq(by_rule.latest_validation_status, "blocked")
  let by_artifact = match
    @moondata_api.list_validations(
      root,
      query=@moondata_api.validation_query(
        artifact_kind="dataset",
        artifact_id="ds-validation-query",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list validation by artifact failed")
  }
  assert_eq(by_artifact.refs[0].artifact_kind, "validation-report")
}

///|
test "repair run query lists cataloged repair evidence by validation and action" {
  let root = "target/moondata-api-repair-query-test"
  ignore(@moondata_store.initialize_root(root))
  let action = @moondata_core.repair_action(
    "repair-api-action",
    "missing-payload",
    "blocker",
    "dataset",
    "dataset-repair-api",
    "data-ref-missing-local-payload",
    "missing payload",
    "restore payload",
    operation_kind="restore-or-remove-payload-ref",
    target_ref="dataset:dataset-repair-api",
  )
  let run = @moondata_core.repair_run(
    "repair-api-run",
    root,
    "validation-api-run",
    "blocked",
    86L,
    1,
    1,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    [action],
    [],
    "repair api run",
  )
  let persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write repair api run failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 87L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=run.validation_status,
        ),
      ]),
    ),
  )
  let repairs = match
    @moondata_api.list_repair_runs(
      root,
      query=@moondata_api.repair_run_query(category="missing-payload"),
    ) {
    Ok(value) => value
    Err(_) => fail("list repair runs failed")
  }
  assert_eq(repairs.repair_count, 1)
  assert_eq(repairs.action_count, 1)
  assert_eq(repairs.blocker_count, 1)
  assert_eq(repairs.missing_payload_count, 1)
  assert_eq(repairs.latest_repair_run_id, "repair-api-run")
  assert_eq(repairs.refs[0].artifact_kind, "repair-run")
  let by_rule = match
    @moondata_api.list_repair_runs(
      root,
      query=@moondata_api.repair_run_query(
        validation_report_id="validation-api-run",
        operation_kind="restore-or-remove-payload-ref",
        target_ref_contains="dataset-repair-api",
        rule_id="data-ref-missing-local-payload",
        artifact_kind="dataset",
        artifact_id="dataset-repair-api",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list repair runs by action failed")
  }
  assert_eq(by_rule.repair_count, 1)
  assert_eq(
    by_rule.repairs[0].actions[0].operation_kind,
    "restore-or-remove-payload-ref",
  )
  assert_eq(
    by_rule.repairs[0].actions[0].target_ref,
    "dataset:dataset-repair-api",
  )
  let by_missing = match
    @moondata_api.list_repair_runs(
      root,
      query=@moondata_api.repair_run_query(category="metadata-conflict"),
    ) {
    Ok(value) => value
    Err(_) => fail("list absent repair runs failed")
  }
  assert_eq(by_missing.repair_count, 0)
}

///|
test "repair receipt query lists recorded repair execution evidence" {
  let root = "target/moondata-api-repair-receipt-query-test"
  ignore(@moondata_store.initialize_root(root))
  let receipt = @moondata_core.repair_receipt(
    "repair-receipt-api",
    "repair-api-run",
    "repair-api-action",
    "restore-or-remove-payload-ref",
    "dataset:dataset-repair-api",
    "applied",
    "operator",
    88L,
    "validation-api-after-repair",
    summary="api repair receipt",
  )
  let persisted = match @moondata_store.write_repair_receipt(root, receipt) {
    Ok(value) => value
    Err(_) => fail("write repair receipt api failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 89L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=receipt.status,
        ),
      ]),
    ),
  )
  let receipts = match
    @moondata_api.list_repair_receipts(
      root,
      query=@moondata_api.repair_receipt_query(
        repair_run_id="repair-api-run",
        operation_kind="restore-or-remove-payload-ref",
        target_ref_contains="dataset-repair-api",
        status="applied",
        actor="operator",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list repair receipts failed")
  }
  assert_eq(receipts.receipt_count, 1)
  assert_eq(receipts.applied_count, 1)
  assert_eq(receipts.latest_repair_receipt_id, "repair-receipt-api")
  assert_eq(receipts.refs[0].artifact_kind, "repair-receipt")
}

///|
test "repair work query joins planned actions with latest receipts" {
  let root = "target/moondata-api-repair-work-query-test"
  ignore(@moondata_store.initialize_root(root))
  let missing_action = @moondata_core.repair_action(
    "repair-work-action-1",
    "missing-payload",
    "blocker",
    "dataset",
    "dataset-repair-work",
    "data-ref-missing-local-payload",
    "missing payload",
    "restore payload",
    operation_kind="restore-or-remove-payload-ref",
    target_ref="dataset:dataset-repair-work",
  )
  let unmanaged_action = @moondata_core.repair_action(
    "repair-work-action-2",
    "unmanaged-payload",
    "blocker",
    "payload",
    "moondata://media/imports/repair-work/unmanaged.json",
    "moondata-unmanaged-local-payload",
    "unmanaged payload",
    "declare payload",
    operation_kind="declare-or-remove-payload",
    target_ref="payload:moondata://media/imports/repair-work/unmanaged.json",
  )
  let run = @moondata_core.repair_run(
    "repair-work-run",
    root,
    "validation-repair-work",
    "blocked",
    90L,
    2,
    2,
    0,
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    [missing_action, unmanaged_action],
    [],
    "repair work run",
  )
  let run_persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write repair work run failed")
  }
  let receipt = @moondata_core.repair_receipt(
    "repair-work-receipt",
    run.repair_run_id,
    missing_action.action_id,
    missing_action.operation_kind,
    missing_action.target_ref,
    "applied",
    "operator",
    91L,
    "",
    summary="repair work receipt",
  )
  let receipt_persisted = match
    @moondata_store.write_repair_receipt(root, receipt) {
    Ok(value) => value
    Err(_) => fail("write repair work receipt failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 92L, [
        @moondata_core.catalog_entry(
          run_persisted.artifact_kind,
          run_persisted.artifact_id,
          run_persisted.path,
          status=run.validation_status,
        ),
        @moondata_core.catalog_entry(
          receipt_persisted.artifact_kind,
          receipt_persisted.artifact_id,
          receipt_persisted.path,
          status=receipt.status,
        ),
      ]),
    ),
  )
  let work = match @moondata_api.list_repair_work(root) {
    Ok(value) => value
    Err(_) => fail("list repair work failed")
  }
  assert_eq(work.work_item_count, 2)
  assert_eq(work.open_count, 1)
  assert_eq(work.applied_unvalidated_count, 1)
  assert_eq(work.latest_repair_run_id, "repair-work-run")
  assert_eq(work.latest_repair_generated_at_ms, 90L)
  assert_eq(work.latest_repair_receipt_id, "repair-work-receipt")
  assert_eq(work.latest_repair_receipt_applied_at_ms, 91L)
  assert_eq(work.refs[0].artifact_kind, "repair-work")
  let open_work = match
    @moondata_api.list_repair_work(
      root,
      query=@moondata_api.repair_work_query(
        work_status="open",
        operation_kind="declare-or-remove-payload",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list open repair work failed")
  }
  assert_eq(open_work.work_item_count, 1)
  assert_eq(open_work.work_items[0].action_id, "repair-work-action-2")
}

///|
test "repair work keeps applied receipts open until current validation passes" {
  let root = "target/moondata-api-repair-work-validation-test"
  ignore(@moondata_store.initialize_root(root))
  let stale_validation = @moondata_core.validation_report(
    "validation-repair-work-stale",
    root,
    100L,
    "passed",
    1,
    0,
    0,
    0,
    [],
  )
  let current_validation = @moondata_core.validation_report(
    "validation-repair-work-current",
    root,
    106L,
    "passed",
    4,
    0,
    0,
    0,
    [],
  )
  let stale_validation_persisted = match
    @moondata_store.write_validation_report(root, stale_validation) {
    Ok(value) => value
    Err(_) => fail("write stale repair work validation failed")
  }
  let current_validation_persisted = match
    @moondata_store.write_validation_report(root, current_validation) {
    Ok(value) => value
    Err(_) => fail("write current repair work validation failed")
  }
  let stale_action = @moondata_core.repair_action(
    "repair-work-stale-action",
    "missing-payload",
    "blocker",
    "dataset",
    "dataset-repair-work-stale",
    "data-ref-missing-local-payload",
    "missing payload",
    "restore payload",
    operation_kind="restore-or-remove-payload-ref",
    target_ref="dataset:dataset-repair-work-stale",
  )
  let current_action = @moondata_core.repair_action(
    "repair-work-current-action",
    "unmanaged-payload",
    "blocker",
    "payload",
    "moondata://media/imports/repair-work/current.json",
    "moondata-unmanaged-local-payload",
    "unmanaged payload",
    "declare payload",
    operation_kind="declare-or-remove-payload",
    target_ref="payload:moondata://media/imports/repair-work/current.json",
  )
  let run = @moondata_core.repair_run(
    "repair-work-validation-run",
    root,
    "",
    "blocked",
    103L,
    2,
    2,
    0,
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    [stale_action, current_action],
    [],
    "repair work validation run",
  )
  let run_persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write repair work validation run failed")
  }
  let stale_receipt = @moondata_core.repair_receipt(
    "repair-work-stale-receipt",
    run.repair_run_id,
    stale_action.action_id,
    stale_action.operation_kind,
    stale_action.target_ref,
    "applied",
    "operator",
    104L,
    stale_validation.validation_report_id,
    summary="stale validation receipt",
  )
  let current_receipt = @moondata_core.repair_receipt(
    "repair-work-current-receipt",
    run.repair_run_id,
    current_action.action_id,
    current_action.operation_kind,
    current_action.target_ref,
    "applied",
    "operator",
    104L,
    current_validation.validation_report_id,
    summary="current validation receipt",
  )
  let stale_receipt_persisted = match
    @moondata_store.write_repair_receipt(root, stale_receipt) {
    Ok(value) => value
    Err(_) => fail("write stale repair work receipt failed")
  }
  let current_receipt_persisted = match
    @moondata_store.write_repair_receipt(root, current_receipt) {
    Ok(value) => value
    Err(_) => fail("write current repair work receipt failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 106L, [
        @moondata_core.catalog_entry(
          stale_validation_persisted.artifact_kind,
          stale_validation_persisted.artifact_id,
          stale_validation_persisted.path,
          status=stale_validation.status,
        ),
        @moondata_core.catalog_entry(
          current_validation_persisted.artifact_kind,
          current_validation_persisted.artifact_id,
          current_validation_persisted.path,
          status=current_validation.status,
        ),
        @moondata_core.catalog_entry(
          run_persisted.artifact_kind,
          run_persisted.artifact_id,
          run_persisted.path,
          status=run.validation_status,
        ),
        @moondata_core.catalog_entry(
          stale_receipt_persisted.artifact_kind,
          stale_receipt_persisted.artifact_id,
          stale_receipt_persisted.path,
          status=stale_receipt.status,
        ),
        @moondata_core.catalog_entry(
          current_receipt_persisted.artifact_kind,
          current_receipt_persisted.artifact_id,
          current_receipt_persisted.path,
          status=current_receipt.status,
        ),
      ]),
    ),
  )
  let work = match @moondata_api.list_repair_work(root) {
    Ok(value) => value
    Err(_) => fail("list repair work validation failed")
  }
  assert_eq(work.work_item_count, 2)
  assert_eq(work.applied_count, 1)
  assert_eq(work.applied_unvalidated_count, 1)
  let applied = match
    @moondata_api.list_repair_work(
      root,
      query=@moondata_api.repair_work_query(work_status="applied"),
    ) {
    Ok(value) => value
    Err(_) => fail("list applied repair work validation failed")
  }
  assert_eq(applied.work_item_count, 1)
  assert_eq(applied.work_items[0].action_id, current_action.action_id)
  let unvalidated = match
    @moondata_api.list_repair_work(
      root,
      query=@moondata_api.repair_work_query(work_status="applied-unvalidated"),
    ) {
    Ok(value) => value
    Err(_) => fail("list stale repair work validation failed")
  }
  assert_eq(unvalidated.work_item_count, 1)
  assert_eq(unvalidated.work_items[0].action_id, stale_action.action_id)
}

///|
test "status and context report repair work pressure" {
  let root = "target/moondata-api-repair-pressure-status-test"
  ignore(@moondata_store.initialize_root(root))
  let missing_action = @moondata_core.repair_action(
    "repair-pressure-action-1",
    "missing-payload",
    "blocker",
    "dataset",
    "dataset-repair-pressure",
    "data-ref-missing-local-payload",
    "missing payload",
    "restore payload",
    operation_kind="restore-or-remove-payload-ref",
    target_ref="dataset:dataset-repair-pressure",
  )
  let unmanaged_action = @moondata_core.repair_action(
    "repair-pressure-action-2",
    "unmanaged-payload",
    "blocker",
    "payload",
    "moondata://media/imports/repair-pressure/unmanaged.json",
    "moondata-unmanaged-local-payload",
    "unmanaged payload",
    "declare payload",
    operation_kind="declare-or-remove-payload",
    target_ref="payload:moondata://media/imports/repair-pressure/unmanaged.json",
  )
  let run = @moondata_core.repair_run(
    "repair-pressure-run",
    root,
    "validation-repair-pressure",
    "blocked",
    93L,
    2,
    2,
    0,
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    [missing_action, unmanaged_action],
    [],
    "repair pressure run",
  )
  let run_persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write repair pressure run failed")
  }
  let receipt = @moondata_core.repair_receipt(
    "repair-pressure-receipt",
    run.repair_run_id,
    missing_action.action_id,
    missing_action.operation_kind,
    missing_action.target_ref,
    "applied",
    "operator",
    94L,
    "",
    summary="repair pressure receipt",
  )
  let receipt_persisted = match
    @moondata_store.write_repair_receipt(root, receipt) {
    Ok(value) => value
    Err(_) => fail("write repair pressure receipt failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 95L, [
        @moondata_core.catalog_entry(
          run_persisted.artifact_kind,
          run_persisted.artifact_id,
          run_persisted.path,
          status=run.validation_status,
        ),
        @moondata_core.catalog_entry(
          receipt_persisted.artifact_kind,
          receipt_persisted.artifact_id,
          receipt_persisted.path,
          status=receipt.status,
        ),
      ]),
    ),
  )
  let status = match @moondata_api.read_status(root) {
    Ok(value) => value
    Err(_) => fail("read repair pressure status failed")
  }
  assert_eq(status.repair_count, 1)
  assert_eq(status.repair_receipt_count, 1)
  assert_eq(status.repair_work_count, 2)
  assert_eq(status.repair_open_count, 1)
  assert_eq(status.repair_applied_count, 0)
  assert_eq(status.repair_applied_unvalidated_count, 1)
  assert_eq(status.repair_failed_count, 0)
  assert_eq(status.repair_pending_count, 0)
  let context = @moondata_api.context_from_status(status)
  assert_eq(context.repair_work_count, 2)
  assert_eq(context.repair_open_count, 1)
  assert_eq(context.repair_applied_count, 0)
  assert_eq(context.repair_applied_unvalidated_count, 1)
  assert_eq(context.repair_failed_count, 0)
  assert_eq(context.repair_pending_count, 0)
  assert_true(context.summary.contains("repair work 2 action"))
  assert_true(context.summary.contains("1 open"))
  assert_true(context.summary.contains("1 applied without validation"))
}

///|
test "capture query lists cataloged captures by source robot bridge status and data kind" {
  let root = "target/moondata-api-capture-query-test"
  ignore(@moondata_store.initialize_root(root))
  let capture = @moondata_core.capture_session(
    "capture-query",
    "source-query",
    "robot-query",
    "bridge-query",
    "stopped",
    63L,
    stopped_at_ms=Some(64L),
    receipt_ids=["receipt-capture-query"],
    data_refs=[
      @moondata_core.data_ref(
        "capture-query-payload",
        "telemetry-frame",
        "sidecar://robot-query/frame.json",
        byte_count=23L,
      ),
    ],
  )
  let capture_persisted = match @moondata_store.write_capture(root, capture) {
    Ok(value) => value
    Err(_) => fail("write capture failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 64L, [
        @moondata_core.catalog_entry(
          capture_persisted.artifact_kind,
          capture_persisted.artifact_id,
          capture_persisted.path,
          status=capture.status,
          summary="query capture",
        ),
      ]),
    ),
  )
  let by_source = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(source_id="source-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by source failed")
  }
  assert_eq(by_source.capture_count, 1)
  assert_eq(by_source.data_ref_count, 1)
  assert_eq(by_source.receipt_count, 1)
  assert_eq(by_source.stopped_capture_count, 1)
  assert_eq(by_source.total_data_byte_count, 23L)
  assert_eq(by_source.latest_capture_id, "capture-query")
  assert_eq(by_source.latest_capture_status, "stopped")
  assert_eq(by_source.latest_capture_started_at_ms, 63L)
  let by_robot = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(robot_id="robot-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by robot failed")
  }
  assert_eq(by_robot.captures[0].capture_id, "capture-query")
  let by_bridge = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(bridge_id="bridge-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by bridge failed")
  }
  assert_eq(by_bridge.capture_count, 1)
  let by_status = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(status="stopped"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by status failed")
  }
  assert_eq(by_status.capture_count, 1)
  assert_eq(by_status.stopped_capture_count, 1)
  let by_data_kind = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(data_kind="telemetry-frame"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "capture")
  assert_eq(by_data_kind.total_data_byte_count, 23L)
}

///|
test "episode query lists cataloged episodes by dataset robot bridge session task status and data kind" {
  let root = "target/moondata-api-episode-query-test"
  ignore(@moondata_store.initialize_root(root))
  let episode = @moondata_core.episode_manifest(
    "episode-query-inventory",
    "ds-episode-query",
    "robot-episode-query",
    "bridge-episode-query",
    "session-episode-query",
    "stopped",
    66L,
    stopped_at_ms=Some(67L),
    frame_count=1,
    frame_ids=["frame-episode-query"],
    receipt_ids=["receipt-episode-query"],
    task_id="task-episode-query",
    data_refs=[
      @moondata_core.data_ref(
        "episode-query-payload",
        "telemetry-frame",
        "sidecar://episode-query/frame.json",
        byte_count=29L,
      ),
    ],
  )
  let episode_persisted = match @moondata_store.write_episode(root, episode) {
    Ok(value) => value
    Err(_) => fail("write episode failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 68L, [
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=episode.status,
        ),
      ]),
    ),
  )
  let by_dataset = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(dataset_id="ds-episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by dataset failed")
  }
  assert_eq(by_dataset.episode_count, 1)
  assert_eq(by_dataset.declared_frame_count, 1)
  assert_eq(by_dataset.frame_ref_count, 1)
  assert_eq(by_dataset.data_ref_count, 1)
  assert_eq(by_dataset.receipt_count, 1)
  assert_eq(by_dataset.stopped_episode_count, 1)
  assert_eq(by_dataset.total_data_byte_count, 29L)
  assert_eq(by_dataset.latest_episode_id, "episode-query-inventory")
  assert_eq(by_dataset.latest_episode_status, "stopped")
  assert_eq(by_dataset.latest_episode_started_at_ms, 66L)
  let by_robot = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(robot_id="robot-episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by robot failed")
  }
  assert_eq(by_robot.episodes[0].episode_id, "episode-query-inventory")
  let by_bridge = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(bridge_id="bridge-episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by bridge failed")
  }
  assert_eq(by_bridge.episode_count, 1)
  let by_session = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(session_id="session-episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by session failed")
  }
  assert_eq(by_session.episode_count, 1)
  let by_task = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(task_id="task-episode-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by task failed")
  }
  assert_eq(by_task.episode_count, 1)
  let by_status = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(status="stopped"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by status failed")
  }
  assert_eq(by_status.episode_count, 1)
  assert_eq(by_status.stopped_episode_count, 1)
  let by_data_kind = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(data_kind="telemetry-frame"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "episode")
  assert_eq(by_data_kind.total_data_byte_count, 29L)
}

///|
test "frame query lists cataloged frames by episode robot bridge and data kind" {
  let root = "target/moondata-api-frame-query-test"
  ignore(@moondata_store.initialize_root(root))
  let frame = @moondata_core.frame_ref(
    "frame-query-inventory",
    "episode-frame-query",
    "robot-frame-query",
    "bridge-frame-query",
    7,
    70L,
    payload_ref=Some(
      @moondata_core.data_ref(
        "frame-query-payload",
        "telemetry-frame",
        "sidecar://frame-query/frame.json",
        byte_count=31L,
      ),
    ),
    signal_refs=[
      @moondata_core.data_ref(
        "frame-query-signal",
        "signal-chunk",
        "sidecar://frame-query/signal.bin",
        byte_count=37L,
      ),
    ],
  )
  let frame_persisted = match @moondata_store.write_frame(root, frame) {
    Ok(value) => value
    Err(_) => fail("write frame failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 71L, [
        @moondata_core.catalog_entry(
          frame_persisted.artifact_kind,
          frame_persisted.artifact_id,
          frame_persisted.path,
        ),
      ]),
    ),
  )
  let by_episode = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(episode_id="episode-frame-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by episode failed")
  }
  assert_eq(by_episode.frame_count, 1)
  assert_eq(by_episode.payload_ref_count, 1)
  assert_eq(by_episode.signal_ref_count, 1)
  assert_eq(by_episode.media_ref_count, 0)
  assert_eq(by_episode.data_ref_count, 2)
  assert_eq(by_episode.total_data_byte_count, 68L)
  assert_eq(by_episode.latest_frame_id, "frame-query-inventory")
  assert_eq(by_episode.latest_frame_captured_at_ms, 70L)
  let by_robot = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(robot_id="robot-frame-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by robot failed")
  }
  assert_eq(by_robot.frames[0].frame_id, "frame-query-inventory")
  let by_bridge = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(bridge_id="bridge-frame-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by bridge failed")
  }
  assert_eq(by_bridge.frame_count, 1)
  let by_payload = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(data_kind="telemetry-frame"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by payload kind failed")
  }
  assert_eq(by_payload.frame_count, 1)
  assert_eq(by_payload.payload_ref_count, 1)
  assert_eq(by_payload.total_data_byte_count, 68L)
  let by_signal = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(data_kind="signal-chunk"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by signal kind failed")
  }
  assert_eq(by_signal.refs[0].artifact_kind, "frame")
  assert_eq(by_signal.signal_ref_count, 1)
}

///|
test "lineage graph reads cataloged lineage nodes and filters by node" {
  let root = "target/moondata-api-lineage-graph-test"
  ignore(@moondata_store.initialize_root(root))
  let lineage = @moondata_core.lineage_manifest(
    "lineage-api",
    "ds-lineage-root",
    64L,
    edges=[
      @moondata_core.lineage_edge(
        "ds-lineage-root", "ds-lineage-curated", "curated-from",
      ),
      @moondata_core.lineage_edge(
        "transform-lineage", "ds-lineage-curated", "produced",
      ),
      @moondata_core.lineage_edge(
        "qr-lineage", "version-lineage", "quality-gate",
      ),
    ],
  )
  let lineage_persisted = match
    @moondata_store.write_lineage_manifest(root, lineage) {
    Ok(value) => value
    Err(_) => fail("write lineage failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 65L, [
        @moondata_core.catalog_entry(
          "dataset",
          "ds-lineage-root",
          "datasets/canonical/ds-lineage-root.json",
          status="active",
          summary="root lineage dataset",
        ),
        @moondata_core.catalog_entry(
          "dataset",
          "ds-lineage-curated",
          "datasets/curated/ds-lineage-curated.json",
          status="active",
          summary="curated lineage dataset",
        ),
        @moondata_core.catalog_entry(
          "transform-run",
          "transform-lineage",
          "transforms/transform-lineage.json",
          status="completed",
          summary="lineage transform",
        ),
        @moondata_core.catalog_entry(
          "quality-run",
          "qr-lineage",
          "quality/qr-lineage.json",
          status="passed",
          summary="lineage quality gate",
        ),
        @moondata_core.catalog_entry(
          "dataset-version",
          "version-lineage",
          "versions/version-lineage.json",
          status="accepted",
          summary="lineage accepted version",
        ),
        @moondata_core.catalog_entry(
          lineage_persisted.artifact_kind,
          lineage_persisted.artifact_id,
          lineage_persisted.path,
          summary="lineage graph",
        ),
      ]),
    ),
  )
  let graph = match
    @moondata_api.read_lineage_graph(
      root,
      query=@moondata_api.lineage_query(node_id="ds-lineage-curated"),
    ) {
    Ok(value) => value
    Err(_) => fail("read lineage graph failed")
  }
  assert_eq(graph.lineage_count, 1)
  assert_eq(graph.edge_count, 3)
  assert_true(graph.node_count >= 6)
  assert_eq(graph.nodes[1].artifact_kind, "lineage")
  assert_eq(graph.refs[0].artifact_kind, "dataset")
  let by_root = match
    @moondata_api.read_lineage_graph(
      root,
      query=@moondata_api.lineage_query(root_dataset_id="ds-lineage-root"),
    ) {
    Ok(value) => value
    Err(_) => fail("read lineage graph by root failed")
  }
  assert_eq(by_root.lineages[0].lineage_id, "lineage-api")
}

///|
test "signal query lists cataloged series by dataset episode field and storage" {
  let root = "target/moondata-api-signal-query-test"
  ignore(@moondata_store.initialize_root(root))
  let storage = @moondata_core.data_ref(
    "signal-query-ref",
    "raw-file",
    "moondata://media/imports/ds-signal-query/0-signal.csv",
    byte_count=41L,
    checksum="text-sum-v1:41:410",
  )
  let signal = @moondata_core.signal_series(
    "signal-query", "ds-signal-query", "ep-signal-query", "joint.position", "rad",
    7, "unix-ms", storage,
  )
  let signal_persisted = match
    @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 66L, [
        @moondata_core.catalog_entry(
          signal_persisted.artifact_kind,
          signal_persisted.artifact_id,
          signal_persisted.path,
          summary="joint position signal",
        ),
      ]),
    ),
  )
  let by_dataset = match
    @moondata_api.list_signals(
      root,
      query=@moondata_api.signal_query(dataset_id="ds-signal-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list signal by dataset failed")
  }
  assert_eq(by_dataset.signal_count, 1)
  assert_eq(by_dataset.sample_count, 7)
  assert_eq(by_dataset.storage_ref_count, 1)
  assert_eq(by_dataset.total_storage_byte_count, 41L)
  assert_eq(by_dataset.storage_checksums[0], "text-sum-v1:41:410")
  let by_episode = match
    @moondata_api.list_signals(
      root,
      query=@moondata_api.signal_query(episode_id="ep-signal-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list signal by episode failed")
  }
  assert_eq(by_episode.signals[0].series_id, "signal-query")
  let by_field = match
    @moondata_api.list_signals(
      root,
      query=@moondata_api.signal_query(field_path_contains="position"),
    ) {
    Ok(value) => value
    Err(_) => fail("list signal by field failed")
  }
  assert_eq(by_field.signal_count, 1)
  assert_eq(by_field.sample_count, 7)
  let by_storage = match
    @moondata_api.list_signals(
      root,
      query=@moondata_api.signal_query(storage_kind="raw-file"),
    ) {
    Ok(value) => value
    Err(_) => fail("list signal by storage failed")
  }
  assert_eq(by_storage.refs[0].artifact_kind, "signal-series")
  assert_eq(by_storage.total_storage_byte_count, 41L)
}

///|
test "handoff composes status context artifacts and lineage" {
  let root = "target/moondata-api-handoff-test"
  ignore(@moondata_store.initialize_root(root))
  let lineage = @moondata_core.lineage_manifest(
    "lineage-handoff",
    "ds-handoff",
    66L,
    edges=[
      @moondata_core.lineage_edge(
        "ds-handoff", "ds-handoff-curated", "curated-from",
      ),
    ],
  )
  let lineage_persisted = match
    @moondata_store.write_lineage_manifest(root, lineage) {
    Ok(value) => value
    Err(_) => fail("write handoff lineage failed")
  }
  let handoff_output = @moondata_core.data_ref(
    "output-handoff",
    "export-jsonl",
    "moondata://exports/export-handoff.jsonl",
    content_type="application/jsonl",
    byte_count=31L,
    checksum="text-sum-v1:31:3131",
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-handoff",
    "version-handoff",
    "ds-handoff-curated",
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [handoff_output],
    66L,
    quality_run_ids=["qr-handoff"],
    status="ready",
    report="handoff export",
  )
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write handoff export failed")
  }
  let validation = @moondata_core.validation_report(
    "validation-handoff",
    root,
    67L,
    "passed",
    5,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write handoff validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 67L, [
        @moondata_core.catalog_entry(
          "dataset",
          "ds-handoff",
          "datasets/canonical/ds-handoff.json",
          status="active",
          summary="handoff source dataset",
        ),
        @moondata_core.catalog_entry(
          "dataset",
          "ds-handoff-curated",
          "datasets/curated/ds-handoff-curated.json",
          status="active",
          summary="handoff curated dataset",
        ),
        @moondata_core.catalog_entry(
          lineage_persisted.artifact_kind,
          lineage_persisted.artifact_id,
          lineage_persisted.path,
          summary="handoff lineage",
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=export_manifest.status,
          summary=export_manifest.report,
        ),
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status="passed",
          summary="handoff validation",
        ),
      ]),
    ),
  )
  let handoff = match @moondata_api.read_handoff(root) {
    Ok(value) => value
    Err(_) => fail("read handoff failed")
  }
  assert_true(handoff.ready)
  assert_eq(handoff.readiness_status, "ready")
  assert_eq(handoff.validation_report_id, "validation-handoff")
  assert_eq(handoff.validation_status, "passed")
  assert_eq(handoff.validation_generated_at_ms, 67L)
  assert_eq(handoff.validation_catalog_entry_count, 5)
  assert_true(handoff.validation_covers_catalog)
  assert_eq(handoff.validation_finding_count, 0)
  assert_eq(handoff.validation_blocker_count, 0)
  assert_eq(handoff.validation_warning_count, 0)
  assert_eq(handoff.repair_count, 0)
  assert_eq(handoff.repair_receipt_count, 0)
  assert_eq(handoff.repair_work_count, 0)
  assert_eq(handoff.repair_open_count, 0)
  assert_eq(handoff.repair_applied_count, 0)
  assert_eq(handoff.repair_applied_unvalidated_count, 0)
  assert_eq(handoff.repair_failed_count, 0)
  assert_eq(handoff.repair_pending_count, 0)
  assert_eq(handoff.validation_findings.length(), 0)
  assert_true(handoff.status.ready)
  assert_eq(handoff.context.status, "ready")
  assert_true(handoff.context.ready)
  assert_eq(handoff.context.validation_report_id, "validation-handoff")
  assert_eq(handoff.context.validation_status, "passed")
  assert_eq(handoff.context.validation_generated_at_ms, 67L)
  assert_eq(handoff.context.validation_catalog_entry_count, 5)
  assert_true(handoff.context.validation_covers_catalog)
  assert_eq(handoff.context.validation_finding_count, 0)
  assert_eq(handoff.output_ref_count, 1)
  assert_eq(handoff.total_output_byte_count, 31L)
  assert_eq(handoff.output_checksums[0], "text-sum-v1:31:3131")
  assert_eq(handoff.output_refs[0].ref_id, "output-handoff")
  assert_eq(handoff.artifacts.artifact_count, 5)
  assert_eq(handoff.lineage.edge_count, 1)
  assert_true(handoff.slice is None)
  assert_true(handoff.refs.length() >= 5)
  assert_true(handoff.summary.contains("MoonData handoff ready"))
  assert_true(handoff.summary.contains("repair work 0 action"))
  assert_true(handoff.summary.contains("1 output ref"))
}

///|
test "handoff exposes stale validation as top-level readiness state" {
  let root = "target/moondata-api-stale-handoff-test"
  ignore(@moondata_store.initialize_root(root))
  let validation = @moondata_core.validation_report(
    "validation-handoff-stale",
    root,
    67L,
    "passed",
    2,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write stale handoff validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 68L, [
        @moondata_core.catalog_entry(
          "dataset",
          "ds-handoff-stale",
          "datasets/canonical/ds-handoff-stale.json",
          status="active",
          summary="stale handoff dataset",
        ),
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status="passed",
          summary="stale handoff validation",
        ),
      ]),
    ),
  )
  let handoff = match @moondata_api.read_handoff(root) {
    Ok(value) => value
    Err(_) => fail("read stale handoff failed")
  }
  assert_false(handoff.ready)
  assert_eq(handoff.readiness_status, "stale")
  assert_eq(handoff.validation_report_id, "validation-handoff-stale")
  assert_eq(handoff.validation_status, "stale")
  assert_eq(handoff.validation_generated_at_ms, 67L)
  assert_eq(handoff.validation_catalog_entry_count, 2)
  assert_false(handoff.validation_covers_catalog)
  assert_eq(handoff.validation_finding_count, 0)
  assert_eq(handoff.validation_blocker_count, 0)
  assert_eq(handoff.validation_warning_count, 0)
  assert_eq(handoff.context.status, "stale")
  assert_true(handoff.summary.contains("MoonData handoff stale"))
}

///|
test "handoff dossier listings filter stored dossier manifests" {
  let root = "target/moondata-api-handoff-dossiers-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset_ref = @moondata_core.moondata_ref(
    "dataset",
    "ds-handoff-list",
    @moondata_store.dataset_kind_path(root, "curated", "ds-handoff-list"),
    "handoff list dataset",
  )
  let export_ref = @moondata_core.moondata_ref(
    "export-manifest",
    "export-handoff-list",
    @moondata_store.export_manifest_path(root, "export-handoff-list"),
    "handoff list export",
  )
  let output_ref = @moondata_core.data_ref(
    "handoff-list-output",
    "export-output",
    "moondata://exports/handoff-list.jsonl",
    content_type="application/jsonl",
    byte_count=31L,
    checksum="checksum-handoff-list",
  )
  let ready = @moondata_core.handoff_dossier(
    "handoff-list-ready",
    "version-handoff-list",
    true,
    "ready",
    "validation-handoff-list",
    "passed",
    80L,
    7,
    true,
    0,
    0,
    0,
    0,
    0,
    2,
    1,
    0,
    1,
    0,
    0,
    [output_ref],
    [dataset_ref, export_ref],
    [],
    81L,
    "ready handoff dossier",
  )
  let stale = @moondata_core.handoff_dossier(
    "handoff-list-stale",
    "version-handoff-list-stale",
    false,
    "stale",
    "validation-handoff-list-stale",
    "stale",
    82L,
    3,
    false,
    1,
    1,
    0,
    1,
    1,
    3,
    2,
    0,
    1,
    0,
    0,
    [],
    [dataset_ref],
    [
      @moondata_core.validation_finding(
        "handoff-stale", "blocker", "handoff-dossier", "handoff-list-stale", "stale handoff dossier",
      ),
    ],
    83L,
    "stale handoff dossier",
  )
  let ready_persisted = match
    @moondata_store.write_handoff_dossier(root, ready) {
    Ok(value) => value
    Err(_) => fail("write ready handoff dossier failed")
  }
  let stale_persisted = match
    @moondata_store.write_handoff_dossier(root, stale) {
    Ok(value) => value
    Err(_) => fail("write stale handoff dossier failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 84L, [
        @moondata_core.catalog_entry(
          ready_persisted.artifact_kind,
          ready_persisted.artifact_id,
          ready_persisted.path,
          status=ready.source_readiness_status,
          summary=ready.summary,
        ),
        @moondata_core.catalog_entry(
          stale_persisted.artifact_kind,
          stale_persisted.artifact_id,
          stale_persisted.path,
          status=stale.source_readiness_status,
          summary=stale.summary,
        ),
      ]),
    ),
  )
  let all = match @moondata_api.list_handoff_dossiers(root) {
    Ok(value) => value
    Err(_) => fail("list handoff dossiers failed")
  }
  assert_eq(all.handoff_count, 2)
  assert_eq(all.ready_count, 1)
  assert_eq(all.ref_count, 3)
  assert_eq(all.repair_work_count, 5)
  assert_eq(all.repair_open_count, 3)
  assert_eq(all.repair_applied_count, 0)
  assert_eq(all.repair_applied_unvalidated_count, 2)
  assert_eq(all.repair_failed_count, 0)
  assert_eq(all.repair_pending_count, 0)
  assert_eq(all.output_ref_count, 1)
  assert_eq(all.total_output_byte_count, 31L)
  assert_eq(all.output_checksums[0], "checksum-handoff-list")
  assert_eq(all.output_refs[0].ref_id, "handoff-list-output")
  assert_eq(all.latest_handoff_dossier_id, "handoff-list-stale")
  assert_eq(all.refs.length(), 2)
  assert_true(all.summary.contains("repair work 5 action"))
  assert_true(all.summary.contains("3 open"))
  let by_status = match
    @moondata_api.list_handoff_dossiers(
      root,
      query=@moondata_api.handoff_dossier_query(readiness_status="ready"),
    ) {
    Ok(value) => value
    Err(_) => fail("list handoff dossiers by status failed")
  }
  assert_eq(by_status.handoff_count, 1)
  assert_eq(by_status.handoffs[0].handoff_dossier_id, "handoff-list-ready")
  let by_version = match
    @moondata_api.list_handoff_dossiers(
      root,
      query=@moondata_api.handoff_dossier_query(
        version_id="version-handoff-list-stale",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list handoff dossiers by version failed")
  }
  assert_eq(by_version.handoff_count, 1)
  assert_eq(by_version.handoffs[0].source_readiness_status, "stale")
  let by_validation = match
    @moondata_api.list_handoff_dossiers(
      root,
      query=@moondata_api.handoff_dossier_query(
        validation_report_id="validation-handoff-list",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list handoff dossiers by validation failed")
  }
  assert_eq(by_validation.handoff_count, 1)
  assert_true(by_validation.handoffs[0].source_ready)
  let by_ref = match
    @moondata_api.list_handoff_dossiers(
      root,
      query=@moondata_api.handoff_dossier_query(
        artifact_kind="export-manifest",
        artifact_id="export-handoff-list",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list handoff dossiers by ref failed")
  }
  assert_eq(by_ref.handoff_count, 1)
  assert_eq(by_ref.handoffs[0].handoff_dossier_id, "handoff-list-ready")
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
  let version_ref = @moondata_core.moondata_ref(
    "dataset-version",
    version.version_id,
    @moondata_store.dataset_version_path(root, version.version_id),
    version.summary,
  )
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    "ep-slice-1",
    @moondata_store.episode_path(root, "ep-slice-1"),
    "accepted slice episode",
  )
  let annotation = @moondata_core.annotation_set(
    "annotation-slice",
    [version_ref, episode_ref],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-api-test",
      ),
    ],
    "moondata-api-test",
    74L,
    status="accepted",
    summary="slice review annotation",
  )
  let annotation_target = @moondata_core.annotation_target_index(
    "annotation-target-slice",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["accepted"],
    summary="slice annotation target index",
  )
  let replay_payload = @moondata_core.data_ref(
    "replay-slice-payload",
    "replay-payload",
    "moondata://media/replays/replay-slice.json",
    content_type="application/json",
    byte_count=10L,
    checksum="text-sum-v1:10:456",
  )
  let replay = @moondata_core.replay_artifact(
    "replay-slice",
    version.dataset_id,
    version.accepted_episode_ids,
    75L,
    source_refs=[version_ref, episode_ref],
    generated_refs=[replay_payload],
    summary="slice replay artifact",
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
  let annotation_persisted = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  let annotation_target_persisted = match
    @moondata_store.write_annotation_target_index(root, annotation_target) {
    Ok(value) => value
    Err(_) => fail("write annotation target failed")
  }
  let replay_persisted = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(_) => fail("write replay failed")
  }
  let validation = @moondata_core.validation_report(
    "validation-slice",
    root,
    76L,
    "passed",
    8,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write validation failed")
  }
  let catalog_entries = [
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
    @moondata_core.catalog_entry(
      annotation_persisted.artifact_kind,
      annotation_persisted.artifact_id,
      annotation_persisted.path,
      status=annotation.status,
    ),
    @moondata_core.catalog_entry(
      annotation_target_persisted.artifact_kind,
      annotation_target_persisted.artifact_id,
      annotation_target_persisted.path,
      status=annotation_target.status,
    ),
    @moondata_core.catalog_entry(
      replay_persisted.artifact_kind,
      replay_persisted.artifact_id,
      replay_persisted.path,
      summary=replay.summary,
    ),
    @moondata_core.catalog_entry(
      validation_persisted.artifact_kind,
      validation_persisted.artifact_id,
      validation_persisted.path,
      status=validation.status,
      summary="slice validation",
    ),
  ]
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 76L, catalog_entries),
    ),
  )
  let slice = match @moondata_api.read_dataset_slice(root, version.version_id) {
    Ok(value) => value
    Err(_) => fail("read dataset slice failed")
  }
  assert_eq(slice.status, "ready")
  assert_true(slice.ready)
  assert_eq(slice.local_status, "ready")
  assert_eq(slice.validation_report_id, "validation-slice")
  assert_eq(slice.validation_status, "passed")
  assert_eq(slice.catalog_generated_at_ms, 76L)
  assert_eq(slice.accepted_episode_count, 1)
  assert_eq(slice.quality_gates[0].status, "passed")
  assert_eq(slice.exports[0].output_refs[0].checksum, "text-sum-v1:20:123")
  assert_eq(slice.output_ref_count, 1)
  assert_eq(slice.total_output_byte_count, 20L)
  assert_eq(slice.output_checksums[0], "text-sum-v1:20:123")
  assert_eq(slice.annotations[0].annotation_set_id, "annotation-slice")
  assert_eq(slice.annotations[0].labels[0].value, "accepted")
  assert_eq(slice.annotation_target_count, 1)
  assert_eq(
    slice.annotation_targets[0].annotation_index_id,
    "annotation-target-slice",
  )
  assert_eq(slice.annotation_targets[0].annotation_set_id, "annotation-slice")
  assert_eq(slice.replays[0].replay_artifact_id, "replay-slice")
  assert_eq(slice.replays[0].generated_refs[0].checksum, "text-sum-v1:10:456")
  assert_eq(slice.refs.length(), 7)
  assert_true(slice.summary.contains("1 output ref"))
  assert_true(slice.summary.contains("20 byte"))
  assert_true(slice.summary.contains("1 annotation target index"))
  let slice_handoff = match
    @moondata_api.read_handoff(root, version_id=version.version_id) {
    Ok(value) => value
    Err(_) => fail("read slice handoff failed")
  }
  assert_true(slice_handoff.ready)
  assert_true(slice_handoff.slice is Some(_))
  assert_eq(slice_handoff.output_ref_count, 1)
  assert_eq(slice_handoff.total_output_byte_count, 20L)
  assert_eq(slice_handoff.output_checksums[0], "text-sum-v1:20:123")
  assert_true(slice_handoff.refs.length() >= 8)
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 77L, catalog_entries),
    ),
  )
  let stale_slice = match
    @moondata_api.read_dataset_slice(root, version.version_id) {
    Ok(value) => value
    Err(_) => fail("read stale dataset slice failed")
  }
  assert_eq(stale_slice.local_status, "ready")
  assert_eq(stale_slice.status, "stale")
  assert_true(!stale_slice.ready)
  assert_eq(stale_slice.validation_status, "stale")
}

///|
test "dataset slice blocks ready handoff until replay is materialized" {
  let root = "target/moondata-api-slice-missing-replay-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-slice-no-replay",
    "curated",
    "accepted",
    78L,
    episode_ids=["ep-slice-no-replay"],
  )
  let version = @moondata_core.dataset_version(
    "version-slice-no-replay",
    dataset.dataset_id,
    "accepted",
    79L,
    accepted_episode_ids=dataset.episode_ids,
    quality_run_ids=["qr-slice-no-replay"],
    summary="accepted exported slice without replay",
  )
  let quality = @moondata_core.quality_run(
    "qr-slice-no-replay",
    dataset.dataset_id,
    dataset.episode_ids,
    80L,
    [],
  )
  let output = @moondata_core.data_ref(
    "export-slice-no-replay-output",
    "export-jsonl",
    "moondata://exports/export-slice-no-replay.jsonl",
    byte_count=21L,
    checksum="text-sum-v1:21:2121",
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-slice-no-replay",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    81L,
    quality_run_ids=version.quality_run_ids,
  )
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write no-replay dataset failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write no-replay version failed")
  }
  let quality_persisted = match
    @moondata_store.write_quality_run(root, quality) {
    Ok(value) => value
    Err(_) => fail("write no-replay quality failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write no-replay export failed")
  }
  let validation = @moondata_core.validation_report(
    "validation-slice-no-replay",
    root,
    82L,
    "passed",
    4,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write no-replay validation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 82L, [
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
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status=validation.status,
        ),
      ]),
    ),
  )
  let slice = match @moondata_api.read_dataset_slice(root, version.version_id) {
    Ok(value) => value
    Err(_) => fail("read no-replay slice failed")
  }
  assert_eq(slice.validation_status, "passed")
  assert_eq(slice.local_status, "pending-replay")
  assert_eq(slice.status, "pending-replay")
  assert_false(slice.ready)
  assert_eq(slice.replays.length(), 0)
  assert_true(slice.summary.contains("0 replay"))
  let handoff = match
    @moondata_api.read_handoff(root, version_id=version.version_id) {
    Ok(value) => value
    Err(_) => fail("read no-replay handoff failed")
  }
  assert_false(handoff.ready)
  assert_eq(handoff.readiness_status, "pending-replay")
  assert_true(handoff.summary.contains("pending-replay"))
}

///|
test "annotation query lists by frame reviewer label and task" {
  let root = "target/moondata-api-annotation-query-test"
  ignore(@moondata_store.initialize_root(root))
  let episode = @moondata_core.episode_manifest(
    "ep-query-1",
    "ds-query",
    "robot-query",
    "bridge-query",
    "session-query",
    "stopped",
    80L,
    stopped_at_ms=Some(81L),
    frame_count=1,
    frame_ids=["frame-query-1"],
    task_id="task-query-accept",
  )
  let frame = @moondata_core.frame_ref(
    "frame-query-1",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    80L,
  )
  let frame_ref = @moondata_core.moondata_ref(
    "frame",
    frame.frame_id,
    @moondata_store.frame_path(root, frame.frame_id),
    "query frame",
  )
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    episode.episode_id,
    @moondata_store.episode_path(root, episode.episode_id),
    "query episode evidence",
  )
  let annotation = @moondata_core.annotation_set(
    "annotation-query",
    [frame_ref],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-api-test",
      ),
    ],
    "reviewer-query",
    82L,
    status="accepted",
    evidence_refs=[episode_ref],
    summary="query annotation",
  )
  let episode_persisted = match @moondata_store.write_episode(root, episode) {
    Ok(value) => value
    Err(_) => fail("write episode failed")
  }
  let frame_persisted = match @moondata_store.write_frame(root, frame) {
    Ok(value) => value
    Err(_) => fail("write frame failed")
  }
  let annotation_persisted = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 83L, [
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=episode.status,
        ),
        @moondata_core.catalog_entry(
          frame_persisted.artifact_kind,
          frame_persisted.artifact_id,
          frame_persisted.path,
        ),
        @moondata_core.catalog_entry(
          annotation_persisted.artifact_kind,
          annotation_persisted.artifact_id,
          annotation_persisted.path,
          status=annotation.status,
        ),
      ]),
    ),
  )
  let by_frame = match
    @moondata_api.list_annotations(
      root,
      query=@moondata_api.annotation_query(
        artifact_kind="frame",
        artifact_id=frame.frame_id,
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list by frame failed")
  }
  assert_eq(by_frame.annotation_count, 1)
  assert_eq(by_frame.label_count, 1)
  assert_eq(by_frame.target_ref_count, 1)
  assert_eq(by_frame.evidence_ref_count, 1)
  assert_eq(by_frame.latest_annotation_set_id, "annotation-query")
  assert_eq(by_frame.latest_annotation_created_at_ms, 82L)
  assert_eq(by_frame.annotations[0].created_at_ms, 82L)
  let by_reviewer = match
    @moondata_api.list_annotations(
      root,
      query=@moondata_api.annotation_query(reviewer="reviewer-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by reviewer failed")
  }
  assert_eq(by_reviewer.annotations[0].annotation_set_id, "annotation-query")
  let by_label = match
    @moondata_api.list_annotations(
      root,
      query=@moondata_api.annotation_query(
        label_key="curation",
        label_value="accepted",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list by label failed")
  }
  assert_eq(by_label.annotation_count, 1)
  let by_task = match
    @moondata_api.list_annotations(
      root,
      query=@moondata_api.annotation_query(task_id="task-query-accept"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by task failed")
  }
  assert_eq(by_task.annotation_count, 1)
  assert_eq(by_task.refs[0].artifact_kind, "annotation-set")
}

///|
test "annotation target query lists cataloged target indexes" {
  let root = "target/moondata-api-annotation-target-query-test"
  ignore(@moondata_store.initialize_root(root))
  let frame_ref = @moondata_core.moondata_ref(
    "frame",
    "frame-target-query-1",
    @moondata_store.frame_path(root, "frame-target-query-1"),
    "target query frame",
  )
  let annotation = @moondata_core.annotation_set(
    "annotation-target-query",
    [frame_ref],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-api-test",
      ),
    ],
    "reviewer-target-query",
    84L,
    status="accepted",
    summary="target query annotation",
  )
  let index = @moondata_core.annotation_target_index(
    "annotation-target-index-query",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["accepted"],
    summary=annotation.summary,
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
      @moondata_core.moondata_catalog(root, 85L, [
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
  let by_frame = match
    @moondata_api.list_annotation_targets(
      root,
      query=@moondata_api.annotation_target_query(
        artifact_kind="frame",
        artifact_id="frame-target-query-1",
        reviewer="reviewer-target-query",
        status="accepted",
        label_key="curation",
        label_value="accepted",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list annotation targets failed")
  }
  assert_eq(by_frame.annotation_index_count, 1)
  assert_eq(by_frame.target_ref_count, 1)
  assert_eq(by_frame.label_key_count, 1)
  assert_eq(by_frame.label_value_count, 1)
  assert_eq(
    by_frame.latest_annotation_index_id,
    "annotation-target-index-query",
  )
  assert_eq(by_frame.latest_annotation_created_at_ms, 84L)
  assert_eq(by_frame.indexes[0].annotation_set_id, "annotation-target-query")
  assert_eq(by_frame.refs[0].artifact_kind, "annotation-target-index")
}

///|
test "replay query lists by dataset episode source and generated payload" {
  let root = "target/moondata-api-replay-query-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset_ref = @moondata_core.moondata_ref(
    "dataset",
    "ds-replay-query",
    @moondata_store.dataset_path(root, "ds-replay-query"),
    "replay query dataset",
  )
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    "ep-replay-query",
    @moondata_store.episode_path(root, "ep-replay-query"),
    "replay query episode",
  )
  let frame_ref = @moondata_core.moondata_ref(
    "frame",
    "frame-replay-query",
    @moondata_store.frame_path(root, "frame-replay-query"),
    "replay query frame",
  )
  let payload = @moondata_core.data_ref(
    "replay-query-payload",
    "replay-payload",
    "moondata://media/replays/replay-query.json",
    content_type="application/json",
    byte_count=44L,
    checksum="text-sum-v1:44:987",
  )
  let replay = @moondata_core.replay_artifact(
    "replay-query",
    "ds-replay-query",
    ["ep-replay-query"],
    90L,
    source_refs=[dataset_ref, episode_ref, frame_ref],
    generated_refs=[payload],
    viewer_profile="moondata.replay.v1",
    summary="query replay artifact",
  )
  let replay_persisted = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(_) => fail("write replay failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 91L, [
        @moondata_core.catalog_entry(
          replay_persisted.artifact_kind,
          replay_persisted.artifact_id,
          replay_persisted.path,
          summary=replay.summary,
        ),
      ]),
    ),
  )
  let by_dataset = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(dataset_id="ds-replay-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by dataset failed")
  }
  assert_eq(by_dataset.replay_count, 1)
  assert_eq(by_dataset.episode_count, 1)
  assert_eq(by_dataset.source_ref_count, 3)
  assert_eq(by_dataset.generated_ref_count, 1)
  assert_eq(by_dataset.total_generated_byte_count, 44L)
  assert_eq(by_dataset.generated_checksums[0], "text-sum-v1:44:987")
  assert_eq(by_dataset.latest_replay_artifact_id, "replay-query")
  assert_eq(by_dataset.latest_replay_created_at_ms, 90L)
  let by_episode = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(episode_id="ep-replay-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by episode failed")
  }
  assert_eq(by_episode.replays[0].replay_artifact_id, "replay-query")
  assert_eq(by_episode.replays[0].created_at_ms, 90L)
  let by_source = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(
        source_artifact_kind="frame",
        source_artifact_id="frame-replay-query",
      ),
    ) {
    Ok(value) => value
    Err(_) => fail("list by source failed")
  }
  assert_eq(by_source.replay_count, 1)
  let by_viewer = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(viewer_profile="moondata.replay.v1"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by viewer failed")
  }
  assert_eq(by_viewer.replay_count, 1)
  let by_generated = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(generated_kind="replay-payload"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by generated payload failed")
  }
  assert_eq(by_generated.refs[0].artifact_kind, "replay-artifact")
  assert_eq(by_generated.total_generated_byte_count, 44L)
}
