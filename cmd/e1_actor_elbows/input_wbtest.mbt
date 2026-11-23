///|
test "captured out-of-range knee is rejected before the first proposal" {
  let packet : @ankle.Packet = {
    seq: 1,
    source_ns: 1000000000L,
    arrival_ns: 2000000000L,
    q: Array::make(24, 0.0),
    qd: Array::make(24, 0.0),
    error: Array::make(24, 0),
  }
  // Exact reading from all 750 live frames on 23 November, SDK motor 19.
  packet.q[19] = -0.00476837158203125
  try hold_detector(packet) catch {
    error =>
      assert_true(
        error
        .to_string()
        .contains("leg feedback outside SDK joint range slot 19"),
      )
  } noraise {
    _ => fail("invalid captured baseline was admitted")
  }
  packet.q[19] = 0.0
  let detector = hold_detector(packet)
  assert_eq(detector.good.seq, packet.seq)
  let next = {
    ..packet,
    seq: 2,
    source_ns: 1002000000L,
    arrival_ns: 2002000000L,
  }
  assert_true(detector.observe(next) is Use)
}
