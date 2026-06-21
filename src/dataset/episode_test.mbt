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
  assert_eq(episode.review_id, "review-dataset-session")
  assert_eq(episode.review_disposition, "accepted")
  assert_eq(episode.replay_path, "/api/replays/dataset-session")
  assert_eq(episode.artifact_paths.length(), 2)
}
