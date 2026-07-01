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
  assert_eq(context.status, "stale")
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
        "dataset-query-payload", "raw-file", "moondata://media/imports/ds-query-raw/payload.json",
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
  let by_data_kind = match
    @moondata_api.list_datasets(
      root,
      query=@moondata_api.dataset_query(data_kind="raw-file"),
    ) {
    Ok(value) => value
    Err(_) => fail("list dataset by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "dataset")
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
        "source-query-ref", "raw-file", "moondata://media/imports/source-query.csv",
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
}

///|
test "data ref query projects embedded payload refs across cataloged manifests" {
  let root = "target/moondata-api-data-ref-query-test"
  ignore(@moondata_store.initialize_root(root))
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
    "moondata://frames/data-ref-payload.json",
    content_type="application/json",
    byte_count=13L,
    checksum="text-sum-v1:13:103",
  )
  let frame_signal_ref = @moondata_core.data_ref(
    "data-ref-frame-signal",
    "signal-chunk",
    "moondata://signals/data-ref-frame.bin",
    byte_count=17L,
    checksum="text-sum-v1:17:104",
  )
  let frame_media_ref = @moondata_core.data_ref(
    "data-ref-frame-media",
    "image",
    "moondata://media/data-ref-frame.png",
    content_type="image/png",
    byte_count=19L,
    checksum="text-sum-v1:19:105",
  )
  let signal_storage_ref = @moondata_core.data_ref(
    "data-ref-signal-storage",
    "columnar",
    "moondata://signals/data-ref-series.parquet",
    content_type="application/parquet",
    byte_count=23L,
    checksum="text-sum-v1:23:106",
  )
  let replay_ref = @moondata_core.data_ref(
    "data-ref-replay",
    "replay-payload",
    "moondata://replays/data-ref.json",
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
      ]),
    ),
  )
  let all = match @moondata_api.list_data_refs(root) {
    Ok(value) => value
    Err(_) => fail("list data refs failed")
  }
  assert_eq(all.data_ref_count, 8)
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
  assert_eq(by_payload.data_refs[0].data_ref.ref_id, "data-ref-payload")
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
  let by_severity = match
    @moondata_api.list_quality_runs(
      root,
      query=@moondata_api.quality_query(severity="warning"),
    ) {
    Ok(value) => value
    Err(_) => fail("list quality by severity failed")
  }
  assert_eq(by_severity.quality_count, 1)
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
  let by_quality = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(quality_run_id="qr-version-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by quality failed")
  }
  assert_eq(by_quality.version_count, 1)
  let by_summary = match
    @moondata_api.list_versions(
      root,
      query=@moondata_api.version_query(summary_contains="training"),
    ) {
    Ok(value) => value
    Err(_) => fail("list version by summary failed")
  }
  assert_eq(by_summary.refs[0].artifact_kind, "dataset-version")
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
  let by_step = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(step_kind="normalize"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by step failed")
  }
  assert_eq(by_step.transform_count, 1)
  let by_summary = match
    @moondata_api.list_transforms(
      root,
      query=@moondata_api.transform_query(summary_contains="query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list transform by summary failed")
  }
  assert_eq(by_summary.refs[0].artifact_kind, "transform-run")
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
    74L,
    "blocked",
    2,
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
  let by_rule = match
    @moondata_api.list_validations(
      root,
      query=@moondata_api.validation_query(rule_id="manifest-missing"),
    ) {
    Ok(value) => value
    Err(_) => fail("list validation by rule failed")
  }
  assert_eq(by_rule.validation_count, 1)
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
    data_refs=[
      @moondata_core.data_ref(
        "capture-query-payload", "telemetry-frame", "sidecar://robot-query/frame.json",
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
  let by_data_kind = match
    @moondata_api.list_captures(
      root,
      query=@moondata_api.capture_query(data_kind="telemetry-frame"),
    ) {
    Ok(value) => value
    Err(_) => fail("list capture by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "capture")
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
    task_id="task-episode-query",
    data_refs=[
      @moondata_core.data_ref(
        "episode-query-payload", "telemetry-frame", "sidecar://episode-query/frame.json",
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
  let by_data_kind = match
    @moondata_api.list_episodes(
      root,
      query=@moondata_api.episode_query(data_kind="telemetry-frame"),
    ) {
    Ok(value) => value
    Err(_) => fail("list episode by data kind failed")
  }
  assert_eq(by_data_kind.refs[0].artifact_kind, "episode")
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
        "frame-query-payload", "telemetry-frame", "sidecar://frame-query/frame.json",
      ),
    ),
    signal_refs=[
      @moondata_core.data_ref(
        "frame-query-signal", "signal-chunk", "sidecar://frame-query/signal.bin",
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
  let by_signal = match
    @moondata_api.list_frames(
      root,
      query=@moondata_api.frame_query(data_kind="signal-chunk"),
    ) {
    Ok(value) => value
    Err(_) => fail("list frame by signal kind failed")
  }
  assert_eq(by_signal.refs[0].artifact_kind, "frame")
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
    "signal-query-ref", "raw-file", "moondata://media/imports/ds-signal-query/0-signal.csv",
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
  let by_storage = match
    @moondata_api.list_signals(
      root,
      query=@moondata_api.signal_query(storage_kind="raw-file"),
    ) {
    Ok(value) => value
    Err(_) => fail("list signal by storage failed")
  }
  assert_eq(by_storage.refs[0].artifact_kind, "signal-series")
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
  let validation = @moondata_core.validation_report(
    "validation-handoff",
    root,
    67L,
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
  assert_true(handoff.status.ready)
  assert_eq(handoff.context.status, "ready")
  assert_eq(handoff.artifacts.artifact_count, 4)
  assert_eq(handoff.lineage.edge_count, 1)
  assert_true(handoff.slice is None)
  assert_true(handoff.refs.length() >= 4)
  assert_true(handoff.summary.contains("MoonData handoff"))
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
  let replay_persisted = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(_) => fail("write replay failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 76L, [
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
          replay_persisted.artifact_kind,
          replay_persisted.artifact_id,
          replay_persisted.path,
          summary=replay.summary,
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
  assert_eq(slice.annotations[0].annotation_set_id, "annotation-slice")
  assert_eq(slice.annotations[0].labels[0].value, "accepted")
  assert_eq(slice.replays[0].replay_artifact_id, "replay-slice")
  assert_eq(slice.replays[0].generated_refs[0].checksum, "text-sum-v1:10:456")
  assert_eq(slice.refs.length(), 6)
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
  let by_episode = match
    @moondata_api.list_replays(
      root,
      query=@moondata_api.replay_query(episode_id="ep-replay-query"),
    ) {
    Ok(value) => value
    Err(_) => fail("list by episode failed")
  }
  assert_eq(by_episode.replays[0].replay_artifact_id, "replay-query")
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
}
