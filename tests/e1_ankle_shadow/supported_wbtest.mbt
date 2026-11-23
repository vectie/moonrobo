///|
test "explicit supported leg tolerance leaves default and nonleg guards unchanged" {
  for supported in [false, true] {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    assert_true(d.observe(post_hold(1, 0)) is Use)
    let d = d.begin_hold(
      leg_tolerance_rad=if supported { 3.0 * @ankle.RAD } else { @ankle.RAD },
    )
    let below = post_hold(2, 0)
    below.q[7] -= 2.5 * @ankle.RAD
    if supported {
      assert_true(d.observe(below) is Use)
      let beyond = post_hold(3, 0)
      beyond.q[7] -= 3.1 * @ankle.RAD
      assert_true(
        d.observe(beyond) is Stop("stationary joint outside tolerance", 7),
      )
    } else {
      assert_true(
        d.observe(below) is Stop("stationary joint outside tolerance", 7),
      )
    }
  }
  let first = post_hold(0, 0)
  let d = Detector::new(first, confirm_isolated=true)
  assert_true(d.observe(first) is Use)
  let d = d.begin_hold(leg_tolerance_rad=3.0 * @ankle.RAD)
  let arm = post_hold(1, 0)
  arm.q[1] += 1.1 * @ankle.RAD
  assert_true(d.observe(arm) is Stop("stationary joint outside tolerance", 1))
}

///|
test "supported envelope still quarantines sub-three-degree ankle glitches" {
  for mask in 1..<16 {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    assert_true(d.observe(post_hold(1, 0)) is Use)
    let d = d.begin_hold(leg_tolerance_rad=3.0 * @ankle.RAD)
    assert_true(d.observe(post_hold(2, mask)) is Wait)
    assert_true(d.observe(post_hold(3, 0)) is Use)
    assert_eq(d.left_events + d.right_only_events, 1)
  }
}

///|
test "explicit five-degree stationary profile accepts four degrees and stops beyond five" {
  for slot in [1, 7, 12, 18, 22] {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    let d = d.begin_hold(
      leg_tolerance_rad=5.0 * @ankle.RAD,
      stationary_tolerance_rad=5.0 * @ankle.RAD,
    )
    let within = post_hold(1, 0)
    within.q[slot] -= 4.5 * @ankle.RAD
    assert_true(d.observe(within) is Use)
    let beyond = post_hold(2, 0)
    beyond.q[slot] -= 5.1 * @ankle.RAD
    assert_true(
      d.observe(beyond) is Stop("stationary joint outside tolerance", _),
    )
  }
}
