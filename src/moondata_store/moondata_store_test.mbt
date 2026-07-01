///|
fn ensure_tmp(root : String) -> Unit {
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => ()
    }
  }
}

///|
test "store initializes standalone moondata layout and writes dataset" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  let init = match @moondata_store.initialize_root(root) {
    Ok(value) => value
    Err(_) => fail("init failed")
  }
  assert_eq(init.root, root)
  assert_true(@fsx.path_exists(root + "/datasets/canonical"))
  assert_true(@fsx.path_exists(root + "/robot_models"))
  assert_true(@fsx.path_exists(root + "/media/robot_models"))
  assert_true(@fsx.path_exists(root + "/repairs"))
  let dataset = @moondata_core.dataset_manifest(
    "ds-store-1", "canonical", "active", 1L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write failed")
  }
  assert_eq(persisted.path, root + "/datasets/canonical/ds-store-1.json")
  let loaded = match @moondata_store.read_dataset(root, "ds-store-1") {
    Ok(value) => value
    Err(_) => fail("read failed")
  }
  assert_eq(loaded.dataset_id, "ds-store-1")
}

///|
test "store writes and reads robot model manifests" {
  let root = "target/moondata-store-robot-model-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-store-urdf",
    "urdf",
    "moondata://media/robot_models/store/robot.urdf",
    content_type="application/xml",
  )
  let mesh_ref = @moondata_core.data_ref(
    "robot-model-store-mesh", "stl", "moondata://media/robot_models/store/meshes/base.stl",
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-store",
    "robot-store",
    "urdf",
    "active",
    urdf_ref,
    8L,
    mesh_refs=[mesh_ref],
    link_names=["base_link"],
    joint_names=["hip_yaw"],
    validation_status="passed",
    summary="stored robot model",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write robot model failed")
  }
  assert_eq(persisted.path, root + "/robot_models/robot-model-store.json")
  let loaded = match
    @moondata_store.read_robot_model(root, "robot-model-store") {
    Ok(value) => value
    Err(_) => fail("read robot model failed")
  }
  assert_eq(loaded.robot_id, "robot-store")
  assert_eq(loaded.urdf_ref.kind, "urdf")
  assert_eq(loaded.mesh_refs[0].ref_id, "robot-model-store-mesh")
}

///|
test "store writes and reads data sources" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let source = @moondata_core.data_source(
    "source-store-1",
    "local-files",
    "store source",
    "robot-store",
    "bridge-store",
    "file:///tmp/source-store",
    2L,
    source_refs=[
      @moondata_core.data_ref(
        "source-store-ref", "raw-file", "moondata://media/imports/source-store.csv",
      ),
    ],
  )
  let persisted = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write source failed")
  }
  assert_eq(persisted.path, root + "/sources/source-store-1.json")
  let loaded = match @moondata_store.read_source(root, "source-store-1") {
    Ok(value) => value
    Err(_) => fail("read source failed")
  }
  assert_eq(loaded.kind, "local-files")
  assert_eq(loaded.source_refs[0].kind, "raw-file")
}

///|
test "store writes curated version and export manifests" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-curated-1",
    "curated",
    "active",
    2L,
    episode_ids=["ep-1"],
  )
  let version = @moondata_core.dataset_version(
    "version-store-1",
    dataset.dataset_id,
    "accepted",
    3L,
    accepted_episode_ids=dataset.episode_ids,
  )
  let output = @moondata_core.data_ref(
    "export-store-1-ref", "jsonl", "moondata://exports/export-store-1.jsonl",
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-store-1",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{}",
    [output],
    4L,
  )
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write curated dataset failed")
  }
  assert_eq(
    dataset_persisted.path,
    root + "/datasets/curated/ds-curated-1.json",
  )
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_export_manifest(root, export_manifest))
  let loaded_version = match
    @moondata_store.read_dataset_version(root, "version-store-1") {
    Ok(value) => value
    Err(_) => fail("read version failed")
  }
  let loaded_export = match
    @moondata_store.read_export_manifest(root, "export-store-1") {
    Ok(value) => value
    Err(_) => fail("read export failed")
  }
  assert_eq(loaded_version.dataset_id, dataset.dataset_id)
  assert_eq(loaded_export.input_version_id, version.version_id)
}

///|
test "store writes and reads transform runs" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let run = @moondata_core.transform_run(
    "transform-store-1",
    "ds-transform-input",
    "ds-transform-output",
    5L,
    [
      @moondata_core.transform_step(
        "step-transform-store",
        "normalize",
        "{}",
        summary="normalize input",
      ),
    ],
    quality_run_ids=["qr-transform-store"],
    lineage_id="lineage-transform-store",
    summary="store transform run",
  )
  let persisted = match @moondata_store.write_transform_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write transform failed")
  }
  assert_eq(persisted.path, root + "/transforms/transform-store-1.json")
  let loaded = match
    @moondata_store.read_transform_run(root, "transform-store-1") {
    Ok(value) => value
    Err(_) => fail("read transform failed")
  }
  assert_eq(loaded.output_dataset_id, "ds-transform-output")
  assert_eq(loaded.steps[0].kind, "normalize")
}

