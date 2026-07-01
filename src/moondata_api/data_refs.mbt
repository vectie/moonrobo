///|
pub(all) struct MoonDataDataRefQuery {
  artifact_kind : String
  artifact_id : String
  ref_role : String
  data_kind : String
  ref_id_contains : String
  uri_contains : String
  content_type : String
  checksum : String
  local_status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDataRefView {
  artifact_kind : String
  artifact_id : String
  ref_role : String
  data_ref : @moondata_core.DataRef
  local_status : String
  relative_path : String
  local_path : String
  payload_root : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDataRefList {
  root : String
  query : MoonDataDataRefQuery
  data_ref_count : Int
  total_byte_count : Int64
  checksums : Array[String]
  present_count : Int
  missing_count : Int
  non_payload_count : Int
  unsafe_count : Int
  external_count : Int
  data_refs : Array[MoonDataDataRefView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn data_ref_query(
  artifact_kind? : String = "",
  artifact_id? : String = "",
  ref_role? : String = "",
  data_kind? : String = "",
  ref_id_contains? : String = "",
  uri_contains? : String = "",
  content_type? : String = "",
  checksum? : String = "",
  local_status? : String = "",
) -> MoonDataDataRefQuery {
  {
    artifact_kind,
    artifact_id,
    ref_role,
    data_kind,
    ref_id_contains,
    uri_contains,
    content_type,
    checksum,
    local_status,
  }
}

///|
fn data_ref_query_has_filters(query : MoonDataDataRefQuery) -> Bool {
  query.artifact_kind != "" ||
  query.artifact_id != "" ||
  query.ref_role != "" ||
  query.data_kind != "" ||
  query.ref_id_contains != "" ||
  query.uri_contains != "" ||
  query.content_type != "" ||
  query.checksum != "" ||
  query.local_status != ""
}

///|
fn data_ref_view_matches(
  view : MoonDataDataRefView,
  query : MoonDataDataRefQuery,
) -> Bool {
  if query.artifact_kind != "" && view.artifact_kind != query.artifact_kind {
    return false
  }
  if query.artifact_id != "" && view.artifact_id != query.artifact_id {
    return false
  }
  if query.ref_role != "" && view.ref_role != query.ref_role {
    return false
  }
  if query.data_kind != "" && view.data_ref.kind != query.data_kind {
    return false
  }
  if query.ref_id_contains != "" &&
    !view.data_ref.ref_id.contains(query.ref_id_contains) {
    return false
  }
  if query.uri_contains != "" && !view.data_ref.uri.contains(query.uri_contains) {
    return false
  }
  if query.content_type != "" &&
    view.data_ref.content_type != query.content_type {
    return false
  }
  if query.checksum != "" && view.data_ref.checksum != query.checksum {
    return false
  }
  query.local_status == "" || view.local_status == query.local_status
}

///|
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn data_ref_view(
  root : String,
  artifact_kind : String,
  artifact_id : String,
  ref_role : String,
  data_ref : @moondata_core.DataRef,
) -> MoonDataDataRefView {
  match @moondata_core.moondata_uri_relative_path(data_ref.uri) {
    Some(relative) =>
      if @moondata_core.moondata_payload_relative_path_is_allowed(relative) {
        let path = join(root, relative)
        {
          artifact_kind,
          artifact_id,
          ref_role,
          data_ref,
          local_status: if @fsx.path_exists(path) {
            "present"
          } else {
            "missing"
          },
          relative_path: relative,
          local_path: path,
          payload_root: @moondata_core.moondata_payload_root(relative),
        }
      } else {
        {
          artifact_kind,
          artifact_id,
          ref_role,
          data_ref,
          local_status: "non-payload",
          relative_path: relative,
          local_path: join(root, relative),
          payload_root: "",
        }
      }
    None => {
      let status = if data_ref.uri.has_prefix("moondata://") {
        "unsafe"
      } else {
        "external"
      }
      {
        artifact_kind,
        artifact_id,
        ref_role,
        data_ref,
        local_status: status,
        relative_path: "",
        local_path: "",
        payload_root: "",
      }
    }
  }
}

///|
fn push_data_ref_view(
  root : String,
  views : Array[MoonDataDataRefView],
  artifact_kind : String,
  artifact_id : String,
  ref_role : String,
  data_ref : @moondata_core.DataRef,
) -> Unit {
  views.push(
    data_ref_view(root, artifact_kind, artifact_id, ref_role, data_ref),
  )
}

///|
fn push_data_ref_views(
  root : String,
  views : Array[MoonDataDataRefView],
  artifact_kind : String,
  artifact_id : String,
  ref_role : String,
  data_refs : Array[@moondata_core.DataRef],
) -> Unit {
  for data_ref in data_refs {
    push_data_ref_view(
      root, views, artifact_kind, artifact_id, ref_role, data_ref,
    )
  }
}

///|
fn dataset_kind_from_ref_path(path : String) -> String {
  if path.contains("/datasets/raw/") {
    "raw"
  } else if path.contains("/datasets/curated/") {
    "curated"
  } else {
    "canonical"
  }
}

///|
fn collect_entry_data_refs(
  root : String,
  entry : @moondata_core.CatalogEntry,
  views : Array[MoonDataDataRefView],
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  match entry.artifact_kind {
    "source" => {
      let source = match @moondata_store.read_source(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "source",
        source.source_id,
        "source",
        source.source_refs,
      )
    }
    "capture" => {
      let capture = match
        @moondata_store.read_capture(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "capture",
        capture.capture_id,
        "data",
        capture.data_refs,
      )
    }
    "dataset" => {
      let dataset = match
        @moondata_store.read_dataset_kind(
          root,
          dataset_kind_from_ref_path(entry.manifest_path),
          entry.artifact_id,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "dataset",
        dataset.dataset_id,
        "data",
        dataset.data_refs,
      )
    }
    "episode" => {
      let episode = match
        @moondata_store.read_episode(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "episode",
        episode.episode_id,
        "data",
        episode.data_refs,
      )
    }
    "frame" => {
      let frame = match @moondata_store.read_frame(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match frame.payload_ref {
        Some(data_ref) =>
          push_data_ref_view(
            root,
            views,
            "frame",
            frame.frame_id,
            "payload",
            data_ref,
          )
        None => ()
      }
      push_data_ref_views(
        root,
        views,
        "frame",
        frame.frame_id,
        "signal",
        frame.signal_refs,
      )
      push_data_ref_views(
        root,
        views,
        "frame",
        frame.frame_id,
        "media",
        frame.media_refs,
      )
    }
    "signal-series" => {
      let signal = match
        @moondata_store.read_signal_series(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_view(
        root,
        views,
        "signal-series",
        signal.series_id,
        "storage",
        signal.storage_ref,
      )
    }
    "robot-model" => {
      let model = match
        @moondata_store.read_robot_model(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_view(
        root,
        views,
        "robot-model",
        model.model_id,
        "urdf",
        model.urdf_ref,
      )
      push_data_ref_views(
        root,
        views,
        "robot-model",
        model.model_id,
        "mesh",
        model.mesh_refs,
      )
      push_data_ref_views(
        root,
        views,
        "robot-model",
        model.model_id,
        "material",
        model.material_refs,
      )
    }
    "replay-artifact" => {
      let replay = match
        @moondata_store.read_replay_artifact(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "replay-artifact",
        replay.replay_artifact_id,
        "generated",
        replay.generated_refs,
      )
    }
    "export-manifest" => {
      let manifest = match
        @moondata_store.read_export_manifest(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "export-manifest",
        manifest.export_manifest_id,
        "output",
        manifest.output_refs,
      )
    }
    "handoff-dossier" => {
      let dossier = match
        @moondata_store.read_handoff_dossier(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
        root,
        views,
        "handoff-dossier",
        dossier.handoff_dossier_id,
        "output",
        dossier.output_refs,
      )
    }
    _ => ()
  }
  Ok(())
}

///|
fn data_ref_refs(
  views : Array[MoonDataDataRefView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for view in views {
    refs.push(
      @moondata_core.moondata_ref(
        view.artifact_kind,
        view.artifact_id,
        view.data_ref.uri,
        "\{view.ref_role} \{view.data_ref.kind} \{view.data_ref.ref_id}",
      ),
    )
  }
  refs
}

///|
fn data_ref_total_byte_count(views : Array[MoonDataDataRefView]) -> Int64 {
  let mut count = 0L
  for view in views {
    count += view.data_ref.byte_count
  }
  count
}

///|
fn data_ref_checksums(views : Array[MoonDataDataRefView]) -> Array[String] {
  let checksums : Array[String] = []
  for view in views {
    push_unique_checksum(checksums, view.data_ref.checksum)
  }
  checksums
}

///|
priv struct DataRefLocalStatusSummary {
  present_count : Int
  missing_count : Int
  non_payload_count : Int
  unsafe_count : Int
  external_count : Int
}

///|
fn data_ref_local_status_summary(
  views : Array[MoonDataDataRefView],
) -> DataRefLocalStatusSummary {
  let mut present_count = 0
  let mut missing_count = 0
  let mut non_payload_count = 0
  let mut unsafe_count = 0
  let mut external_count = 0
  for view in views {
    match view.local_status {
      "present" => present_count += 1
      "missing" => missing_count += 1
      "non-payload" => non_payload_count += 1
      "unsafe" => unsafe_count += 1
      "external" => external_count += 1
      _ => ()
    }
  }
  {
    present_count,
    missing_count,
    non_payload_count,
    unsafe_count,
    external_count,
  }
}

///|
pub fn list_data_refs(
  root : String,
  query? : MoonDataDataRefQuery = data_ref_query(),
) -> Result[MoonDataDataRefList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let all_views : Array[MoonDataDataRefView] = []
  for entry in catalog.entries {
    match collect_entry_data_refs(root, entry, all_views) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let data_refs : Array[MoonDataDataRefView] = []
  for view in all_views {
    let matches = if data_ref_query_has_filters(query) {
      data_ref_view_matches(view, query)
    } else {
      true
    }
    if matches {
      data_refs.push(view)
    }
  }
  let refs = data_ref_refs(data_refs)
  let byte_count = data_ref_total_byte_count(data_refs)
  let checksums = data_ref_checksums(data_refs)
  let local_status = data_ref_local_status_summary(data_refs)
  Ok({
    root,
    query,
    data_ref_count: data_refs.length(),
    total_byte_count: byte_count,
    checksums,
    present_count: local_status.present_count,
    missing_count: local_status.missing_count,
    non_payload_count: local_status.non_payload_count,
    unsafe_count: local_status.unsafe_count,
    external_count: local_status.external_count,
    data_refs,
    refs,
    summary: "MoonData data refs: \{data_refs.length()} match(es), \{byte_count} byte(s), \{local_status.present_count} present, \{local_status.missing_count} missing, \{local_status.external_count} external, \{local_status.unsafe_count} unsafe, \{local_status.non_payload_count} non-payload",
  })
}
