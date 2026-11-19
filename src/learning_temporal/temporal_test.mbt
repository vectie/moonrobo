///|
test "history is causal and restarts after gaps" {
  let rows = [[1.0], [2.0], [3.0], [4.0]]
  let h = causal_history(rows, [0.0, 0.02, 0.1, 0.12], 3, 0.02)
  assert_eq(h[0], [[1.0], [1.0], [1.0]])
  assert_eq(h[1], [[1.0], [1.0], [2.0]])
  assert_eq(h[2], [[3.0], [3.0], [3.0]])
  assert_eq(h[3], [[3.0], [3.0], [4.0]])
}

///|
test "previews use future command times" {
  let rows = preview_goals(fn(t) { [t, t * t] }, 1.0, 0.02, 10)
  assert_eq(rows.length(), 10)
  assert_true((rows[0][0] - 1.02).abs() < 1.0e-14)
  assert_true((rows[9][0] - 1.2).abs() < 1.0e-14)
}

///|
test "discounted visitation includes preceding continuation only" {
  let weights = discounted_visitation([0.5, 0.25, 0.0], 0.9)
  assert_eq(weights[0], 1.0)
  assert_eq(weights[1], 0.45)
  assert_true((weights[2] - 0.10125).abs() < 1.0e-14)
}