///|
test "store writes and reads capture manifests" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let capture = @moondata_core.capture_session(
    "cap-store-1",
    "src-store-1",
    "robot-store",
    "bridge-store",
    "stopped",
    3L,
    stopped_at_ms=Some(4L),
    receipt_ids=["receipt-store-1"],
  )
  let persisted = match @moondata_store.write_capture(root, capture) {
    Ok(value) => value
    Err(_) => fail("write capture failed")
  }
  assert_eq(persisted.path, root + "/captures/cap-store-1.json")
  let loaded = match @moondata_store.read_capture(root, "cap-store-1") {
    Ok(value) => value
    Err(_) => fail("read capture failed")
  }
  assert_eq(loaded.source_id, "src-store-1")
  assert_eq(loaded.receipt_ids[0], "receipt-store-1")
}

///|
test "store writes and reads signal series manifests" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let storage = @moondata_core.data_ref(
    "signal-store-ref", "raw-file", "moondata://media/imports/signal.csv",
  )
  let signal = @moondata_core.signal_series(
    "signal-store-1", "ds-store-1", "ep-store-1", "joint.position", "rad", 3, "unix-ms",
    storage,
  )
  let persisted = match @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  assert_eq(persisted.path, root + "/signals/signal-store-1.json")
  let loaded = match
    @moondata_store.read_signal_series(root, "signal-store-1") {
    Ok(value) => value
    Err(_) => fail("read signal failed")
  }
  assert_eq(loaded.field_path, "joint.position")
  assert_eq(loaded.storage_ref.kind, "raw-file")
}

///|
test "store writes and reads annotation target indexes" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let target = @moondata_core.moondata_ref(
    "frame",
    "frame-index-store",
    @moondata_store.frame_path(root, "frame-index-store"),
    "indexed frame",
  )
  let index = @moondata_core.annotation_target_index(
    "annotation-target-store-1",
    "annotation-store-1",
    [target],
    "reviewer-store",
    "accepted",
    5L,
    label_keys=["curation"],
    label_values=["accepted"],
    summary="stored annotation target index",
  )
  let persisted = match
    @moondata_store.write_annotation_target_index(root, index) {
    Ok(value) => value
    Err(_) => fail("write annotation target index failed")
  }
  assert_eq(
    persisted.path,
    root + "/annotation_indexes/annotation-target-store-1.json",
  )
  let loaded = match
    @moondata_store.read_annotation_target_index(
      root, "annotation-target-store-1",
    ) {
    Ok(value) => value
    Err(_) => fail("read annotation target index failed")
  }
  assert_eq(loaded.annotation_set_id, "annotation-store-1")
  assert_eq(loaded.target_refs[0].artifact_id, "frame-index-store")
  assert_eq(loaded.label_keys[0], "curation")
}

///|
test "store writes and reads lineage manifests" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let lineage = @moondata_core.lineage_manifest(
    "lineage-store-1",
    "ds-lineage-root",
    5L,
    edges=[
      @moondata_core.lineage_edge(
        "ds-lineage-root", "ds-lineage-output", "curated-from",
      ),
    ],
  )
  let persisted = match @moondata_store.write_lineage_manifest(root, lineage) {
    Ok(value) => value
    Err(_) => fail("write lineage failed")
  }
  assert_eq(persisted.path, root + "/lineage/lineage-store-1.json")
  let loaded = match
    @moondata_store.read_lineage_manifest(root, "lineage-store-1") {
    Ok(value) => value
    Err(_) => fail("read lineage failed")
  }
  assert_eq(loaded.root_dataset_id, "ds-lineage-root")
  assert_eq(loaded.edges[0].relation, "curated-from")
}

///|
test "store writes and reads catalog index" {
  let root = "target/moondata-store-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let catalog = @moondata_core.moondata_catalog(root, 5L, [
    @moondata_core.catalog_entry(
      "dataset",
      "ds-store-1",
      @moondata_store.dataset_path(root, "ds-store-1"),
      status="active",
    ),
  ])
  let persisted = match @moondata_store.write_catalog(root, catalog) {
    Ok(value) => value
    Err(_) => fail("write catalog failed")
  }
  assert_eq(persisted.path, root + "/indexes/catalog.json")
  let loaded = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_eq(loaded.entry_count, 1)
  assert_eq(loaded.entries[0].artifact_id, "ds-store-1")
}
