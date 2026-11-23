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

///|
fn stationary_packet(seq : Int32) -> @ankle.Packet {
  let q = Array::make(24, 0.0)
  q[19] = -0.00476837158203125
  {
    seq,
    source_ns: 1000000000L + seq.to_int64() * 2000000L,
    arrival_ns: 2000000000L + seq.to_int64() * 2000000L,
    q,
    qd: Array::make(24, 0.0),
    error: Array::make(24, 0),
  }
}

///|
fn stationary_history() -> @ankle.Detector raise {
  let previous = @ankle.Detector::new(
    stationary_packet(1),
    confirm_isolated=true,
  )
  for seq in 1..<4 {
    assert_true(previous.observe(stationary_packet(seq)) is Use)
  }
  previous
}

///|
test "shadow preserves raw knee and validated history while powered admission rejects it" {
  let packet = stationary_packet(3)
  let previous = stationary_history()
  let shadow = assessed_hold(previous, packet, true, None)
  assert_eq(shadow.baseline.q[19], packet.q[19])
  assert_false(shadow.suspended)
  assert_eq(shadow.healthy_streak, previous.healthy_streak)
  assert_eq(nominal_leg_range_discrepancies(packet), [19])
  assert_true(shadow.observe(stationary_packet(4)) is Use)
  try assessed_hold(previous, packet, false, None) catch {
    error =>
      assert_true(
        error
        .to_string()
        .contains("leg feedback outside SDK joint range slot 19"),
      )
  } noraise {
    _ => fail("shadow assessment bypassed powered admission")
  }
}

///|
test "shadow still stops gradual knee drift against the unchanged relative limit" {
  let shadow = assessed_hold(
    stationary_history(),
    stationary_packet(3),
    true,
    None,
  )
  for seq, degrees in [0.5, 0.9] {
    let packet = stationary_packet(seq + 4)
    packet.q[19] += degrees * @ankle.RAD
    assert_true(shadow.observe(packet) is Use)
  }
  let drift = stationary_packet(6)
  drift.q[19] += 1.1 * @ankle.RAD
  assert_true(
    shadow.observe(drift) is Stop("stationary joint outside tolerance", 19),
  )
}

///|
test "shadow confirms isolated ankle recovery but rejects a sustained excursion" {
  let recovered = assessed_hold(
    stationary_history(),
    stationary_packet(3),
    true,
    None,
  )
  let sustained = assessed_hold(
    stationary_history(),
    stationary_packet(3),
    true,
    None,
  )
  let spike = stationary_packet(4)
  spike.q[10] -= 9.22 * @ankle.RAD
  assert_true(recovered.observe(spike) is Wait)
  assert_true(recovered.observe(stationary_packet(5)) is Use)
  assert_eq(recovered.good.q[19], stationary_packet(3).q[19])
  assert_true(sustained.observe(spike) is Wait)
  let held = stationary_packet(5)
  held.q[10] = spike.q[10]
  assert_true(sustained.observe(held) is Stop("ankle excursion persisted", 10))
}

///|
test "explicit current-pose commissioning permits elbows and still stops leg drift" {
  let profile : @adapter.CurrentPoseProfile = {
    format: "moonrobo.e1-current-pose-commissioning.v1",
    scope: "unchanged-raw-hold-and-elbows-only",
    expected_knee_raw_rad: -0.00476837158203125,
    evidence_sha256: "30871a26b526f56dd82d308a2449df00731836d3792b6af934393209fbb03113",
  }
  let hold = assessed_hold(
    stationary_history(),
    stationary_packet(3),
    false,
    Some(profile),
  )
  assert_false(hold.suspended)
  assert_true(hold.moving_right_elbow)
  assert_eq(hold.baseline.q[19], profile.expected_knee_raw_rad)
  let arms = stationary_packet(4)
  arms.q[3] = -0.1
  arms.q[14] = -0.1
  assert_true(hold.observe(arms) is Use)
  let drift = stationary_packet(5)
  drift.q[19] += 1.1 * @ankle.RAD
  assert_true(
    hold.observe(drift) is Stop("stationary joint outside tolerance", 19),
  )
  let changed = stationary_packet(3)
  changed.q[19] = 0.0
  try profile.validate_baseline(changed.q[:]) catch {
    _ => ()
  } noraise {
    _ => fail("changed measured knee was silently admitted")
  }
  let other = stationary_packet(3)
  other.q[8] = -0.01
  try profile.validate_baseline(other.q[:]) catch {
    _ => ()
  } noraise {
    _ => fail("exception expanded to a different leg")
  }
}

///|
test "takeover hip settling cannot pass as an isolated ankle glitch" {
  let detector = stationary_history().begin_hold(moving_right_elbow=true)
  // Measured left-hip offsets from the stopped 23 November powered hold.
  // The default stationary limit must stop the first over-limit hip sample;
  // neither the elbow exemption nor ankle recovery logic can postpone it.
  let offsets = [
    0.0, -0.04371321068808161, -0.17485284275232643, -0.32784908016061204, -0.43713210688081605,
    -0.5901283442891017, -0.7649811870414281, -0.9179774244497138, -1.0491170565139585,
  ]
  for index, degrees in offsets {
    let packet = stationary_packet(index + 4)
    packet.q[7] = degrees * @ankle.RAD
    packet.qd[7] = -14.355418389966 * @ankle.RAD
    if index < offsets.length() - 1 {
      assert_true(detector.observe(packet) is Use)
    } else {
      assert_true(
        detector.observe(packet)
        is Stop("stationary joint outside tolerance", 7),
      )
    }
  }
}
