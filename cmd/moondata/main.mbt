///|
struct MoonDataCliSummary {
  root : String
  dataset_path : String
  episode_path : String
  quality_path : String
  status : String
  finding_count : Int
} derive(ToJson)

///|
struct MoonDataCurationCliSummary {
  root : String
  canonical_dataset_path : String
  curated_dataset_path : String
  version_path : String
  transform_path : String
  lineage_path : String
  annotation_path : String
  replay_path : String
  export_path : String
  catalog_path : String
  quality_status : String
} derive(ToJson)

///|
fn cli_arg(args : Array[String], index : Int) -> String? {
  if index < args.length() {
    Some(args[index])
  } else {
    None
  }
}

///|
fn parse_ms(value : String, fallback : Int64) -> Int64 {
  (@string.parse_int(value) catch { _ => return fallback }).to_int64()
}

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn print_usage() -> Unit {
  println("moon run cmd/moondata --target native -- init [moondata-root]")
  println(
    "moon run cmd/moondata --target native -- register-sample [moondata-root] [robot-id] [bridge-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- register-capture [moondata-root] [dataset-id] [robot-id] [bridge-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- curate-sample [moondata-root] [robot-id] [bridge-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- import-files [moondata-root] [input-dir] [dataset-id] [robot-id] [bridge-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- normalize [moondata-root] [raw-dataset-id] [canonical-dataset-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- quality [moondata-root] [canonical-dataset-id] [quality-run-id] [robot-id] [bridge-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- curate [moondata-root] [canonical-dataset-id] [quality-run-id] [curated-dataset-id] [version-id] [transform-run-id] [lineage-id] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- export [moondata-root] [version-id] [export-manifest-id] [target-format] [output-uri] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- prepare-files [moondata-root] [input-dir] [dataset-id] [robot-id] [bridge-id] [now-ms]",
  )
  println("moon run cmd/moondata --target native -- status [moondata-root]")
  println("moon run cmd/moondata --target native -- context [moondata-root]")
  println(
    "moon run cmd/moondata --target native -- handoff [moondata-root] [version-id]",
  )
  println(
    "moon run cmd/moondata --target native -- slice [moondata-root] [version-id]",
  )
  println(
    "moon run cmd/moondata --target native -- artifacts [moondata-root] [artifact-kind] [status] [artifact-id-contains] [summary-contains]",
  )
  println(
    "moon run cmd/moondata --target native -- datasets [moondata-root] [kind] [status] [source-id] [capture-id] [episode-id] [data-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- episodes [moondata-root] [dataset-id] [robot-id] [bridge-id] [session-id] [task-id] [status] [data-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- frames [moondata-root] [episode-id] [robot-id] [bridge-id] [data-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- captures [moondata-root] [source-id] [robot-id] [bridge-id] [status] [data-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- signals [moondata-root] [dataset-id] [episode-id] [field-path-contains] [storage-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- lineage [moondata-root] [lineage-id] [root-dataset-id] [node-id]",
  )
  println(
    "moon run cmd/moondata --target native -- annotations [moondata-root] [artifact-kind] [artifact-id] [reviewer] [task-id] [status] [label-key] [label-value]",
  )
  println(
    "moon run cmd/moondata --target native -- replays [moondata-root] [dataset-id] [episode-id] [source-kind] [source-id] [viewer-profile] [generated-kind]",
  )
  println(
    "moon run cmd/moondata --target native -- rebuild-catalog [moondata-root] [now-ms]",
  )
  println(
    "moon run cmd/moondata --target native -- validate [moondata-root] [now-ms]",
  )
}

///|
fn print_store_error(error : @moondata_store.MoonDataStoreIssue) -> Unit {
  println(
    "MoonData store failed [\{error.code}] \{error.path}: \{error.message}",
  )
}

///|
fn init_root(root : String) -> Unit {
  match @moondata_store.initialize_root(root) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_store_error(error)
  }
}

