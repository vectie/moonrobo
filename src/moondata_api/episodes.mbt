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
  Ok({
    root,
    query,
    episode_count: episodes.length(),
    episodes,
    refs,
    summary: "MoonData episodes: \{episodes.length()} match(es)",
  })
}
