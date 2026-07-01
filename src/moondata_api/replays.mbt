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
  episode_count : Int
  source_ref_count : Int
  generated_ref_count : Int
  total_generated_byte_count : Int64
  generated_checksums : Array[String]
  latest_replay_artifact_id : String
  latest_replay_created_at_ms : Int64
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
priv struct ReplayListSummary {
  episode_count : Int
  source_ref_count : Int
  generated_ref_count : Int
  total_generated_byte_count : Int64
  generated_checksums : Array[String]
  latest_replay_artifact_id : String
  latest_replay_created_at_ms : Int64
}

///|
fn replay_list_summary(
  replays : Array[MoonDataReplayView],
) -> ReplayListSummary {
  let mut episode_count = 0
  let mut source_ref_count = 0
  let mut generated_ref_count = 0
  let mut total_generated_byte_count = 0L
  let generated_checksums : Array[String] = []
  let mut latest_id = ""
  let mut latest_created_at_ms = -1L
  for replay in replays {
    episode_count += replay.episode_ids.length()
    source_ref_count += replay.source_refs.length()
    generated_ref_count += replay.generated_refs.length()
    for generated_ref in replay.generated_refs {
      total_generated_byte_count += generated_ref.byte_count
      push_unique_checksum(generated_checksums, generated_ref.checksum)
    }
    if replay.created_at_ms > latest_created_at_ms {
      latest_id = replay.replay_artifact_id
      latest_created_at_ms = replay.created_at_ms
    }
  }
  if latest_id == "" {
    return {
      episode_count,
      source_ref_count,
      generated_ref_count,
      total_generated_byte_count,
      generated_checksums,
      latest_replay_artifact_id: "",
      latest_replay_created_at_ms: 0L,
    }
  }
  {
    episode_count,
    source_ref_count,
    generated_ref_count,
    total_generated_byte_count,
    generated_checksums,
    latest_replay_artifact_id: latest_id,
    latest_replay_created_at_ms: latest_created_at_ms,
  }
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
  let evidence = replay_list_summary(replays)
  Ok({
    root,
    query,
    replay_count: replays.length(),
    episode_count: evidence.episode_count,
    source_ref_count: evidence.source_ref_count,
    generated_ref_count: evidence.generated_ref_count,
    total_generated_byte_count: evidence.total_generated_byte_count,
    generated_checksums: evidence.generated_checksums,
    latest_replay_artifact_id: evidence.latest_replay_artifact_id,
    latest_replay_created_at_ms: evidence.latest_replay_created_at_ms,
    replays,
    refs,
    summary: "MoonData replays: \{replays.length()} match(es), \{evidence.episode_count} episode ref(s), \{evidence.generated_ref_count} generated ref(s), \{evidence.total_generated_byte_count} byte(s), latest \{evidence.latest_replay_artifact_id}",
  })
}
