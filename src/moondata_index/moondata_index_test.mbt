///|
fn ensure_tmp(root : String) -> Unit {
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => ()
    }
  }
}

///|
fn catalog_has_entry(
  catalog : @moondata_core.MoonDataCatalog,
  artifact_kind : String,
  artifact_id : String,
) -> Bool {
  let mut found = false
  for entry in catalog.entries {
    if entry.artifact_kind == artifact_kind && entry.artifact_id == artifact_id {
      found = true
    }
  }
  found
}

///|
test "index rebuilds catalog from all persisted MoonData manifests" {
  let root = "target/moondata-index-complete-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let source_ref = @moondata_core.data_ref(
    "ref-source-index-1", "raw-file", "moondata://media/imports/source-index.csv",
  )
  let source = @moondata_core.data_source(
    "src-index-1",
    "import",
    "index source",
    "robot-index",
    "bridge-index",
    "file:///tmp/source-index.csv",
    1L,
    source_refs=[source_ref],
  )
  let capture = @moondata_core.capture_session(
    "cap-index-1",
    source.source_id,
    "robot-index",
    "bridge-index",
    "closed",
    2L,
    data_refs=[
      @moondata_core.data_ref(
        "ref-capture-index-1", "receipt-log", "moondata://media/imports/capture-index.log",
      ),
    ],
  )
  let raw_dataset = @moondata_core.dataset_manifest(
    "ds-index-raw-1",
    "raw",
    "imported",
    3L,
    source_ids=[source.source_id],
    capture_ids=[capture.capture_id],
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-index-1",
    "canonical",
    "active",
    10L,
    source_ids=[source.source_id],
    capture_ids=[capture.capture_id],
    episode_ids=["ep-index-1"],
  )
  let curated_dataset = @moondata_core.dataset_manifest(
    "ds-index-curated-1",
    "curated",
    "accepted",
    14L,
    source_ids=[source.source_id],
    capture_ids=[capture.capture_id],
    episode_ids=["ep-index-1"],
    lineage_id="lineage-index-1",
  )
  let episode = @moondata_core.episode_manifest(
    "ep-index-1",
    dataset.dataset_id,
    "robot-index",
    "bridge-index",
    "session-index",
    "accepted",
    11L,
    frame_count=1,
    frame_ids=["frame-index-1"],
    data_refs=[
      @moondata_core.data_ref(
        "ref-episode-index-1", "episode-json", "moondata://media/imports/episode-index.json",
      ),
    ],
  )
  let frame = @moondata_core.frame_ref(
    "frame-index-1",
    episode.episode_id,
    "robot-index",
    "bridge-index",
    0,
    11L,
    payload_ref=Some(
      @moondata_core.data_ref(
        "ref-frame-index-1", "frame-json", "moondata://media/imports/frame-index.json",
      ),
    ),
  )
  let signal = @moondata_core.signal_series(
    "signal-index-1",
    dataset.dataset_id,
    episode.episode_id,
    "joint.position",
    "rad",
    1,
    "unix-ms",
    @moondata_core.data_ref(
      "ref-signal-index-1", "signal-json", "moondata://media/imports/signal-index.json",
    ),
  )
  let robot_model = @moondata_core.robot_model_manifest(
    "robot-model-index-1",
    "robot-index",
    "urdf",
    "active",
    @moondata_core.data_ref(
      "ref-robot-model-index-urdf", "urdf", "moondata://media/robot_models/index/robot.urdf",
    ),
    11L,
    mesh_refs=[
      @moondata_core.data_ref(
        "ref-robot-model-index-mesh", "stl", "moondata://media/robot_models/index/meshes/base.stl",
      ),
    ],
    link_names=["base_link"],
    joint_names=["hip_yaw"],
    validation_status="passed",
    summary="indexed robot model",
  )
  let quality = @moondata_core.quality_run(
    "qr-index-1",
    dataset.dataset_id,
    [episode.episode_id],
    12L,
    [],
  )
  let version = @moondata_core.dataset_version(
    "version-index-1",
    dataset.dataset_id,
    "accepted",
    13L,
    accepted_episode_ids=[episode.episode_id],
    quality_run_ids=[quality.quality_run_id],
    summary="indexed version",
  )
  let lineage = @moondata_core.lineage_manifest(
    "lineage-index-1",
    raw_dataset.dataset_id,
    15L,
    edges=[
      @moondata_core.lineage_edge(
        raw_dataset.dataset_id,
        curated_dataset.dataset_id,
        "curated-to",
      ),
    ],
  )
  let transform = @moondata_core.transform_run(
    "transform-index-1",
    raw_dataset.dataset_id,
    curated_dataset.dataset_id,
    16L,
    [
      @moondata_core.transform_step(
        "step-index-1",
        "dedupe",
        "{\"policy\":\"stable\"}",
        summary="stable dedupe",
      ),
    ],
    quality_run_ids=[quality.quality_run_id],
    lineage_id=lineage.lineage_id,
    summary="indexed transform",
  )
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    episode.episode_id,
    @moondata_store.episode_path(root, episode.episode_id),
    "indexed episode",
  )
  let annotation = @moondata_core.annotation_set(
    "annotation-index-1",
    [episode_ref],
    [
      @moondata_core.annotation_label(
        "status",
        "accepted",
        source="moondata-index-test",
      ),
    ],
    "reviewer-index",
    17L,
    status="accepted",
    summary="indexed annotation",
  )
  let annotation_target_index = @moondata_core.annotation_target_index(
    "annotation-target-index-1",
    annotation.annotation_set_id,
    [episode_ref],
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["status"],
    label_values=["accepted"],
    summary="indexed annotation targets",
  )
  let replay = @moondata_core.replay_artifact(
    "replay-index-1",
    dataset.dataset_id,
    [episode.episode_id],
    18L,
    source_refs=[episode_ref],
    generated_refs=[
      @moondata_core.data_ref(
        "ref-replay-index-1", "replay-json", "moondata://replays/replay-index-1.json",
      ),
    ],
    summary="indexed replay",
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-index-1",
    version.version_id,
    dataset.dataset_id,
    "jsonl",
    "identity",
    [
      @moondata_core.data_ref(
        "ref-export-index-1", "jsonl", "moondata://exports/export-index-1.jsonl",
      ),
    ],
    19L,
    quality_run_ids=[quality.quality_run_id],
    report="indexed export",
  )
  let validation = @moondata_core.validation_report(
    "validation-index-1",
    root,
    21L,
    "passed",
    15,
    0,
    0,
    0,
    [],
  )
  ignore(@moondata_store.write_source(root, source))
  ignore(@moondata_store.write_capture(root, capture))
  ignore(@moondata_store.write_dataset(root, raw_dataset))
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_dataset(root, curated_dataset))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
  ignore(@moondata_store.write_signal_series(root, signal))
  ignore(@moondata_store.write_robot_model(root, robot_model))
  ignore(@moondata_store.write_quality_run(root, quality))
  ignore(@moondata_store.write_lineage_manifest(root, lineage))
  ignore(@moondata_store.write_transform_run(root, transform))
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_annotation_set(root, annotation))
  ignore(
    @moondata_store.write_annotation_target_index(root, annotation_target_index),
  )
  ignore(@moondata_store.write_replay_artifact(root, replay))
  ignore(@moondata_store.write_export_manifest(root, export_manifest))
  ignore(@moondata_store.write_validation_report(root, validation))
  let rebuilt = match @moondata_index.rebuild_catalog(root, 20L) {
    Ok(value) => value
    Err(error) => fail("rebuild failed: " + error.message)
  }
  assert_eq(rebuilt.entry_count, 18)
  assert_true(catalog_has_entry(rebuilt.catalog, "source", source.source_id))
  assert_true(catalog_has_entry(rebuilt.catalog, "capture", capture.capture_id))
  assert_true(
    catalog_has_entry(rebuilt.catalog, "dataset", raw_dataset.dataset_id),
  )
  assert_true(catalog_has_entry(rebuilt.catalog, "dataset", dataset.dataset_id))
  assert_true(
    catalog_has_entry(rebuilt.catalog, "dataset", curated_dataset.dataset_id),
  )
  assert_true(catalog_has_entry(rebuilt.catalog, "episode", episode.episode_id))
  assert_true(catalog_has_entry(rebuilt.catalog, "frame", frame.frame_id))
  assert_true(
    catalog_has_entry(rebuilt.catalog, "signal-series", signal.series_id),
  )
  assert_true(
    catalog_has_entry(rebuilt.catalog, "robot-model", robot_model.model_id),
  )
  assert_true(
    catalog_has_entry(rebuilt.catalog, "quality-run", quality.quality_run_id),
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "transform-run",
      transform.transform_run_id,
    ),
  )
  assert_true(
    catalog_has_entry(rebuilt.catalog, "dataset-version", version.version_id),
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "annotation-set",
      annotation.annotation_set_id,
    ),
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "annotation-target-index",
      annotation_target_index.annotation_index_id,
    ),
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "replay-artifact",
      replay.replay_artifact_id,
    ),
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "export-manifest",
      export_manifest.export_manifest_id,
    ),
  )
  assert_true(catalog_has_entry(rebuilt.catalog, "lineage", lineage.lineage_id))
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "validation-report",
      validation.validation_report_id,
    ),
  )
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read rebuilt catalog failed")
  }
  assert_eq(catalog.entry_count, 18)
}

