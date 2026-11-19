///|
test "preselected preview states retain layout duplicate padding and signed zero" {
  let current : @learning_aligned.State = {
    p: [0.0, 0.0, 0.0],
    rotation: @learning_aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: Array::make(29, 0.0),
    qd: Array::make(29, 0.0),
  }
  let future = {
    ..current,
    p: [0.4, -0.2, 0.8],
    v: [0.1, 0.2, 0.3],
    w: [0.4, 0.5, 0.6],
    q: Array::make(29, 0.02),
    qd: Array::make(29, -0.0),
  }
  let output = @learning_aligned.goal_from_states(current, [future, future])
  assert_eq(output.length(), 146)
  assert_eq(output[0:3].to_owned(), future.p)
  assert_eq(output[9:12].to_owned(), future.v)
  assert_eq(output[12:15].to_owned(), future.w)
  assert_eq(output[15:44].to_owned(), future.q)
  for i in 0..<73 {
    assert_eq(
      output[i].reinterpret_as_int64(),
      output[i + 73].reinterpret_as_int64(),
    )
  }
  for i in 44..<73 {
    assert_eq(output[i].reinterpret_as_int64(), (-0.0).reinterpret_as_int64())
  }
  assert_eq(@learning_aligned.goal_from_states(current, []), [])
}
