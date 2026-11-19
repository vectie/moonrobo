///|
test "reexported shadow frame preserves construction and JSON methods" {
  let frame : @learning_e1_training.ActorReplayFrame = {
    captured_at_ms: 100L,
    observation: [1.0],
    goals: [2.0],
  }
  let decoded : @learning_e1_training.ActorReplayFrame = @json.from_json(
    frame.to_json(),
  )
  assert_eq(decoded.captured_at_ms, 100L)
  assert_eq(decoded.observation, [1.0])
  assert_eq(decoded.goals, [2.0])
}
