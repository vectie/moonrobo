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
          "validation-report",
          "validation-handoff",
          "validations/validation-handoff.json",
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
