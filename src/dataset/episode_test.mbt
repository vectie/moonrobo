///|
test "dataset episode exports replay and review metadata" {
  let profile = @core.noetix_e1_profile("dataset-robot", "Dataset Robot")
  let session = @core.stopped_observation_session(
    @core.observation_session(
      "dataset-session",
      profile,
      @core.operator_requester("dataset-test"),
      "receipt-dataset-session",
      1000L,
    ),
    1200L,
    1,
    latest_frame_id="frame-dataset-1",
    artifact_paths=["/tmp/frame-dataset-1.json"],
  )
  let frame = @core.empty_telemetry_frame(
    "frame-dataset-1",
    profile.id,
    profile.bridge.id,
    1100L,
  )
  let replay = @replay.timeline(session, ["/tmp/frame-dataset-1.json"], [frame])
  let review : @review.ProcessReview = {
    review_id: "review-dataset-session",
    task_id: "task-dataset-session",
    session_id: session.session_id,
    robot_id: profile.id,
    receipt_id: "receipt-dataset-review",
    disposition: Accepted,
    severity: Info,
    summary: "accepted",
    findings: [],
    artifact_paths: ["/tmp/review-dataset-session.json"],
    created_at_ms: 1201L,
    resolved_at_ms: None,
    resolution_note: None,
  }
  let episode = @dataset.episode(session, replay, Some(review))
  assert_eq(episode.episode_id, "episode-dataset-session")
  assert_eq(episode.format_version, 1)
  assert_eq(episode.frame_count, 1)
  assert_eq(episode.annotation_count, 0)
  assert_eq(episode.review_id, "review-dataset-session")
  assert_eq(episode.review_disposition, "accepted")
  assert_eq(episode.replay_path, "/api/replays/dataset-session")
  assert_eq(episode.artifact_paths.length(), 2)
  let report = @dataset.quality_report(episode)
  assert_true(report.passed)
  assert_eq(report.blocker_count, 0)
  assert_eq(report.warning_count, 1)
  assert_eq(report.frame_count, 1)
}

///|
test "dataset episode carries replay annotation ids" {
  let profile = @core.noetix_e1_profile("dataset-annotated", "Dataset Robot")
  let session = @core.stopped_observation_session(
    @core.observation_session(
      "dataset-annotated-session",
      profile,
      @core.operator_requester("dataset-test"),
      "receipt-dataset-annotated",
      1000L,
    ),
    1200L,
    1,
    latest_frame_id="frame-dataset-annotated",
  )
  let frame = @core.empty_telemetry_frame(
    "frame-dataset-annotated",
    profile.id,
    profile.bridge.id,
    1100L,
  )
  let replay = @replay.timeline(session, ["/tmp/frame.json"], [frame])
  let annotation = @annotation.replay_annotation(
    "annotation-dataset-annotated",
    session.session_id,
    frame.frame_id,
    "usable",
    "curated",
    "info",
    @core.operator_requester("dataset-test"),
    1201L,
  )
  let episode = @dataset.episode(session, replay, None, annotations=[annotation])
  assert_eq(episode.annotation_count, 1)
  assert_eq(episode.annotation_ids[0], "annotation-dataset-annotated")
  let report = @dataset.quality_report(episode)
  assert_true(!report.issues.any(issue => issue.code == "missing-annotations"))
}

///|
test "dataset quality report blocks incomplete episodes" {
  let episode : @dataset.DatasetEpisode = {
    episode_id: "episode-incomplete",
    format_version: 1,
    robot_id: "dataset-robot",
    bridge_id: "sdk-e1",
    session_id: "session-incomplete",
    status: "active",
    started_at_ms: 1000L,
    stopped_at_ms: None,
    frame_count: 2,
    receipt_id: "-",
    review_id: "-",
    review_disposition: "-",
    replay_path: "/api/replays/session-incomplete",
    artifact_paths: [],
    annotation_count: 0,
    annotation_ids: [],
    frames: [],
  }
  let report = @dataset.quality_report(episode)
  assert_true(!report.passed)
  assert_true(report.blocker_count >= 4)
  assert_eq(report.warning_count, 1)
  assert_true(report.issues.any(issue => issue.code == "missing-annotations"))
}
