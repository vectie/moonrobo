///|
/// Whitebox translation of the original full-observer constant-memory assertion.
/// No production introspection API is introduced just for testing.
test "full observer retains exactly two raw frames after arbitrarily long input" {
  let geometry : Kinematics = {
    nu: 1,
    bodies: [
      {
        parent: -1,
        position: [0.0, 0.0, 0.0],
        quaternion_wxyz: [1.0, 0.0, 0.0, 0.0],
        com_position: [0.03, 0.04, -0.04],
        mass: 2.0,
        joints: [],
      },
    ],
    feet: [
      { body: 0, position: [0.0, 0.1, -0.8], },
      { body: 0, position: [0.0, -0.1, -0.8], },
    ],
  }
  let observer = BalanceHistory::full_memory(geometry, 0.02)
  for i in 0..<80 {
    let a = i.to_double() * 0.02
    ignore(
      observer.observe([
        0.3 + 0.1 * @math.sin(0.2 * i.to_double()),
        0.0,
        @math.sin(a),
        0.0,
        -@math.cos(a),
        0.0,
        1.0,
        0.0,
        0.0,
      ]),
    )
  }
  assert_eq(observer.errors.length(), 2)
  assert_eq(observer.gravity.length(), 2)
  assert_eq(observer.omega.length(), 2)
}
