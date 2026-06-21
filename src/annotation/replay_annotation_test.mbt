///|
test "replay annotation records operator label" {
  let annotation = @annotation.replay_annotation(
    "annotation-replay-test",
    "session-replay-test",
    "frame-replay-test",
    "usable",
    "stable walking frame",
    "info",
    @core.operator_requester("annotation-test"),
    1000L,
  )
  assert_eq(annotation.annotation_id, "annotation-replay-test")
  assert_eq(annotation.session_id, "session-replay-test")
  assert_eq(annotation.frame_id, "frame-replay-test")
  assert_eq(annotation.created_by.kind, "operator")
  let text = @annotation.annotation_json(annotation)
  assert_true(text.contains("\"label\": \"usable\""))
}
