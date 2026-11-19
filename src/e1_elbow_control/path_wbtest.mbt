///|
fn fixture_clip() -> Clip {
  {
    joint: "l_arm_elbow_pitch_joint",
    step_ms: 20,
    offset_degrees: Array::makei(FRAMES, i => {
      -45.0 * (1.0 - @math.cos(2.0 * 3.141592653589793 * i.to_double() / 750.0))
    }),
  }
}

///|
fn hold_fixture() -> Array[@low.MotorCommand] {
  Array::makei(24, i => {
    let tag = i.to_double() + 1.0
    {
      position: -0.01 * tag,
      velocity: 0.0,
      torque: 0.02 * tag,
      kp: tag,
      kd: tag / 4.0,
    }
  })
}

///|
fn sample(tick : Int32, hold : Array[@low.MotorCommand]) -> Sample {
  {
    source_ns: 3000000000L + tick.to_int64() * 20000000L,
    receipt_ms: 5000L + tick.to_int64() * 20L,
    motors: Array::makei(24, i => {
      id: i,
      error: 0,
      position: hold[i].position,
      velocity: 0.0,
    }),
  }
}

///|
fn rejected(f : () -> Unit raise) -> Bool {
  try {
    f()
    false
  } catch {
    _ => true
  }
}

///|
test "all 751 frames change only the named elbow position, including ownership of mutable inputs/outputs" {
  let hold = hold_fixture()
  let initial_hold = hold.copy()
  let clip = fixture_clip()
  let path = Path::new(clip, hold[:])
  let mut last = initial_hold[ELBOW_SLOT].position
  // Neither a caller edit nor a corrupted reference may mutate an established path.
  hold[6] = { ..hold[6], position: 10.0, }
  let degrees = clip.offset_degrees.copy()
  clip.offset_degrees[375] = 99.0
  for i in 0..<FRAMES {
    let s = sample(i, initial_hold)
    s.motors[ELBOW_SLOT] = { ..s.motors[ELBOW_SLOT], position: last, }
    let commands = path.next(s, s.receipt_ms)
    assert_eq(commands.length(), 24)
    for j, m in commands {
      let h = initial_hold[j]
      assert_eq(
        (m.velocity, m.torque, m.kp, m.kd),
        (h.velocity, h.torque, h.kp, h.kd),
      )
      let expected = if j == ELBOW_SLOT {
        h.position + degrees[i] * RAD
      } else {
        h.position
      }
      assert_eq(m.position, expected)
    }
    last = commands[ELBOW_SLOT].position
    commands[8] = { ..commands[8], position: 99.0, }
  }
  assert_eq(last, initial_hold[ELBOW_SLOT].position)
  let s = sample(FRAMES, initial_hold)
  assert_true(rejected(() => ignore(path.next(s, s.receipt_ms))))
}

///|
test "incomplete hold, wrong joint, corrupted reference, unreachable fold or invalid hold field fail before startup" {
  let h = hold_fixture()
  let c = fixture_clip()
  assert_true(rejected(() => ignore(Path::new(c, h[:23]))))
  assert_true(
    rejected(() => {
      ignore(Path::new({ ..c, joint: "r_arm_elbow_pitch_joint", }, h[:]))
    }),
  )
  for i in [0, 23, 375, 750] {
    let offsets = c.offset_degrees.copy()
    offsets[i] = -40.0
    assert_true(
      rejected(() => ignore(Path::new({ ..c, offset_degrees: offsets, }, h[:]))),
    )
  }
  for
    invalid in [
      { ..h[3], position: -1.5, },
      { ..h[3], position: 0.01, },
      { ..h[3], kp: 0.0, },
      { ..h[3], kd: -1.0, },
      { ..h[3], torque: 0.0 / 0.0, },
      { ..h[3], velocity: 0.4, },
    ] {
    h[3] = invalid
    assert_true(rejected(() => ignore(Path::new(c, h[:]))))
  }
}

///|
test "stale, missing, duplicate, erroneous and mismatched joint input latches before another candidate" {
  let h = hold_fixture()
  let c = fixture_clip()
  let first = sample(0, h)
  for fault in 0..<12 {
    let path = Path::new(c, h[:])
    ignore(path.next(first, first.receipt_ms))
    let s = sample(1, h)
    let mut now = s.receipt_ms
    let bad = match fault {
      0 => { ..s, source_ns: first.source_ns, }
      1 => { ..s, source_ns: first.source_ns + 50000000L, }
      2 => { ..s, receipt_ms: first.receipt_ms, }
      3 => {
        now += 41L
        s
      }
      4 => {
        now -= 1L
        s
      }
      5 => { ..s, motors: s.motors[:23].to_owned(), }
      6 => {
        s.motors[23] = { ..s.motors[23], id: 22, }
        s
      }
      7 => {
        s.motors[17] = { ..s.motors[17], error: 1, }
        s
      }
      8 => {
        s.motors[10] = {
          ..s.motors[10],
          position: s.motors[10].position + 2.0 * RAD,
        }
        s
      }
      9 => {
        s.motors[3] = { ..s.motors[3], position: -0.5, }
        s
      }
      10 => {
        s.motors[6] = { ..s.motors[6], velocity: 0.0 / 0.0, }
        s
      }
      _ => {
        now += 11L
        s
      }
    }
    assert_true(rejected(() => ignore(path.next(bad, now))))
    let good = sample(2, h)
    assert_true(rejected(() => ignore(path.next(good, good.receipt_ms))))
  }
  let path = Path::new(c, h[:])
  path.cancel()
  assert_true(rejected(() => ignore(path.next(first, first.receipt_ms))))
}

///|
test "candidate cannot start from a hold that already requests changing a leg" {
  let h = hold_fixture()
  let initial = sample(0, h)
  h[8] = { ..h[8], position: h[8].position + 0.1, }
  let path = Path::new(fixture_clip(), h[:])
  assert_true(rejected(() => ignore(path.next(initial, initial.receipt_ms))))
}
