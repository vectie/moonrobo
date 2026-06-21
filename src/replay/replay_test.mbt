///|
test "replay timeline summarizes observation frames" {
  let profile = @core.noetix_e1_profile("replay-robot", "Replay Robot")
  let session = @core.observation_session(
    "replay-session",
    profile,
    @core.operator_requester("replay-test"),
    "receipt-replay",
    10L,
    telemetry_frame_count=1,
    latest_frame_id="frame-replay",
    artifact_paths=["/tmp/frame-replay.json"],
  )
  let frame = @core.empty_telemetry_frame(
    "frame-replay",
    profile.id,
    profile.bridge.id,
    11L,
  )
  let timeline = @replay.timeline(session, ["/tmp/frame-replay.json"], [frame])
  assert_eq(timeline.session_id, "replay-session")
  assert_eq(timeline.status, "active")
  assert_eq(timeline.frames.length(), 1)
  assert_eq(timeline.frames[0].frame_id, "frame-replay")
  assert_eq(timeline.frames[0].artifact_path, "/tmp/frame-replay.json")
  assert_eq(timeline.frames[0].joint_count, 0)
}
