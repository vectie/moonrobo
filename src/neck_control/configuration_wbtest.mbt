///|
test "factory diagnostic reads both identities and never writes" {
  let bus = SimBus::new()
  bus.registers[7][83] = 2
  let result = configuration_snapshot(bus)
  assert_true(
    result
    is {
      "read_only": true,
      "motors": [{ "id": 7, "minimum_speed_limit": 2, .. }, { "id": 8, .. }],
      ..
    },
  )
  assert_eq(bus.writes.length(), 0)
  assert_eq(bus.registers[7][40], 0)
  assert_eq(bus.registers[8][40], 0)
}

///|
test "factory diagnostic rejects a changed identity without writing" {
  let bus = SimBus::new()
  bus.registers[7][18] = 8
  expect_denied(() => configuration_snapshot(bus) |> ignore)
  assert_eq(bus.writes.length(), 0)
}
