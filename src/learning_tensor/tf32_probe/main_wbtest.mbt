///|
test "probe inputs are bounded and carry fine mantissa bits" {
  for side in 0..<2 {
    for i in 0..<65536 {
      let value = input_value(i, side)
      assert_true(value.abs() < 1.001)
      assert_eq((value * 1048576.0).floor(), value * 1048576.0)
    }
  }
  assert_true(
    input_value(1, 0) * 2048.0 != (input_value(1, 0) * 2048.0).floor(),
  )
}
