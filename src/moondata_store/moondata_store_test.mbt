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
