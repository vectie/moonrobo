///|
fn reboot_standing(i : Int32, mask : Int32) -> Packet {
  let p = sample(i)
  for
    bit, (slot, nominal, alternate) in [
      (9, -9.209261566, -8.010555142),
      (10, 2.109822671, -10.261840134),
      (20, -6.566201157, -4.928719147),
      (21, -2.895199770, -8.076124958),
    ] {
    p.q[slot] = (if (mask & (1 << bit)) == 0 { nominal } else { alternate }) *
      @ankle.RAD
  }
  p
}

///|
test "reboot ankle component combinations require one confirming packet" {
  for mask in 1..<16 {
    let opening = reboot_standing(0, mask)
    assert_true(opening.starts_on_standing_spike())
    assert_true(Detector::new(opening).observe(opening) is Stop(_, _))
    assert_true(reboot_standing(1, 0).confirms_standing_start(opening))
    let first = reboot_standing(0, 0)
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    let result = d.observe(reboot_standing(1, mask))
    assert_true(result is Wait)
    assert_eq(d.good.seq, first.seq)
    assert_true(d.pending is Some(_))
    assert_eq(d.left_events + d.right_only_events, 0)
    assert_true(d.observe(reboot_standing(2, 0)) is Use)
    assert_true(d.pending is None)
    assert_eq(d.left_events + d.right_only_events, 1)
    assert_eq(d.max_confirmation_ns, 2850000L)
    let sustained = Detector::new(first)
    assert_true(sustained.observe(first) is Use)
    assert_true(sustained.observe(reboot_standing(1, mask)) is Wait)
    assert_true(
      sustained.observe(reboot_standing(2, mask))
      is Stop("ankle excursion persisted", _),
    )
  }
}

///|
test "reboot signature persistence or invalid recovery stops before another target" {
  for fault in 0..<12 {
    let first = reboot_standing(0, 0)
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    let suspect = reboot_standing(1, 15)
    assert_true(d.observe(suspect) is Wait)
    let after = reboot_standing(2, 0)
    let result = match fault {
      0 => d.observe(reboot_standing(2, 15))
      1 => d.observe(reboot_standing(2, 4))
      2 => {
        after.q[9] += 0.2 * @ankle.RAD
        d.observe(after)
      }
      3 => {
        after.q[8] += 1.1 * @ankle.RAD
        d.observe(after)
      }
      4 => {
        after.qd[9] = 1.0
        d.observe(after)
      }
      5 => {
        after.error[9] = 1
        d.observe(after)
      }
      6 => d.observe({ ..after, seq: after.seq + 1, })
      7 => d.observe({ ..after, arrival_ns: suspect.arrival_ns + 6000001L, })
      8 => d.observe({ ..after, source_ns: suspect.source_ns + 6000001L, })
      9 => d.observe({ ..after, source_ns: suspect.source_ns, })
      10 => d.observe(standing(2, 0))
      _ => {
        after.q[0] += 1.1 * @ankle.RAD
        d.observe(after)
      }
    }
    assert_true(result is Stop(_, _))
    assert_eq(d.good.seq, first.seq)
    assert_eq(d.left_events + d.right_only_events, 0)
  }
}

///|
test "reboot alternate quantization clears but cannot conceal two-packet drift" {
  for persist in [false, true] {
    let first = reboot_standing(0, 0)
    first.q[20] += 0.0112022843 * @ankle.RAD
    first.q[21] -= 0.0198906869 * @ankle.RAD
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    let suspect = reboot_standing(1, 15)
    suspect.q[20] += 0.0218566053 * @ankle.RAD
    assert_true(d.observe(suspect) is Wait)
    let after = if persist {
      reboot_standing(2, 15)
    } else {
      reboot_standing(2, 0)
    }
    if persist {
      after.q[20] += 0.0218566053 * @ankle.RAD
      assert_true(d.observe(after) is Stop("ankle excursion persisted", _))
    } else {
      after.q[20] = first.q[20]
      after.q[21] = first.q[21]
      assert_true(d.observe(after) is Use)
      assert_eq(d.left_events, 1)
    }
  }
}

///|
test "reboot gradual drift uses the original baseline and stops above one degree" {
  for slot in [5, 8, 9, 10, 16, 19, 20, 21] {
    let first = reboot_standing(0, 0)
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    for i in 1..<=9 {
      let p = reboot_standing(i, 0)
      p.q[slot] += i.to_double() * 0.1 * @ankle.RAD
      assert_true(d.observe(p) is Use)
    }
    let over = reboot_standing(10, 0)
    over.q[slot] += 1.01 * @ankle.RAD
    guard d.observe(over) is Stop(_, actual) else {
      fail("sustained drift escaped")
    }
    assert_eq(actual, slot)
    assert_eq(d.good.seq, first.seq + 9)
  }
}

///|
test "reboot startup cannot mix poses or accept motion corroborated by velocity" {
  let spike = reboot_standing(0, 15)
  assert_true(spike.starts_on_standing_spike())
  assert_true(Detector::new(spike).observe(spike) is Stop(_, _))
  assert_true(reboot_standing(1, 0).confirms_standing_start(spike))
  assert_false(standing(1, 0).confirms_standing_start(spike))
  assert_false(reboot_standing(1, 0).confirms_standing_start(standing(0, 15)))
  assert_false(reboot_standing(2, 0).confirms_standing_start(spike))
  for slot in [9, 10, 20, 21] {
    let first = reboot_standing(0, 0)
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    let moving = reboot_standing(1, 15)
    moving.qd[slot] = 1.0
    assert_true(d.observe(moving) is Stop(_, _))
  }
  let first = reboot_standing(0, 0)
  let d = Detector::new(first)
  assert_true(d.observe(first) is Use)
  let unknown = reboot_standing(1, 15)
  unknown.q[9] += 0.2 * @ankle.RAD
  assert_true(d.observe(unknown) is Stop(_, _))
}

///|
test "reboot recognition follows a shifted good pose without rebasing the drift guard" {
  for persist in [false, true] {
    let first = reboot_standing(0, 0)
    first.q[20] += 0.056028579 * @ankle.RAD
    first.q[21] -= 0.099423990 * @ankle.RAD
    let d = Detector::new(first)
    assert_true(d.observe(first) is Use)
    let transient = reboot_standing(1, 12)
    transient.q[20] += 0.109283027 * @ankle.RAD
    assert_true(d.observe(transient) is Wait)
    let after = reboot_standing(2, 0)
    after.q[20] = if persist { transient.q[20] } else { first.q[20] }
    after.q[21] = if persist { transient.q[21] } else { first.q[21] }
    if persist {
      assert_true(d.observe(after) is Stop("ankle excursion persisted", _))
    } else {
      assert_true(d.observe(after) is Use)
      assert_eq(d.right_only_events, 1)
      assert_eq(d.baseline.q[20], first.q[20])
    }
  }
}
