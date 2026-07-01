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
