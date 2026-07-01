///|
pub(all) struct MoonDataReplayQuery {
  dataset_id : String
  episode_id : String
  source_artifact_kind : String
  source_artifact_id : String
  viewer_profile : String
  generated_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataReplayList {
  root : String
  query : MoonDataReplayQuery
  replay_count : Int
  replays : Array[MoonDataReplayView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn replay_query(
  dataset_id? : String = "",
  episode_id? : String = "",
  source_artifact_kind? : String = "",
  source_artifact_id? : String = "",
  viewer_profile? : String = "",
  generated_kind? : String = "",
) -> MoonDataReplayQuery {
  {
    dataset_id,
    episode_id,
    source_artifact_kind,
    source_artifact_id,
    viewer_profile,
    generated_kind,
  }
}

///|
fn replay_query_has_filters(query : MoonDataReplayQuery) -> Bool {
  query.dataset_id != "" ||
  query.episode_id != "" ||
  query.source_artifact_kind != "" ||
  query.source_artifact_id != "" ||
  query.viewer_profile != "" ||
  query.generated_kind != ""
}

///|
fn source_refs_match_replay_query(
  refs : Array[@moondata_core.MoonDataRef],
  query : MoonDataReplayQuery,
) -> Bool {
  if query.source_artifact_kind == "" && query.source_artifact_id == "" {
    return true
  }
  for source_ref in refs {
    let kind_matches = query.source_artifact_kind == "" ||
      source_ref.artifact_kind == query.source_artifact_kind
    let id_matches = query.source_artifact_id == "" ||
      source_ref.artifact_id == query.source_artifact_id
    if kind_matches && id_matches {
      return true
    }
  }
  false
}

///|
fn generated_refs_match_kind(
  refs : Array[@moondata_core.DataRef],
  generated_kind : String,
) -> Bool {
  if generated_kind == "" {
    return true
  }
  for generated_ref in refs {
    if generated_ref.kind == generated_kind {
      return true
    }
  }
  false
}

///|
fn replay_matches(
  replay : @moondata_core.ReplayArtifact,
  query : MoonDataReplayQuery,
) -> Bool {
  if query.dataset_id != "" && replay.dataset_id != query.dataset_id {
    return false
  }
  if query.episode_id != "" &&
    !contains_id(replay.episode_ids, query.episode_id) {
    return false
  }
  if query.viewer_profile != "" && replay.viewer_profile != query.viewer_profile {
    return false
  }
  if !source_refs_match_replay_query(replay.source_refs, query) {
    return false
  }
  generated_refs_match_kind(replay.generated_refs, query.generated_kind)
}

///|
fn replay_refs(
  root : String,
  replays : Array[MoonDataReplayView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for replay in replays {
    refs.push(
      @moondata_core.moondata_ref(
        "replay-artifact",
        replay.replay_artifact_id,
        @moondata_store.replay_artifact_path(root, replay.replay_artifact_id),
        replay.summary,
      ),
    )
  }
  refs
}

///|
pub fn list_replays(
  root : String,
  query? : MoonDataReplayQuery = replay_query(),
) -> Result[MoonDataReplayList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let replays : Array[MoonDataReplayView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "replay-artifact" {
      let replay = match
        @moondata_store.read_replay_artifact(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if replay_query_has_filters(query) {
        replay_matches(replay, query)
      } else {
        true
      }
      if matches {
        replays.push(replay_view(replay))
      }
    }
  }
  let refs = replay_refs(root, replays)
  Ok({
    root,
    query,
    replay_count: replays.length(),
    replays,
    refs,
    summary: "MoonData replays: \{replays.length()} match(es)",
  })
}
