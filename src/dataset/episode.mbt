///|
pub(all) struct DatasetEpisode {
  episode_id : String
  format_version : Int
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  session_id : String
  status : String
  started_at_ms : Int64
  stopped_at_ms : Int64?
  frame_count : Int
  receipt_id : @core.ReceiptId
  review_id : String
  review_disposition : String
  replay_path : String
  artifact_paths : Array[String]
  frames : Array[@replay.ReplayFrameSummary]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn review_id(review : @review.ProcessReview?) -> String {
  match review {
    Some(value) => value.review_id
    None => "-"
  }
}

///|
fn review_disposition(review : @review.ProcessReview?) -> String {
  match review {
    Some(value) =>
      match value.disposition {
        Accepted => "accepted"
        NeedsHumanReview => "needs-human-review"
      }
    None => "-"
  }
}

///|
fn push_unique(paths : Array[String], path : String) -> Unit {
  if path == "" {
    return
  }
  if !paths.any(value => value == path) {
    paths.push(path)
  }
}

///|
fn episode_artifacts(
  replay : @replay.ReplayTimeline,
  review : @review.ProcessReview?,
) -> Array[String] {
  let paths : Array[String] = []
  for frame in replay.frames {
    push_unique(paths, frame.artifact_path)
  }
  match review {
    Some(value) =>
      for path in value.artifact_paths {
        push_unique(paths, path)
      }
    None => ()
  }
  paths
}

///|
pub fn episode(
  session : @core.ObservationSession,
  replay : @replay.ReplayTimeline,
  review : @review.ProcessReview?,
) -> DatasetEpisode {
  {
    episode_id: "episode-\{session.session_id}",
    format_version: 1,
    robot_id: session.robot_id,
    bridge_id: session.bridge_id,
    session_id: session.session_id,
    status: replay.status,
    started_at_ms: session.started_at_ms,
    stopped_at_ms: session.stopped_at_ms,
    frame_count: replay.frames.length(),
    receipt_id: session.receipt_id,
    review_id: review_id(review),
    review_disposition: review_disposition(review),
    replay_path: "/api/replays/\{session.session_id}",
    artifact_paths: episode_artifacts(replay, review),
    frames: replay.frames,
  }
}

///|
pub fn episode_json(episode : DatasetEpisode, indent? : Int = 2) -> String {
  episode.to_json().stringify(indent~)
}
