///|
test "full body encoding removes world XY and yaw" {
  let q = [
    0.0, 0.0, 0.8, 1.0, 0.0, 0.0, 0.0, 0.2, 0.1, -0.2, 0.3, 0.01, 0.02, 0.03, 0.4,
  ]
  let positions = [[0.0, 0.0, 0.8], [0.1, 0.2, 0.5]]
  let rotations = [identity(), rotation_vector([0.1, 0.2, -0.1])]
  let baseline = encode_goal(q, positions, rotations, [7], [6], 8, 0)
  let yaw = rotation_vector([0.0, 0.0, 0.7])
  let moved_positions = positions.map(fn(p) {
    let rotated = matvec(yaw, p)
    [rotated[0] + 10.0, rotated[1] - 20.0, rotated[2]]
  })
  let moved_rotations = rotations.map(fn(r) { matmul(yaw, r) })
  let moved_state = q.copy()
  let velocity = matvec(yaw, [q[8], q[9], q[10]])
  for i in 0..<3 {
    moved_state[8 + i] = velocity[i]
  }
  let encoded = encode_goal(
    moved_state,
    moved_positions,
    moved_rotations,
    [7],
    [6],
    8,
    0,
  )
  for i in 0..<baseline.length() {
    assert_true((encoded[i] - baseline[i]).abs() < 1.0e-12)
  }
}

///|
test "tracking quality rejects duplicate cells and nonfinite metrics" {
  let t : TrackingTrial = {
    case_id: "stand",
    origin: 0,
    failed: false,
    simulated_seconds: 1.0,
    requested_seconds: 1.0,
    metrics: { "error": 0.01 },
  }
  assert_true(assess_tracking_quality([t], [("stand", 0)], { "error": 0.1 }).0)
  assert_false(assess_tracking_quality([], [("stand", 0)], { "error": 0.1 }).0)
  assert_false(
    assess_tracking_quality([t, t], [("stand", 0)], { "error": 0.1 }).0,
  )
  let failed : TrackingTrial = { ..t, metrics: { "error": 1.0 / 0.0 }, }
  assert_false(
    assess_tracking_quality([failed], [("stand", 0)], { "error": 0.1 }).0,
  )
}