///|
fn sample_registration(
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> @moondata_ingest.CaptureRegistration {
  let capture_id = "cap-\{robot_id}-\{now}"
  let episode_id = "ep-\{robot_id}-\{now}"
  let request : @moondata_ingest.CaptureRegistrationRequest = {
    source_id: "src-\{robot_id}-moondata-sample",
    capture_id,
    dataset_id: "ds-\{robot_id}-sample",
    episode_id,
    robot_id,
    bridge_id,
    session_id: "session-\{robot_id}-\{now}",
    source_kind: "moondata-sample",
    source_label: "MoonData sample capture",
    origin_uri: "moondata://sample/\{robot_id}/\{now}",
    status: "stopped",
    started_at_ms: now,
    stopped_at_ms: Some(now + 20L),
    receipt_ids: ["receipt-\{capture_id}"],
    frames: [
      @moondata_ingest.frame_input(
        "frame-\{robot_id}-0001",
        now,
        "moondata://sample/\{robot_id}/frame-0001.json",
        byte_count=64L,
      ),
      @moondata_ingest.frame_input(
        "frame-\{robot_id}-0002",
        now + 20L,
        "moondata://sample/\{robot_id}/frame-0002.json",
        byte_count=64L,
      ),
    ],
  }
  @moondata_ingest.register_capture(request)
}

///|
fn sidecar_capture_request(
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> @moondata_ingest.CaptureRegistrationRequest {
  let capture_id = "cap-\{dataset_id}-\{now}"
  let episode_id = "ep-\{dataset_id}-\{now}"
  {
    source_id: "src-\{dataset_id}-sidecar",
    capture_id,
    dataset_id,
    episode_id,
    robot_id,
    bridge_id,
    session_id: "session-\{dataset_id}-\{now}",
    source_kind: "sidecar-observation",
    source_label: "MoonData sidecar capture",
    origin_uri: "sidecar://\{robot_id}/\{now}",
    status: "stopped",
    started_at_ms: now,
    stopped_at_ms: Some(now + 20L),
    receipt_ids: ["receipt-\{capture_id}"],
    frames: [
      @moondata_ingest.frame_input(
        "frame-\{dataset_id}-0001",
        now,
        "sidecar://\{robot_id}/\{now}/frame-0001.json",
        byte_count=64L,
      ),
      @moondata_ingest.frame_input(
        "frame-\{dataset_id}-0002",
        now + 20L,
        "sidecar://\{robot_id}/\{now}/frame-0002.json",
        byte_count=64L,
      ),
    ],
  }
}

///|
fn write_frame_manifests(
  root : String,
  frames : Array[@moondata_core.FrameRef],
) -> Bool {
  for frame in frames {
    match @moondata_store.write_frame(root, frame) {
      Ok(_) => ()
      Err(error) => {
        print_store_error(error)
        return false
      }
    }
  }
  true
}

///|
fn persisted_or_print(
  result : Result[
    @moondata_store.PersistedManifest,
    @moondata_store.MoonDataStoreIssue,
  ],
) -> @moondata_store.PersistedManifest? {
  match result {
    Ok(value) => Some(value)
    Err(error) => {
      print_store_error(error)
      None
    }
  }
}

///|
fn sample_quality(
  registration : @moondata_ingest.CaptureRegistration,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> @moondata_core.QualityRun {
  @moondata_quality.evaluate_episode(
    "qr-\{registration.episode.episode_id}",
    registration.dataset.dataset_id,
    registration.episode,
    registration.frames,
    now,
    config=@moondata_quality.default_quality_config(
      expected_robot_id=robot_id,
      expected_bridge_id=bridge_id,
    ),
  )
}

///|
fn persist_sample_capture(
  root : String,
  registration : @moondata_ingest.CaptureRegistration,
  quality : @moondata_core.QualityRun,
) -> MoonDataCliSummary? {
  let dataset_persisted = match
    persisted_or_print(@moondata_store.write_source(root, registration.source)) {
    Some(_) =>
      match
        persisted_or_print(
          @moondata_store.write_capture(root, registration.capture),
        ) {
        Some(_) =>
          match
            persisted_or_print(
              @moondata_store.write_dataset(root, registration.dataset),
            ) {
            Some(value) => value
            None => return None
          }
        None => return None
      }
    None => return None
  }
  let episode_persisted = match
    persisted_or_print(
      @moondata_store.write_episode(root, registration.episode),
    ) {
    Some(value) => value
    None => return None
  }
  if !write_frame_manifests(root, registration.frames) {
    return None
  }
  let quality_persisted = match
    persisted_or_print(@moondata_store.write_quality_run(root, quality)) {
    Some(value) => value
    None => return None
  }
  Some({
    root,
    dataset_path: dataset_persisted.path,
    episode_path: episode_persisted.path,
    quality_path: quality_persisted.path,
    status: quality.status,
    finding_count: quality.finding_count,
  })
}

///|
fn entry_from_persisted(
  persisted : @moondata_store.PersistedManifest,
  status? : String = "",
  summary? : String = "",
) -> @moondata_core.CatalogEntry {
  @moondata_core.catalog_entry(
    persisted.artifact_kind,
    persisted.artifact_id,
    persisted.path,
    status~,
    summary~,
  )
}

///|
fn print_read_error(error : @moondata_store.MoonDataStoreIssue) -> Unit {
  println(
    "MoonData read failed [\{error.code}] \{error.path}: \{error.message}",
  )
}

///|
fn register_sample(
  root : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  match @moondata_store.initialize_root(root) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(_) => ()
  }
  let registration = sample_registration(robot_id, bridge_id, now)
  let quality = sample_quality(registration, robot_id, bridge_id, now)
  match persist_sample_capture(root, registration, quality) {
    Some(summary) => println(summary.to_json().stringify(indent=2))
    None => ()
  }
}

///|
fn register_capture(
  root : String,
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_capture.stored_capture_registration_request(
    root,
    sidecar_capture_request(dataset_id, robot_id, bridge_id, now),
    generated_at_ms=now,
  )
  match @moondata_capture.register_stored_capture(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_store_error(error)
  }
}

///|
fn curate_sample(
  root : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  match @moondata_store.initialize_root(root) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(_) => ()
  }
  let registration = sample_registration(robot_id, bridge_id, now)
  let quality = sample_quality(registration, robot_id, bridge_id, now)
  let capture_summary = match
    persist_sample_capture(root, registration, quality) {
    Some(value) => value
    None => return
  }
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    registration.episode.episode_id,
    @moondata_store.episode_path(root, registration.episode.episode_id),
    "accepted sample episode",
  )
  let curation = @moondata_transform.curate_dataset(
    @moondata_transform.curation_request(
      "tr-\{registration.episode.episode_id}",
      "\{registration.dataset.dataset_id}-curated",
      "version-\{registration.episode.episode_id}",
      "lineage-\{registration.episode.episode_id}",
      registration.dataset,
      [registration.episode.episode_id],
      now,
      quality_run_ids=[quality.quality_run_id],
      summary="curated sample dataset",
    ),
  )
  let annotation = @moondata_annotation.review_annotation_set(
    "ann-\{registration.episode.episode_id}",
    [episode_ref],
    [
      @moondata_core.annotation_label(
        "split",
        "sample-eval",
        source="moondata-cli",
      ),
    ],
    "moondata-cli",
    now,
    summary="sample episode accepted for curation",
  )
  let replay_ref = @moondata_core.data_ref(
    "replay-\{registration.episode.episode_id}-ref",
    "replay-json",
    "moondata://replays/replay-\{registration.episode.episode_id}.json",
    content_type="application/json",
  )
  let replay = @moondata_core.replay_artifact(
    "replay-\{registration.episode.episode_id}",
    curation.dataset.dataset_id,
    curation.dataset.episode_ids,
    now,
    source_refs=[episode_ref],
    generated_refs=[replay_ref],
    summary="sample replay artifact",
  )
  let export_output = @moondata_core.data_ref(
    "export-\{registration.episode.episode_id}-ref",
    "jsonl",
    "moondata://exports/export-\{registration.episode.episode_id}.jsonl",
    content_type="application/jsonl",
  )
  let export_manifest = @moondata_export.build_export_manifest(
    "export-\{registration.episode.episode_id}",
    curation.version,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [export_output],
    now,
    report="sample export manifest",
  )
  let curated_dataset = match
    persisted_or_print(@moondata_store.write_dataset(root, curation.dataset)) {
    Some(value) => value
    None => return
  }
  let version = match
    persisted_or_print(
      @moondata_store.write_dataset_version(root, curation.version),
    ) {
    Some(value) => value
    None => return
  }
  let transform = match
    persisted_or_print(
      @moondata_store.write_transform_run(root, curation.transform),
    ) {
    Some(value) => value
    None => return
  }
  let lineage = match
    persisted_or_print(
      @moondata_store.write_lineage_manifest(root, curation.lineage),
    ) {
    Some(value) => value
    None => return
  }
  let annotation_persisted = match
    persisted_or_print(@moondata_store.write_annotation_set(root, annotation)) {
    Some(value) => value
    None => return
  }
  let replay_persisted = match
    persisted_or_print(@moondata_store.write_replay_artifact(root, replay)) {
    Some(value) => value
    None => return
  }
  let export_persisted = match
    persisted_or_print(
      @moondata_store.write_export_manifest(root, export_manifest),
    ) {
    Some(value) => value
    None => return
  }
  let catalog = @moondata_core.moondata_catalog(root, now, [
    @moondata_core.catalog_entry(
      "dataset",
      registration.dataset.dataset_id,
      capture_summary.dataset_path,
      status=registration.dataset.status,
      summary="canonical sample dataset",
    ),
    @moondata_core.catalog_entry(
      "episode",
      registration.episode.episode_id,
      capture_summary.episode_path,
      status=registration.episode.status,
      summary="sample episode",
    ),
    @moondata_core.catalog_entry(
      "quality-run",
      quality.quality_run_id,
      capture_summary.quality_path,
      status=quality.status,
      summary="sample quality gate",
    ),
    entry_from_persisted(
      curated_dataset,
      status=curation.dataset.status,
      summary="curated sample dataset",
    ),
    entry_from_persisted(
      version,
      status=curation.version.status,
      summary=curation.version.summary,
    ),
    entry_from_persisted(
      transform,
      status=curation.transform.status,
      summary=curation.transform.summary,
    ),
    entry_from_persisted(lineage, summary="sample lineage graph"),
    entry_from_persisted(
      annotation_persisted,
      status=annotation.status,
      summary=annotation.summary,
    ),
    entry_from_persisted(replay_persisted, summary=replay.summary),
    entry_from_persisted(
      export_persisted,
      status=export_manifest.status,
      summary=export_manifest.report,
    ),
  ])
  let catalog_persisted = match
    persisted_or_print(@moondata_store.write_catalog(root, catalog)) {
    Some(value) => value
    None => return
  }
  println(
    (
      {
        root,
        canonical_dataset_path: capture_summary.dataset_path,
        curated_dataset_path: curated_dataset.path,
        version_path: version.path,
        transform_path: transform.path,
        lineage_path: lineage.path,
        annotation_path: annotation_persisted.path,
        replay_path: replay_persisted.path,
        export_path: export_persisted.path,
        catalog_path: catalog_persisted.path,
        quality_status: quality.status,
      } : MoonDataCurationCliSummary)
    .to_json()
    .stringify(indent=2),
  )
}

