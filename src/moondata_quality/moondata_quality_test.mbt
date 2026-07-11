///|
test "quality flags timestamp gaps and passes clean episode" {
  let payload = @moondata_core.data_ref(
    "payload-frame-1", "telemetry-frame", "file://frame-1.json",
  )
  let frame1 = @moondata_core.frame_ref(
    "frame-1",
    "ep-1",
    "robot-1",
    "bridge-1",
    0,
    100L,
    payload_ref=Some(payload),
  )
  let frame2 = @moondata_core.frame_ref(
    "frame-2",
    "ep-1",
    "robot-1",
    "bridge-1",
    1,
    450L,
    payload_ref=Some(payload),
  )
  let episode = @moondata_core.episode_manifest(
    "ep-1",
    "ds-1",
    "robot-1",
    "bridge-1",
    "session-1",
    "stopped",
    100L,
    stopped_at_ms=Some(450L),
    frame_count=2,
    frame_ids=["frame-1", "frame-2"],
  )
  let run = @moondata_quality.evaluate_episode(
    "qr-1",
    "ds-1",
    episode,
    [frame1, frame2],
    500L,
    config=@moondata_quality.default_quality_config(
      expected_robot_id="robot-1",
      expected_bridge_id="bridge-1",
      max_frame_gap_ms=250L,
    ),
  )
  assert_eq(run.status, "review")
  assert_eq(run.warning_count, 1)
  assert_eq(run.findings[0].rule_id, "timestamp-gap")
}

///|
test "quality blocks identity mismatch" {
  let episode = @moondata_core.episode_manifest(
    "ep-2", "ds-1", "wrong", "bridge-1", "session-2", "stopped", 100L,
  )
  let run = @moondata_quality.evaluate_episode(
    "qr-2",
    "ds-1",
    episode,
    [],
    200L,
    config=@moondata_quality.default_quality_config(
      expected_robot_id="robot-1",
      min_frame_count=0,
    ),
  )
  assert_eq(run.status, "blocked")
  assert_eq(run.blocker_count, 1)
  assert_eq(run.findings[0].rule_id, "robot-id-mismatch")
}
