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
