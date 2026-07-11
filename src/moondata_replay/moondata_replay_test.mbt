///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create " + path)
    }
  }
}

///|
test "materialize stored replay writes payload manifest and catalog entry" {
  let root = "target/moondata-replay-test"
  ignore(@moondata_store.initialize_root(root))
  ensure_dir(root + "/media/imports/replay")
  @fsx.write_string_to_file(
    root + "/media/imports/replay/frame.json",
    "{\"t\":1}",
  ) catch {
    _ => fail("write replay source payload failed")
  }
  let payload_ref = @moondata_core.data_ref(
    "payload-frame-replay",
    "canonical-frame",
    "moondata://media/imports/replay/frame.json",
    content_type="application/json",
    byte_count=7L,
    checksum=@moondata_core.text_checksum("{\"t\":1}"),
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-replay-curated",
    "curated",
    "active",
    10L,
    episode_ids=["ep-replay"],
  )
  let version = @moondata_core.dataset_version(
    "version-replay",
    dataset.dataset_id,
    "accepted",
    11L,
    accepted_episode_ids=dataset.episode_ids,
  )
  let episode = @moondata_core.episode_manifest(
    "ep-replay",
    "ds-replay-canonical",
    "robot-replay",
    "bridge-replay",
    "session-replay",
    "stopped",
    12L,
    stopped_at_ms=Some(13L),
    frame_count=1,
    frame_ids=["frame-replay"],
  )
  let frame = @moondata_core.frame_ref(
    "frame-replay",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    12L,
    payload_ref=Some(payload_ref),
  )
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
  ignore(@moondata_index.rebuild_catalog(root, 14L))
  let result = match
    @moondata_replay.materialize_stored_replay(
      @moondata_replay.stored_replay_request(
        root,
        version.version_id,
        15L,
        replay_artifact_id="replay-version-replay",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("stored replay failed: " + error.message)
  }
  assert_eq(result.dataset_id, dataset.dataset_id)
  assert_eq(result.version_id, version.version_id)
  assert_eq(result.replay_artifact_id, "replay-version-replay")
  assert_eq(result.accepted_episode_count, 1)
  assert_eq(result.frame_count, 1)
  assert_eq(result.manifest.source_refs.length(), 4)
  assert_eq(result.manifest.generated_refs[0].kind, "replay-payload")
  assert_true(@fsx.path_exists(result.replay_payload_path))
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read replay catalog failed")
  }
  assert_true(catalog.entry_count >= 5)
  let replay = match
    @moondata_store.read_replay_artifact(root, result.replay_artifact_id) {
    Ok(value) => value
    Err(_) => fail("read replay artifact failed")
  }
  assert_eq(replay.dataset_id, dataset.dataset_id)
  assert_eq(replay.episode_ids[0], episode.episode_id)
  assert_eq(replay.generated_refs[0].checksum, result.replay_payload_checksum)
}

///|
test "materialize stored replay rejects non accepted versions" {
  let root = "target/moondata-replay-reject-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-replay-reject",
    "ds-replay-reject",
    "draft",
    20L,
    accepted_episode_ids=["ep-replay-reject"],
  )
  ignore(@moondata_store.write_dataset_version(root, version))
  match
    @moondata_replay.materialize_stored_replay(
      @moondata_replay.stored_replay_request(root, version.version_id, 21L),
    ) {
    Ok(_) => fail("expected replay to reject draft version")
    Err(error) => assert_eq(error.code, "replay-version-not-accepted")
  }
}
