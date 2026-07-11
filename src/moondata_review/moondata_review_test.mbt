///|
test "materialize stored review writes annotation target index and catalog entries" {
  let root = "target/moondata-review-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-review-curated",
    "curated",
    "active",
    10L,
    episode_ids=["ep-review"],
  )
  let version = @moondata_core.dataset_version(
    "version-review",
    dataset.dataset_id,
    "accepted",
    11L,
    accepted_episode_ids=dataset.episode_ids,
    quality_run_ids=["qr-review"],
  )
  let quality = @moondata_core.quality_run(
    "qr-review",
    dataset.dataset_id,
    dataset.episode_ids,
    12L,
    [],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-review",
    "ds-review-canonical",
    "robot-review",
    "bridge-review",
    "session-review",
    "stopped",
    13L,
    stopped_at_ms=Some(14L),
    frame_count=1,
    frame_ids=["frame-review"],
  )
  let frame = @moondata_core.frame_ref(
    "frame-review",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    13L,
  )
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_quality_run(root, quality))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
  ignore(@moondata_index.rebuild_catalog(root, 15L))
  let result = match
    @moondata_review.materialize_stored_review(
      @moondata_review.stored_review_request(
        root,
        version.version_id,
        "operator-review",
        16L,
        annotation_set_id="annotation-version-review",
        labels=[
          @moondata_core.annotation_label(
            "split",
            "train",
            source="operator-review",
          ),
        ],
        summary="reviewed version",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("stored review failed: " + error.message)
  }
  assert_eq(result.dataset_id, dataset.dataset_id)
  assert_eq(result.annotation_set_id, "annotation-version-review")
  assert_eq(
    result.annotation_index_id,
    "annotation-target-annotation-version-review",
  )
  assert_eq(result.label_count, 1)
  assert_eq(result.evidence_ref_count, 1)
  assert_eq(result.target_ref_count, 4)
  assert_eq(result.annotation.labels[0].key, "split")
  assert_eq(result.annotation_index.label_values[0], "train")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read review catalog failed")
  }
  assert_true(catalog.entry_count >= 7)
  let target = match
    @moondata_store.read_annotation_target_index(
      root,
      result.annotation_index_id,
    ) {
    Ok(value) => value
    Err(_) => fail("read annotation target index failed")
  }
  assert_eq(target.annotation_set_id, result.annotation_set_id)
  assert_eq(target.target_refs.length(), 4)
}

///|
test "materialize stored review rejects draft versions" {
  let root = "target/moondata-review-reject-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-review-reject",
    "ds-review-reject",
    "draft",
    20L,
    accepted_episode_ids=["ep-review-reject"],
  )
  ignore(@moondata_store.write_dataset_version(root, version))
  match
    @moondata_review.materialize_stored_review(
      @moondata_review.stored_review_request(
        root,
        version.version_id,
        "operator-review",
        21L,
      ),
    ) {
    Ok(_) => fail("expected review to reject draft version")
    Err(error) => assert_eq(error.code, "review-version-not-accepted")
  }
}

///|
test "materialize stored review rejects non passed quality evidence" {
  let root = "target/moondata-review-quality-reject-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "ds-review-quality-curated",
    "curated",
    "active",
    30L,
    episode_ids=["ep-review-quality"],
  )
  let version = @moondata_core.dataset_version(
    "version-review-quality",
    dataset.dataset_id,
    "accepted",
    31L,
    accepted_episode_ids=dataset.episode_ids,
    quality_run_ids=["qr-review-quality"],
  )
  let finding = @moondata_core.quality_finding(
    "finding-review-quality", "requires-review", "warning", "dataset", "ds-review-quality-canonical",
    "quality evidence still needs review",
  )
  let quality = @moondata_core.quality_run(
    "qr-review-quality",
    "ds-review-quality-canonical",
    dataset.episode_ids,
    32L,
    [finding],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-review-quality",
    "ds-review-quality-canonical",
    "robot-review",
    "bridge-review",
    "session-review",
    "stopped",
    33L,
    stopped_at_ms=Some(34L),
    frame_count=1,
    frame_ids=["frame-review-quality"],
  )
  let frame = @moondata_core.frame_ref(
    "frame-review-quality",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    33L,
  )
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_quality_run(root, quality))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
  match
    @moondata_review.materialize_stored_review(
      @moondata_review.stored_review_request(
        root,
        version.version_id,
        "operator-review",
        35L,
      ),
    ) {
    Ok(_) => fail("expected review to reject non-passed quality evidence")
    Err(error) => assert_eq(error.code, "review-quality-not-passed")
  }
}
