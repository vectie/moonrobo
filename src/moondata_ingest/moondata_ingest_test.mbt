///|
test "register capture creates source dataset episode and ordered frames" {
  let request : @moondata_ingest.CaptureRegistrationRequest = {
    source_id: "src-1",
    capture_id: "cap-1",
    dataset_id: "ds-1",
    episode_id: "ep-1",
    robot_id: "robot-1",
    bridge_id: "bridge-1",
    session_id: "session-1",
    source_kind: "moonrobo-observation",
    dataset_kind: "canonical",
    source_label: "Observation session",
    origin_uri: "robobook://session-1",
    status: "stopped",
    started_at_ms: 10L,
    stopped_at_ms: Some(30L),
    receipt_ids: ["receipt-1"],
    frames: [
      @moondata_ingest.frame_input("frame-1", 10L, "file://frame-1.json"),
      @moondata_ingest.frame_input("frame-2", 20L, "file://frame-2.json"),
    ],
  }
  let registration = @moondata_ingest.register_capture(request)
  assert_eq(registration.dataset.dataset_id, "ds-1")
  assert_eq(registration.episode.frame_count, 2)
  assert_eq(registration.frames[1].sequence_index, 1)
  assert_true(registration.frames[0].payload_ref is Some(_))
}
