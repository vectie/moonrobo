///|
pub fn dataset_episode_path(session_id : String) -> String {
  "/api/datasets/episodes/\{session_id}"
}

///|
pub fn dataset_episode_quality_path(session_id : String) -> String {
  "\{dataset_episode_path(session_id)}/quality"
}

///|
fn session_id_from_dataset_episode_path(path : String) -> String? {
  let prefix = "/api/datasets/episodes/"
  if path.has_prefix(prefix) &&
    path.length() > prefix.length() &&
    !path.has_suffix("/quality") {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn session_id_from_dataset_episode_quality_path(path : String) -> String? {
  let prefix = "/api/datasets/episodes/"
  let suffix = "/quality"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
fn review_for_session(
  reviews : Array[@review.ProcessReview],
  session_id : String,
) -> @review.ProcessReview? {
  let mut found : @review.ProcessReview? = None
  for review in reviews {
    if review.session_id == session_id {
      found = Some(review)
    }
  }
  found
}

///|
fn build_dataset_episode(
  root : String,
  session_id : String,
) -> Result[@dataset.DatasetEpisode, HostApiResponse] {
  let session = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(issue) =>
      return Err(error_response(400, issue.code, issue.path, issue.message))
  }
  let frame_paths = match
    @runtime.list_telemetry_frame_paths(root, session_id) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let frames : Array[@core.TelemetryFrame] = []
  for frame_path in frame_paths {
    match @runtime.read_telemetry_frame_file(frame_path) {
      Ok(frame) => frames.push(frame)
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
  }
  let reviews = match @runtime.list_process_reviews(root) {
    Ok(reviews) => reviews
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let annotations = match @runtime.list_replay_annotations(root, session_id) {
    Ok(annotations) => annotations
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let replay = @replay.timeline(session, frame_paths, frames)
  Ok(
    @dataset.episode(
      session,
      replay,
      review_for_session(reviews, session_id),
      annotations~,
    ),
  )
}

///|
pub fn dataset_episode_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let session_id = match session_id_from_dataset_episode_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let episode = match build_dataset_episode(root, session_id) {
    Ok(episode) => episode
    Err(response) => return response
  }
  json_response(200, episode.to_json())
}

///|
pub fn dataset_episode_quality_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let session_id = match session_id_from_dataset_episode_quality_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let episode = match build_dataset_episode(root, session_id) {
    Ok(episode) => episode
    Err(response) => return response
  }
  json_response(200, @dataset.quality_report(episode).to_json())
}
