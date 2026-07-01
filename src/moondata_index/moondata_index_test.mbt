///|
fn ensure_tmp(root : String) -> Unit {
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => ()
    }
  }
}

///|
test "index rebuilds catalog from persisted manifests" {
  let root = "target/moondata-index-test"
  ensure_tmp("target")
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-index-1",
    "canonical",
    "active",
    10L,
    episode_ids=["ep-index-1"],
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
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_quality_run(root, quality))
  ignore(@moondata_store.write_dataset_version(root, version))
  let rebuilt = match @moondata_index.rebuild_catalog(root, 20L) {
    Ok(value) => value
    Err(error) => fail("rebuild failed: " + error.message)
  }
  assert_eq(rebuilt.entry_count, 4)
  assert_eq(rebuilt.catalog.entries[0].artifact_kind, "dataset")
  assert_eq(rebuilt.catalog.entries[0].artifact_id, "ds-index-1")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read rebuilt catalog failed")
  }
  assert_eq(catalog.entry_count, 4)
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
