///|
test "measured teaching take checks the cue, elbow, other arm and legs through the tail" {
  let angle = (phase : Double) => {
    -45.0 * (1.0 - @math.cos(2.0 * @math.PI * phase))
  }
  let clip : @elbow.Clip = {
    joint: "l_arm_elbow_pitch_joint",
    step_ms: 20,
    offset_degrees: Array::makei(751, i => angle(i.to_double() / 750.0)),
  }
  let packets : Array[@ankle.Packet] = Array::makei(3005, i => {
    let q = Array::make(24, 0.0)
    q[3] = -0.03 +
      angle((i - 2).clamp(min=0, max=3000).to_double() / 3000.0) * @ankle.RAD
    if i == 145 {
      for (slot, deg) in [(9, 0.23), (10, -9.22), (20, -0.46), (21, -3.59)] {
        q[slot] = deg * @ankle.RAD
      }
    }
    {
      seq: 1000 + i,
      arrival_ns: 1000000000L + i.to_int64() * 5000000L,
      source_ns: 8000000000L + i.to_int64() * 5000000L,
      q,
      qd: Array::make(24, 0.0),
      error: Array::make(24, 0),
    }
  })
  let verify = () => check_teach(clip, packets, 1002).0
  assert_true(verify())
  for (sample, slot) in [(0, 11), (145, 1), (1500, 3), (2500, 8), (3004, 23)] {
    let old = packets[sample].q[slot]
    packets[sample].q[slot] = old + 0.25
    assert_false(verify())
    packets[sample].q[slot] = old
  }
  assert_false(check_teach(clip, packets[:3002].to_owned(), 1002).0)
  assert_false(check_teach(clip, packets, 1600).0)
}
