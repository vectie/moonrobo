///|
fn captured_close_spike(i : Int32, spike : Bool) -> Packet {
  let p = post_hold(i, 0)
  let normal = [
    1.5039131737332043, 2.9004985293745107, -1.9102554899954707, 2.3507833061238,
  ]
  let abnormal = [
    3.2457605351034196, -0.09835472404818361, -3.158334113727256, -0.5136302255849589,
  ]
  for j, slot in [9, 10, 20, 21] {
    p.q[slot] = (if spike { abnormal[j] } else { normal[j] }) * @ankle.RAD
  }
  p
}

///|
test "supported repeated single-packet spikes separated by one recovery never become model inputs" {
  for tolerance in [3.0, 5.0] {
    let first = captured_close_spike(0, false)
    let detector = Detector::new(first, confirm_isolated=true)
    assert_true(detector.observe(first) is Use)
    assert_true(detector.observe(captured_close_spike(1, false)) is Use)
    let detector = detector.begin_hold(leg_tolerance_rad=tolerance * @ankle.RAD)
    for i in 2..<=7 {
      let spike = i % 2 == 0
      let p = captured_close_spike(i, spike)
      if spike {
        assert_true(detector.observe(p) is Wait)
        assert_eq(detector.good.seq, p.seq - 1)
      } else {
        assert_true(detector.observe(p) is Use)
        assert_eq(detector.good.seq, p.seq)
      }
      assert_eq(detector.good.q, first.q)
    }
    assert_eq(detector.left_events, 3)
    assert_eq(detector.healthy_streak, 2)
  }
}

///|
test "supported repeated-spike fix still rejects persistence and insufficient initial history" {
  let first = captured_close_spike(0, false)
  let initial = Detector::new(first, confirm_isolated=true)
  assert_true(initial.observe(first) is Use)
  let unarmed = initial.begin_hold(leg_tolerance_rad=5.0 * @ankle.RAD)
  assert_true(
    unarmed.observe(captured_close_spike(1, true))
    is Stop("ankle excursion lacks stationary history", _),
  )
  assert_eq(unarmed.good.seq, first.seq)
  assert_true(initial.observe(captured_close_spike(1, false)) is Use)
  let detector = initial.begin_hold(leg_tolerance_rad=5.0 * @ankle.RAD)
  assert_true(detector.observe(captured_close_spike(2, true)) is Wait)
  assert_true(detector.observe(captured_close_spike(3, false)) is Use)
  assert_true(detector.observe(captured_close_spike(4, true)) is Wait)
  assert_true(detector.observe(captured_close_spike(5, true)) is Stop(_, _))
  assert_eq(detector.good.seq, first.seq + 3)
}

///|
test "confirmed close spikes do not reset the supported baseline or admit sustained drift" {
  let first = captured_close_spike(0, false)
  let detector = Detector::new(first, confirm_isolated=true)
  assert_true(detector.observe(first) is Use)
  assert_true(detector.observe(captured_close_spike(1, false)) is Use)
  let detector = detector.begin_hold(leg_tolerance_rad=5.0 * @ankle.RAD)
  assert_true(detector.observe(captured_close_spike(2, true)) is Wait)
  assert_true(detector.observe(captured_close_spike(3, false)) is Use)
  for i in 4..<=14 {
    let p = captured_close_spike(i, false)
    p.q[9] += (i - 3).to_double() * 0.49 * @ankle.RAD
    if i == 14 {
      assert_true(detector.observe(p) is Stop("gradual ankle drift", 9))
    } else {
      assert_true(detector.observe(p) is Use)
    }
  }
  assert_eq(detector.baseline.q, first.q)
}