///|
test "index rebuilds validation report entries" {
  let root = "target/moondata-index-validation-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let report = @moondata_core.validation_report(
    "validation-index-1",
    root,
    21L,
    "passed",
    0,
    0,
    0,
    0,
    [],
  )
  ignore(@moondata_store.write_validation_report(root, report))
  let rebuilt = match @moondata_index.rebuild_catalog(root, 22L) {
    Ok(value) => value
    Err(error) => fail("rebuild failed: " + error.message)
  }
  assert_eq(rebuilt.entry_count, 1)
  assert_eq(rebuilt.catalog.entries[0].artifact_kind, "validation-report")
  assert_eq(rebuilt.catalog.entries[0].artifact_id, report.validation_report_id)
}

///|
test "index rebuilds repair receipt entries" {
  let root = "target/moondata-index-repair-receipt-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let receipt = @moondata_core.repair_receipt(
    "repair-receipt-index",
    "repair-index",
    "repair-action-index",
    "restore-or-remove-payload-ref",
    "dataset:dataset-index",
    "applied",
    "operator",
    23L,
    "validation-index-repair",
    summary="indexed repair receipt",
  )
  ignore(@moondata_store.write_repair_receipt(root, receipt))
  let rebuilt = match @moondata_index.rebuild_catalog(root, 24L) {
    Ok(value) => value
    Err(error) => fail("rebuild failed: " + error.message)
  }
  assert_eq(rebuilt.entry_count, 1)
  assert_eq(rebuilt.catalog.entries[0].artifact_kind, "repair-receipt")
  assert_eq(rebuilt.catalog.entries[0].artifact_id, receipt.repair_receipt_id)
  assert_eq(rebuilt.catalog.entries[0].status, "applied")
}

