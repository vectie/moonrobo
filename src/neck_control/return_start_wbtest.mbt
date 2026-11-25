///|
test "explicit return is receipt-bound and never bypasses bounded trajectory" {
  let action = ReturnToStart(1948, 2056)
  assert_eq(target(action, 7, 1927), 1948)
  assert_eq(target(action, 8, 2371), 2056)
  let bus = SimBus::new()
  bus.registers[8][56] = (2371 & 255).to_byte()
  bus.registers[8][57] = (2371 >> 8).to_byte()
  let report = run_action(bus, action)
  assert_true(report.completed && report.holding)
  assert_eq(report.after.map(f => f.position), [1948, 2056])
  for invalid in [ReturnToStart(1585, 2056), ReturnToStart(1948, 2389)] {
    let denied = SimBus::new()
    expect_denied(() => run_action(denied, invalid) |> ignore)
    assert_eq(denied.writes.length(), 0)
  }
  assert_true(intent_parameters(action) != intent_parameters(Sweep(30)))
  assert_true(
    intent_parameters(action) != intent_parameters(ReturnToStart(1949, 2056)),
  )
}
