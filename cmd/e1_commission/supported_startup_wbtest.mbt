///|
test "passive supported startup may restart on a fresh forward gap but armed guard cannot" {
  let (p, _) = decode_status(raw_status(Json::null()), position_only=true)
  let detector = @ankle.Detector::new(p, confirm_isolated=true)
  assert_true(detector.observe(p) is Use)
  let next = {
    ..p,
    seq: p.seq + 2,
    source_ns: p.source_ns + 5800000L,
    arrival_ns: p.arrival_ns + 5800000L,
  }
  assert_true(detector.observe(next) is Stop("packet continuity lost", -1))
  assert_true(supported_startup_rebaseline(false, detector, next))
  assert_false(supported_startup_rebaseline(true, detector, next))
  assert_false(
    supported_startup_rebaseline(false, detector, {
      ..next,
      source_ns: p.source_ns,
    }),
  )
  assert_false(
    supported_startup_rebaseline(false, detector, {
      ..next,
      source_ns: p.source_ns + 41000000L,
    }),
  )
  assert_false(
    supported_startup_rebaseline(false, detector, { ..next, seq: p.seq, }),
  )
}
