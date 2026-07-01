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
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDataRefView {
  artifact_kind : String
  artifact_id : String
  ref_role : String
  data_ref : @moondata_core.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDataRefList {
  root : String
  query : MoonDataDataRefQuery
  data_ref_count : Int
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
  query.checksum != ""
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
  query.checksum == "" || view.data_ref.checksum == query.checksum
}

///|
fn push_data_ref_view(
  views : Array[MoonDataDataRefView],
  artifact_kind : String,
  artifact_id : String,
  ref_role : String,
  data_ref : @moondata_core.DataRef,
) -> Unit {
  views.push({ artifact_kind, artifact_id, ref_role, data_ref })
}

///|
fn push_data_ref_views(
  views : Array[MoonDataDataRefView],
  artifact_kind : String,
  artifact_id : String,
  ref_role : String,
  data_refs : Array[@moondata_core.DataRef],
) -> Unit {
  for data_ref in data_refs {
    push_data_ref_view(views, artifact_kind, artifact_id, ref_role, data_ref)
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
            views,
            "frame",
            frame.frame_id,
            "payload",
            data_ref,
          )
        None => ()
      }
      push_data_ref_views(
        views,
        "frame",
        frame.frame_id,
        "signal",
        frame.signal_refs,
      )
      push_data_ref_views(
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
        views,
        "signal-series",
        signal.series_id,
        "storage",
        signal.storage_ref,
      )
    }
    "replay-artifact" => {
      let replay = match
        @moondata_store.read_replay_artifact(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      push_data_ref_views(
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
        views,
        "export-manifest",
        manifest.export_manifest_id,
        "output",
        manifest.output_refs,
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
  Ok({
    root,
    query,
    data_ref_count: data_refs.length(),
    data_refs,
    refs,
    summary: "MoonData data refs: \{data_refs.length()} match(es)",
  })
}
