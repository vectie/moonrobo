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
  annotation_count : Int
  annotation_ids : Array[String]
  frames : Array[@replay.ReplayFrameSummary]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DatasetQualityIssue {
  code : String
  severity : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DatasetQualityReport {
  episode_id : String
  passed : Bool
  issue_count : Int
  blocker_count : Int
  warning_count : Int
  frame_count : Int
  artifact_count : Int
  issues : Array[DatasetQualityIssue]
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
fn annotation_ids(
  annotations : Array[@annotation.ReplayAnnotation],
) -> Array[String] {
  let ids : Array[String] = []
  for annotation in annotations {
    ids.push(annotation.annotation_id)
  }
  ids
}

///|
pub fn episode(
  session : @core.ObservationSession,
  replay : @replay.ReplayTimeline,
  review : @review.ProcessReview?,
  annotations? : Array[@annotation.ReplayAnnotation] = [],
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
    annotation_count: annotations.length(),
    annotation_ids: annotation_ids(annotations),
    frames: replay.frames,
  }
}

///|
pub fn episode_json(episode : DatasetEpisode, indent? : Int = 2) -> String {
  episode.to_json().stringify(indent~)
}

///|
fn quality_issue(
  code : String,
  severity : String,
  message : String,
) -> DatasetQualityIssue {
  { code, severity, message }
}

///|
fn add_blocker(
  issues : Array[DatasetQualityIssue],
  code : String,
  message : String,
) -> Unit {
  issues.push(quality_issue(code, "blocker", message))
}

///|
fn add_warning(
  issues : Array[DatasetQualityIssue],
  code : String,
  message : String,
) -> Unit {
  issues.push(quality_issue(code, "warning", message))
}

///|
fn count_severity(
  issues : Array[DatasetQualityIssue],
  severity : String,
) -> Int {
  let mut count = 0
  for issue in issues {
    if issue.severity == severity {
      count += 1
    }
  }
  count
}

///|
fn add_frame_error_warnings(
  issues : Array[DatasetQualityIssue],
  episode : DatasetEpisode,
) -> Unit {
  for frame in episode.frames {
    if frame.error_count > 0 {
      add_warning(
        issues,
        "frame-errors",
        "frame \{frame.frame_id} reported \{frame.error_count} error(s)",
      )
    }
  }
}

///|
pub fn quality_report(
  episode : DatasetEpisode,
  min_frame_count? : Int = 1,
) -> DatasetQualityReport {
  let issues : Array[DatasetQualityIssue] = []
  if episode.status != "stopped" {
    add_blocker(issues, "session-not-stopped", "episode session is not stopped")
  }
  if episode.frame_count != episode.frames.length() {
    add_blocker(
      issues, "frame-count-mismatch", "episode frame_count does not match exported frame summaries",
    )
  }
  if episode.frames.length() < min_frame_count {
    add_blocker(
      issues,
      "too-few-frames",
      "episode has fewer than \{min_frame_count} frame(s)",
    )
  }
  if episode.review_disposition != "accepted" {
    add_blocker(
      issues, "review-not-accepted", "episode review disposition is not accepted",
    )
  }
  if episode.receipt_id == "-" {
    add_blocker(issues, "missing-receipt", "episode has no receipt id")
  }
  if episode.artifact_paths.length() < episode.frames.length() {
    add_warning(
      issues, "missing-artifacts", "episode has fewer artifacts than frame summaries",
    )
  }
  if episode.annotation_count == 0 {
    add_warning(
      issues, "missing-annotations", "episode has no replay annotations",
    )
  }
  add_frame_error_warnings(issues, episode)
  let blockers = count_severity(issues, "blocker")
  let warnings = count_severity(issues, "warning")
  {
    episode_id: episode.episode_id,
    passed: blockers == 0,
    issue_count: issues.length(),
    blocker_count: blockers,
    warning_count: warnings,
    frame_count: episode.frames.length(),
    artifact_count: episode.artifact_paths.length(),
    issues,
  }
}

///|
pub fn quality_report_json(
  report : DatasetQualityReport,
  indent? : Int = 2,
) -> String {
  report.to_json().stringify(indent~)
}
