///|
test "fixture and frame identity match Python bridge contract" {
  let snapshot = @sdk_e1_native.fixture_snapshot("self-check", 0L)
  assert_eq(@sdk_e1_native.validate_snapshot_shape(snapshot), [])
  assert_eq(snapshot.joints.length(), 24)
  assert_eq(snapshot.joints[23].position, 0.23)
  assert_eq(@sdk_e1_native.frame_id_for("frame", 2, false, false), "frame-2")
  assert_eq(@sdk_e1_native.frame_id_for("frame", 2, true, false), "frame")
  assert_eq(@sdk_e1_native.validate_command(@sdk_e1_native.fixture_command()), [])
}

///|
test "watch skips existing commands and acknowledges only success" {
  let state = @sdk_e1_native.WatchState::new(true, Some((10L, 20L)))
  assert_false(state.changed((10L, 20L)))
  assert_true(state.changed((11L, 20L)))
  assert_true(state.changed((11L, 20L)))
  state.acknowledge((11L, 20L))
  assert_false(state.changed((11L, 20L)))
}