///|
test "index rebuilds annotation target indexes from annotation manifests" {
  let root = "target/moondata-index-annotation-target-rebuild-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let target = @moondata_core.moondata_ref(
    "frame",
    "frame-annotation-rebuild",
    @moondata_store.frame_path(root, "frame-annotation-rebuild"),
    "annotation rebuild target",
  )
  let annotation = @moondata_core.annotation_set(
    "annotation-rebuild-index",
    [target],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-index-test",
      ),
    ],
    "reviewer-index",
    31L,
    status="accepted",
    summary="annotation index rebuild",
  )
  let stale = @moondata_core.annotation_target_index(
    "stale-annotation-target-index",
    annotation.annotation_set_id,
    [],
    "stale-reviewer",
    "draft",
    1L,
    label_keys=["stale"],
    label_values=["stale"],
  )
  ignore(@moondata_store.write_annotation_set(root, annotation))
  ignore(@moondata_store.write_annotation_target_index(root, stale))
  let rebuilt = match
    @moondata_index.rebuild_annotation_target_indexes(root, 32L) {
    Ok(value) => value
    Err(error) => fail("annotation target rebuild failed: " + error.message)
  }
  assert_eq(rebuilt.annotation_count, 1)
  assert_eq(rebuilt.annotation_index_count, 1)
  assert_eq(
    rebuilt.indexes[0].artifact_id,
    "annotation-target-annotation-rebuild-index",
  )
  assert_true(
    catalog_has_entry(
      rebuilt.catalog,
      "annotation-target-index",
      "annotation-target-annotation-rebuild-index",
    ),
  )
  assert_false(
    catalog_has_entry(
      rebuilt.catalog,
      "annotation-target-index",
      "stale-annotation-target-index",
    ),
  )
  match
    @moondata_store.read_annotation_target_index(
      root, "stale-annotation-target-index",
    ) {
    Ok(_) => fail("stale annotation target index should be removed")
    Err(_) => ()
  }
  let index = match
    @moondata_store.read_annotation_target_index(
      root, "annotation-target-annotation-rebuild-index",
    ) {
    Ok(value) => value
    Err(_) => fail("read rebuilt annotation target index failed")
  }
  assert_eq(index.annotation_set_id, annotation.annotation_set_id)
  assert_eq(index.target_refs[0].artifact_id, target.artifact_id)
  assert_eq(index.label_keys[0], "curation")
  assert_eq(index.label_values[0], "accepted")
  assert_eq(rebuilt.catalog_entry_count, 2)
}

///|
test "index returns decode errors for malformed manifests" {
  let root = "target/moondata-index-bad-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  @fsx.write_string_to_file(
    root + "/datasets/canonical/not-a-dataset.json",
    "{\"dataset_id\":1}",
  ) catch {
    _ => fail("failed to write malformed manifest")
  }
  match @moondata_index.rebuild_catalog(root, 30L) {
    Ok(_) => fail("expected rebuild to reject malformed manifest")
    Err(error) => assert_eq(error.code, "decode-dataset")
  }
}
