///|
pub(all) struct MoonDataEpisodeQuery {
  dataset_id : String
  robot_id : String
  bridge_id : String
  session_id : String
  task_id : String
  status : String
  data_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataEpisodeList {
  root : String
  query : MoonDataEpisodeQuery
  episode_count : Int
  declared_frame_count : Int
  frame_ref_count : Int
  data_ref_count : Int
  receipt_count : Int
  stopped_episode_count : Int
  total_data_byte_count : Int64
  latest_episode_id : String
  latest_episode_status : String
  latest_episode_started_at_ms : Int64
  episodes : Array[@moondata_core.EpisodeManifest]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn episode_query(
  dataset_id? : String = "",
  robot_id? : String = "",
  bridge_id? : String = "",
  session_id? : String = "",
  task_id? : String = "",
  status? : String = "",
  data_kind? : String = "",
) -> MoonDataEpisodeQuery {
  { dataset_id, robot_id, bridge_id, session_id, task_id, status, data_kind }
}

///|
fn episode_query_has_filters(query : MoonDataEpisodeQuery) -> Bool {
  query.dataset_id != "" ||
  query.robot_id != "" ||
  query.bridge_id != "" ||
  query.session_id != "" ||
  query.task_id != "" ||
  query.status != "" ||
  query.data_kind != ""
}

///|
fn episode_has_data_kind(
  episode : @moondata_core.EpisodeManifest,
  data_kind : String,
) -> Bool {
  if data_kind == "" {
    return true
  }
  for data_ref in episode.data_refs {
    if data_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn episode_matches(
  episode : @moondata_core.EpisodeManifest,
  query : MoonDataEpisodeQuery,
) -> Bool {
  if query.dataset_id != "" && episode.dataset_id != query.dataset_id {
    return false
  }
  if query.robot_id != "" && episode.robot_id != query.robot_id {
    return false
  }
  if query.bridge_id != "" && episode.bridge_id != query.bridge_id {
    return false
  }
  if query.session_id != "" && episode.session_id != query.session_id {
    return false
  }
  if query.task_id != "" && episode.task_id != query.task_id {
    return false
  }
  if query.status != "" && episode.status != query.status {
    return false
  }
  episode_has_data_kind(episode, query.data_kind)
}

///|
fn episode_refs(
  root : String,
  episodes : Array[@moondata_core.EpisodeManifest],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for episode in episodes {
    refs.push(
      @moondata_core.moondata_ref(
        "episode",
        episode.episode_id,
        @moondata_store.episode_path(root, episode.episode_id),
        "\{episode.dataset_id} \{episode.frame_count} frame(s) \{episode.status}",
      ),
    )
  }
  refs
}

///|
priv struct EpisodeListSummary {
  declared_frame_count : Int
  frame_ref_count : Int
  data_ref_count : Int
  receipt_count : Int
  stopped_episode_count : Int
  total_data_byte_count : Int64
  latest_episode_id : String
  latest_episode_status : String
  latest_episode_started_at_ms : Int64
}

///|
fn episode_list_summary(
  episodes : Array[@moondata_core.EpisodeManifest],
) -> EpisodeListSummary {
  let mut declared_frame_count = 0
  let mut frame_ref_count = 0
  let mut data_ref_count = 0
  let mut receipt_count = 0
  let mut stopped_episode_count = 0
  let mut total_data_byte_count = 0L
  let mut latest_id = ""
  let mut latest_status = "unrecorded"
  let mut latest_started_at_ms = -1L
  for episode in episodes {
    declared_frame_count += episode.frame_count
    frame_ref_count += episode.frame_ids.length()
    data_ref_count += episode.data_refs.length()
    receipt_count += episode.receipt_ids.length()
    if episode.stopped_at_ms is Some(_) {
      stopped_episode_count += 1
    }
    for data_ref in episode.data_refs {
      total_data_byte_count += data_ref.byte_count
    }
    if episode.started_at_ms > latest_started_at_ms {
      latest_id = episode.episode_id
      latest_status = episode.status
      latest_started_at_ms = episode.started_at_ms
    }
  }
  if latest_id == "" {
    return {
      declared_frame_count,
      frame_ref_count,
      data_ref_count,
      receipt_count,
      stopped_episode_count,
      total_data_byte_count,
      latest_episode_id: "",
      latest_episode_status: "unrecorded",
      latest_episode_started_at_ms: 0L,
    }
  }
  {
    declared_frame_count,
    frame_ref_count,
    data_ref_count,
    receipt_count,
    stopped_episode_count,
    total_data_byte_count,
    latest_episode_id: latest_id,
    latest_episode_status: latest_status,
    latest_episode_started_at_ms: latest_started_at_ms,
  }
}

///|
pub fn list_episodes(
  root : String,
  query? : MoonDataEpisodeQuery = episode_query(),
) -> Result[MoonDataEpisodeList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let episodes : Array[@moondata_core.EpisodeManifest] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "episode" {
      let episode = match
        @moondata_store.read_episode(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if episode_query_has_filters(query) {
        episode_matches(episode, query)
      } else {
        true
      }
      if matches {
        episodes.push(episode)
      }
    }
  }
  let refs = episode_refs(root, episodes)
  let evidence = episode_list_summary(episodes)
  Ok({
    root,
    query,
    episode_count: episodes.length(),
    declared_frame_count: evidence.declared_frame_count,
    frame_ref_count: evidence.frame_ref_count,
    data_ref_count: evidence.data_ref_count,
    receipt_count: evidence.receipt_count,
    stopped_episode_count: evidence.stopped_episode_count,
    total_data_byte_count: evidence.total_data_byte_count,
    latest_episode_id: evidence.latest_episode_id,
    latest_episode_status: evidence.latest_episode_status,
    latest_episode_started_at_ms: evidence.latest_episode_started_at_ms,
    episodes,
    refs,
    summary: "MoonData episodes: \{episodes.length()} match(es), \{evidence.declared_frame_count} declared frame(s), \{evidence.data_ref_count} data ref(s), \{evidence.total_data_byte_count} byte(s), latest \{evidence.latest_episode_status}",
  })
}
