///|
fn sample(i : Int32, spike~ : Bool = false) -> Packet {
  let q = Array::make(24, 0.0)
  if spike {
    for (slot, degrees) in [(9, 0.23), (10, -9.22), (20, -0.46), (21, -3.59)] {
      q[slot] = degrees * @ankle.RAD
    }
  }
  {
    seq: 100 + i,
    source_ns: 3000000000L + i.to_int64() * 2850000L,
    arrival_ns: 5000000000L + i.to_int64() * 2850000L,
    q,
    qd: Array::make(24, 0.0),
    error: Array::make(24, 0),
  }
}

///|
fn standing(i : Int32, mask : Int32) -> Packet {
  let p = sample(i)
  for
    bit, (slot, start, delta) in [
      (9, -8.79273, 1.26302),
      (10, 2.22618, -12.13832),
      (20, -5.76529, 1.77640),
      (21, -3.13875, -4.28168),
    ] {
    p.q[slot] = (start + (if (mask & (1 << bit)) == 0 { 0.0 } else { delta })) *
      @ankle.RAD
  }
  p
}

///|
test "only captured standing ankle combinations wait for one confirming packet" {
  for mask in 1..<16 {
    let base = standing(0, 0)
    let d = Detector::new(base)
    assert_true(d.observe(base) is Use)
    let transient = standing(1, mask)
    let v = d.observe(transient)
    if mask is (4 | 12 | 13 | 14 | 15) {
      assert_true(v is Wait)
      assert_eq(d.good.seq, base.seq)
      assert_true(d.observe(standing(2, 0)) is Use)
      assert_eq(d.left_events + d.right_only_events, 1)
    } else {
      assert_true(v is Stop(_, _))
    }
  }
}

///|
test "standing pitch persistence, partial recovery, bad timing and moving encoders latch" {
  for fault in 0..<9 {
    let base = standing(0, 0)
    let d = Detector::new(base)
    assert_true(d.observe(base) is Use)
    let suspect = standing(1, 15)
    if fault == 0 {
      suspect.qd[9] = 1.0
    }
    if fault == 1 {
      suspect.q[8] += 1.1 * @ankle.RAD
    }
    if fault < 2 {
      assert_true(d.observe(suspect) is Stop(_, _))
      continue
    }
    assert_true(d.observe(suspect) is Wait)
    let after = standing(2, 0)
    let result = match fault {
      2 => d.observe(standing(2, 15))
      3 => {
        after.q[9] = suspect.q[9]
        d.observe(after)
      }
      4 => {
        after.q[9] += 0.2 * @ankle.RAD
        d.observe(after)
      }
      5 => {
        after.qd[9] = 1.0
        d.observe(after)
      }
      6 => {
        after.error[9] = 1
        d.observe(after)
      }
      7 => d.observe({ ..after, seq: after.seq + 1, })
      _ => d.observe({ ..after, arrival_ns: after.arrival_ns + 4000000L, })
    }
    assert_true(result is Stop(_, _))
    assert_eq(d.good.seq, base.seq)
    assert_eq(d.left_events, 0)
  }
}

///|
test "starting on the standing transient requires a healthy consecutive nominal sample" {
  let spike = standing(0, 15)
  assert_true(Detector::new(spike).observe(spike) is Stop(_, _))
  assert_true(standing(1, 0).confirms_standing_start(spike))
  assert_false(standing(1, 15).confirms_standing_start(spike))
  assert_false(standing(2, 0).confirms_standing_start(spike))
  let changed = standing(1, 0)
  changed.q[6] += 1.1 * @ankle.RAD
  assert_false(changed.confirms_standing_start(spike))
}

///|
test "a matching spike stays pending until the immediately following sample is validated" {
  for fault in 0..<8 {
    let s = sample(0)
    let d = Detector::new(s)
    assert_true(d.observe(s) is Use)
    let suspect = sample(1, spike=true)
    assert_true(d.observe(suspect) is Wait)
    assert_eq(d.good.seq, s.seq)
    assert_eq(d.left_events, 0)
    let after = sample(2)
    let result = match fault {
      0 => d.observe(after)
      1 => d.observe(sample(2, spike=true))
      2 => d.observe({ ..after, seq: after.seq + 1, })
      3 => d.observe({ ..after, arrival_ns: after.arrival_ns + 4000000L, })
      4 => {
        after.error[10] = 1
        d.observe(after)
      }
      5 => {
        after.q[10] = 0.5 * @ankle.RAD
        d.observe(after)
      }
      6 => d.observe({ ..after, source_ns: suspect.source_ns, })
      _ => {
        after.q[8] = 1.5 * @ankle.RAD
        d.observe(after)
      }
    }
    if fault == 0 {
      assert_true(result is Use)
      assert_eq(d.left_events, 1)
    } else {
      assert_true(result is Stop(_, _))
      assert_eq(d.left_events, 0)
    }
  }
}

///|
test "unmatched ankle steps and steps corroborated by reported speed trip on entry" {
  for fault in 0..<3 {
    let s = sample(0)
    let d = Detector::new(s)
    assert_true(d.observe(s) is Use)
    let p = sample(1, spike=true)
    match fault {
      0 => p.qd[10] = 100.0
      1 => p.q[21] = 0.0
      _ => p.q[10] = 1.5 * @ankle.RAD
    }
    assert_true(d.observe(p) is Stop(_, 10))
  }
}

///|
test "right-only recovery preserves the independent left ankle measurement" {
  let first = sample(0)
  let d = Detector::new(first)
  assert_true(d.observe(first) is Use)
  let r = sample(1, spike=true)
  r.q[9] = 0.0
  r.q[10] = 0.06 * @ankle.RAD
  assert_true(d.observe(r) is Wait)
  let ok = sample(2)
  ok.q[10] = 0.12 * @ankle.RAD
  assert_true(d.observe(ok) is Use)
  assert_eq(d.right_only_events, 1)
  assert_eq(d.good.q[10], ok.q[10])
  let beyond = sample(3)
  beyond.q[10] = 1.05 * @ankle.RAD
  assert_true(d.observe(beyond) is Stop(_, 10))
}

///|
test "a silent or truncated stream cannot confirm a pending spike at a tick" {
  let clip : @elbow.Clip = {
    joint: "l_arm_elbow_pitch_joint",
    step_ms: 20,
    offset_degrees: Array::makei(@elbow.FRAMES, i => {
      -45.0 * (1.0 - @math.cos(2.0 * 3.141592653589793 * i.to_double() / 750.0))
    }),
  }
  let early = Array::makei(8, i => sample(i, spike=i == 7))
  for lost in [false, true] {
    let data = early.copy()
    if !lost {
      let late = sample(8)
      data.push({ ..late, arrival_ns: late.arrival_ns + 10000000L, })
    }
    let result = replay(clip, data, classify=true, track=true)
    assert_eq(result.candidates, 1)
    assert_eq(result.isolated_left, 0)
    guard result.trip is Some(trip) else {
      fail("unconfirmed sample escaped the guard")
    }
    if !lost {
      assert_eq(trip.reason, "confirmation timed out")
      assert_eq(trip.elapsed_ms, 25.95)
    }
  }
}