///|
fn print_status(root : String) -> Unit {
  match @moondata_api.read_status(root) {
    Ok(status) => println(status.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_context(root : String) -> Unit {
  match @moondata_api.read_context(root) {
    Ok(context) => println(context.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_handoff(root : String, version_id : String) -> Unit {
  match @moondata_api.read_handoff(root, version_id~) {
    Ok(handoff) => println(handoff.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_slice(root : String, version_id : String) -> Unit {
  match @moondata_api.read_dataset_slice(root, version_id) {
    Ok(slice) => println(slice.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_artifacts(
  root : String,
  artifact_kind : String,
  status : String,
  artifact_id_contains : String,
  summary_contains : String,
) -> Unit {
  let query = @moondata_api.artifact_query(
    artifact_kind~,
    status~,
    artifact_id_contains~,
    summary_contains~,
  )
  match @moondata_api.list_artifacts(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_signals(
  root : String,
  dataset_id : String,
  episode_id : String,
  field_path_contains : String,
  storage_kind : String,
) -> Unit {
  let query = @moondata_api.signal_query(
    dataset_id~,
    episode_id~,
    field_path_contains~,
    storage_kind~,
  )
  match @moondata_api.list_signals(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_captures(
  root : String,
  source_id : String,
  robot_id : String,
  bridge_id : String,
  status : String,
  data_kind : String,
) -> Unit {
  let query = @moondata_api.capture_query(
    source_id~,
    robot_id~,
    bridge_id~,
    status~,
    data_kind~,
  )
  match @moondata_api.list_captures(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_datasets(
  root : String,
  kind : String,
  status : String,
  source_id : String,
  capture_id : String,
  episode_id : String,
  data_kind : String,
) -> Unit {
  let query = @moondata_api.dataset_query(
    kind~,
    status~,
    source_id~,
    capture_id~,
    episode_id~,
    data_kind~,
  )
  match @moondata_api.list_datasets(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_episodes(
  root : String,
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  session_id : String,
  task_id : String,
  status : String,
  data_kind : String,
) -> Unit {
  let query = @moondata_api.episode_query(
    dataset_id~,
    robot_id~,
    bridge_id~,
    session_id~,
    task_id~,
    status~,
    data_kind~,
  )
  match @moondata_api.list_episodes(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_frames(
  root : String,
  episode_id : String,
  robot_id : String,
  bridge_id : String,
  data_kind : String,
) -> Unit {
  let query = @moondata_api.frame_query(
    episode_id~,
    robot_id~,
    bridge_id~,
    data_kind~,
  )
  match @moondata_api.list_frames(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_lineage(
  root : String,
  lineage_id : String,
  root_dataset_id : String,
  node_id : String,
) -> Unit {
  let query = @moondata_api.lineage_query(
    lineage_id~,
    root_dataset_id~,
    node_id~,
  )
  match @moondata_api.read_lineage_graph(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_annotations(
  root : String,
  artifact_kind : String,
  artifact_id : String,
  reviewer : String,
  task_id : String,
  status : String,
  label_key : String,
  label_value : String,
) -> Unit {
  let query = @moondata_api.annotation_query(
    artifact_kind~,
    artifact_id~,
    reviewer~,
    status~,
    label_key~,
    label_value~,
    task_id~,
  )
  match @moondata_api.list_annotations(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn print_replays(
  root : String,
  dataset_id : String,
  episode_id : String,
  source_artifact_kind : String,
  source_artifact_id : String,
  viewer_profile : String,
  generated_kind : String,
) -> Unit {
  let query = @moondata_api.replay_query(
    dataset_id~,
    episode_id~,
    source_artifact_kind~,
    source_artifact_id~,
    viewer_profile~,
    generated_kind~,
  )
  match @moondata_api.list_replays(root, query~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn import_files(
  root : String,
  input_dir : String,
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_import.local_file_import_request(
    root,
    input_dir,
    dataset_id,
    robot_id,
    bridge_id,
    "import-\{dataset_id}-\{now}",
    now,
  )
  match @moondata_import.import_local_files(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn normalize_dataset(
  root : String,
  raw_dataset_id : String,
  canonical_dataset_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_normalize.normalize_request(
    root, raw_dataset_id, canonical_dataset_id, now,
  )
  match @moondata_normalize.normalize_raw_dataset(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn quality_dataset(
  root : String,
  dataset_id : String,
  quality_run_id : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_assess.dataset_quality_request(
    root,
    dataset_id,
    now,
    quality_run_id~,
    expected_robot_id=robot_id,
    expected_bridge_id=bridge_id,
  )
  match @moondata_assess.run_dataset_quality(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn curate_dataset(
  root : String,
  dataset_id : String,
  quality_run_id : String,
  curated_dataset_id : String,
  version_id : String,
  transform_run_id : String,
  lineage_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_curate.stored_curation_request(
    root,
    dataset_id,
    quality_run_id,
    now,
    output_dataset_id=curated_dataset_id,
    version_id~,
    transform_run_id~,
    lineage_id~,
  )
  match @moondata_curate.curate_stored_dataset(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn publish_export(
  root : String,
  version_id : String,
  export_manifest_id : String,
  target_format : String,
  output_uri : String,
  now : Int64,
) -> Unit {
  let request = @moondata_publish.stored_export_request(
    root,
    version_id,
    now,
    export_manifest_id~,
    target_format~,
    output_uri~,
  )
  match @moondata_publish.publish_stored_export(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn prepare_files(
  root : String,
  input_dir : String,
  dataset_id : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  let request = @moondata_pipeline.local_file_product_request(
    root, input_dir, dataset_id, robot_id, bridge_id, now,
  )
  match @moondata_pipeline.build_local_file_product(request) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn rebuild_catalog(root : String, generated_at_ms : Int64) -> Unit {
  match @moondata_index.rebuild_catalog(root, generated_at_ms) {
    Ok(rebuild) => println(rebuild.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn validate_root(root : String, generated_at_ms : Int64) -> Unit {
  match @moondata_validate.validate_and_write_root(root, generated_at_ms~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_read_error(error)
  }
}

///|
fn main {
  let args = @sys.get_cli_args()
  let command = cli_arg(args, 1).unwrap_or("help")
  let root = cli_arg(args, 2).unwrap_or("moondata")
  match command {
    "init" => init_root(root)
    "register-sample" => {
      let robot_id = cli_arg(args, 3).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 4).unwrap_or("sdk-e1")
      let now = parse_ms(cli_arg(args, 5).unwrap_or(""), now_ms())
      register_sample(root, robot_id, bridge_id, now)
    }
    "register-capture" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("ds-sidecar-capture")
      let robot_id = cli_arg(args, 4).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 5).unwrap_or("sdk-e1")
      let now = parse_ms(cli_arg(args, 6).unwrap_or(""), now_ms())
      register_capture(root, dataset_id, robot_id, bridge_id, now)
    }
    "curate-sample" => {
      let robot_id = cli_arg(args, 3).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 4).unwrap_or("sdk-e1")
      let now = parse_ms(cli_arg(args, 5).unwrap_or(""), now_ms())
      curate_sample(root, robot_id, bridge_id, now)
    }
    "status" => print_status(root)
    "context" => print_context(root)
    "handoff" => {
      let version_id = cli_arg(args, 3).unwrap_or("")
      print_handoff(root, version_id)
    }
    "slice" => {
      let version_id = cli_arg(args, 3).unwrap_or(
        "version-ds-local-import-canonical-curated",
      )
      print_slice(root, version_id)
    }
    "artifacts" => {
      let artifact_kind = cli_arg(args, 3).unwrap_or("")
      let status = cli_arg(args, 4).unwrap_or("")
      let artifact_id_contains = cli_arg(args, 5).unwrap_or("")
      let summary_contains = cli_arg(args, 6).unwrap_or("")
      print_artifacts(
        root, artifact_kind, status, artifact_id_contains, summary_contains,
      )
    }
    "signals" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("")
      let episode_id = cli_arg(args, 4).unwrap_or("")
      let field_path_contains = cli_arg(args, 5).unwrap_or("")
      let storage_kind = cli_arg(args, 6).unwrap_or("")
      print_signals(
        root, dataset_id, episode_id, field_path_contains, storage_kind,
      )
    }
    "captures" => {
      let source_id = cli_arg(args, 3).unwrap_or("")
      let robot_id = cli_arg(args, 4).unwrap_or("")
      let bridge_id = cli_arg(args, 5).unwrap_or("")
      let status = cli_arg(args, 6).unwrap_or("")
      let data_kind = cli_arg(args, 7).unwrap_or("")
      print_captures(root, source_id, robot_id, bridge_id, status, data_kind)
    }
    "datasets" => {
      let kind = cli_arg(args, 3).unwrap_or("")
      let status = cli_arg(args, 4).unwrap_or("")
      let source_id = cli_arg(args, 5).unwrap_or("")
      let capture_id = cli_arg(args, 6).unwrap_or("")
      let episode_id = cli_arg(args, 7).unwrap_or("")
      let data_kind = cli_arg(args, 8).unwrap_or("")
      print_datasets(
        root, kind, status, source_id, capture_id, episode_id, data_kind,
      )
    }
    "episodes" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("")
      let robot_id = cli_arg(args, 4).unwrap_or("")
      let bridge_id = cli_arg(args, 5).unwrap_or("")
      let session_id = cli_arg(args, 6).unwrap_or("")
      let task_id = cli_arg(args, 7).unwrap_or("")
      let status = cli_arg(args, 8).unwrap_or("")
      let data_kind = cli_arg(args, 9).unwrap_or("")
      print_episodes(
        root, dataset_id, robot_id, bridge_id, session_id, task_id, status, data_kind,
      )
    }
    "frames" => {
      let episode_id = cli_arg(args, 3).unwrap_or("")
      let robot_id = cli_arg(args, 4).unwrap_or("")
      let bridge_id = cli_arg(args, 5).unwrap_or("")
      let data_kind = cli_arg(args, 6).unwrap_or("")
      print_frames(root, episode_id, robot_id, bridge_id, data_kind)
    }
    "lineage" => {
      let lineage_id = cli_arg(args, 3).unwrap_or("")
      let root_dataset_id = cli_arg(args, 4).unwrap_or("")
      let node_id = cli_arg(args, 5).unwrap_or("")
      print_lineage(root, lineage_id, root_dataset_id, node_id)
    }
    "annotations" => {
      let artifact_kind = cli_arg(args, 3).unwrap_or("")
      let artifact_id = cli_arg(args, 4).unwrap_or("")
      let reviewer = cli_arg(args, 5).unwrap_or("")
      let task_id = cli_arg(args, 6).unwrap_or("")
      let status = cli_arg(args, 7).unwrap_or("")
      let label_key = cli_arg(args, 8).unwrap_or("")
      let label_value = cli_arg(args, 9).unwrap_or("")
      print_annotations(
        root, artifact_kind, artifact_id, reviewer, task_id, status, label_key, label_value,
      )
    }
    "replays" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("")
      let episode_id = cli_arg(args, 4).unwrap_or("")
      let source_artifact_kind = cli_arg(args, 5).unwrap_or("")
      let source_artifact_id = cli_arg(args, 6).unwrap_or("")
      let viewer_profile = cli_arg(args, 7).unwrap_or("")
      let generated_kind = cli_arg(args, 8).unwrap_or("")
      print_replays(
        root, dataset_id, episode_id, source_artifact_kind, source_artifact_id, viewer_profile,
        generated_kind,
      )
    }
    "import-files" => {
      let input_dir = cli_arg(args, 3).unwrap_or("moondata-import")
      let dataset_id = cli_arg(args, 4).unwrap_or("ds-local-import")
      let robot_id = cli_arg(args, 5).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 6).unwrap_or("local-file-import")
      let now = parse_ms(cli_arg(args, 7).unwrap_or(""), now_ms())
      import_files(root, input_dir, dataset_id, robot_id, bridge_id, now)
    }
    "normalize" => {
      let raw_dataset_id = cli_arg(args, 3).unwrap_or("ds-local-import")
      let canonical_dataset_id = cli_arg(args, 4).unwrap_or(
        "\{raw_dataset_id}-canonical",
      )
      let now = parse_ms(cli_arg(args, 5).unwrap_or(""), now_ms())
      normalize_dataset(root, raw_dataset_id, canonical_dataset_id, now)
    }
    "quality" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("ds-local-import-canonical")
      let quality_run_id = cli_arg(args, 4).unwrap_or("qr-\{dataset_id}")
      let robot_id = cli_arg(args, 5).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 6).unwrap_or("local-file-import")
      let now = parse_ms(cli_arg(args, 7).unwrap_or(""), now_ms())
      quality_dataset(
        root, dataset_id, quality_run_id, robot_id, bridge_id, now,
      )
    }
    "curate" => {
      let dataset_id = cli_arg(args, 3).unwrap_or("ds-local-import-canonical")
      let quality_run_id = cli_arg(args, 4).unwrap_or("qr-\{dataset_id}")
      let curated_dataset_id = cli_arg(args, 5).unwrap_or(
        "\{dataset_id}-curated",
      )
      let version_id = cli_arg(args, 6).unwrap_or(
        "version-\{curated_dataset_id}",
      )
      let transform_run_id = cli_arg(args, 7).unwrap_or("curate-\{dataset_id}")
      let lineage_id = cli_arg(args, 8).unwrap_or(
        "lineage-\{curated_dataset_id}",
      )
      let now = parse_ms(cli_arg(args, 9).unwrap_or(""), now_ms())
      curate_dataset(
        root, dataset_id, quality_run_id, curated_dataset_id, version_id, transform_run_id,
        lineage_id, now,
      )
    }
    "export" => {
      let version_id = cli_arg(args, 3).unwrap_or(
        "version-ds-local-import-canonical-curated",
      )
      let export_manifest_id = cli_arg(args, 4).unwrap_or(
        "export-\{version_id}",
      )
      let target_format = cli_arg(args, 5).unwrap_or("jsonl")
      let output_uri = cli_arg(args, 6).unwrap_or(
        "moondata://exports/\{export_manifest_id}.\{target_format}",
      )
      let now = parse_ms(cli_arg(args, 7).unwrap_or(""), now_ms())
      publish_export(
        root, version_id, export_manifest_id, target_format, output_uri, now,
      )
    }
    "prepare-files" => {
      let input_dir = cli_arg(args, 3).unwrap_or("moondata-import")
      let dataset_id = cli_arg(args, 4).unwrap_or("ds-local-product")
      let robot_id = cli_arg(args, 5).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 6).unwrap_or("local-file-import")
      let now = parse_ms(cli_arg(args, 7).unwrap_or(""), now_ms())
      prepare_files(root, input_dir, dataset_id, robot_id, bridge_id, now)
    }
    "rebuild-catalog" => {
      let generated_at_ms = parse_ms(cli_arg(args, 3).unwrap_or(""), now_ms())
      rebuild_catalog(root, generated_at_ms)
    }
    "validate" => {
      let generated_at_ms = parse_ms(cli_arg(args, 3).unwrap_or(""), now_ms())
      validate_root(root, generated_at_ms)
    }
    "help" => print_usage()
    _ => {
      println("unknown MoonData command: \{command}")
      print_usage()
    }
  }
}
