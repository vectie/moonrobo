///|
test "control cadence keeps normal slots and waits after a slow tick" {
  let normal = Cadence::new(100L, 20)
  assert_eq(normal.delay(103L), 17)
  assert_eq(normal.delay(122L), 18)
  assert_eq(normal.delay(145L), 15)
  for completed_at in [120L, 121L, 170L] {
    let overrun = Cadence::new(100L, 20)
    assert_eq(overrun.delay(completed_at), 20)
    assert_eq(overrun.delay(completed_at + 21L), 19)
  }
}

///|
test "control cadence rejects invalid periods and clock rollback" {
  for period in [0, -1] {
    try Cadence::new(100L, period) catch {
      _ => ()
    } noraise {
      _ => fail("invalid control period accepted")
    }
  }
  let cadence = Cadence::new(100L, 20)
  ignore(cadence.delay(101L))
  try cadence.delay(100L) catch {
    _ => ()
  } noraise {
    _ => fail("backward host clock accepted")
  }
}
