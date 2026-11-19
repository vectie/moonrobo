///|
test "gentle clip uses the reviewed slot fields and trips when a stationary elbow fails to follow" {
  let clip = @e1_elbow_control.Clip::gentle()
  clip.validate()
  assert_eq(clip.tracking_tolerance_deg(), 1.0)
  assert_eq(clip.offset_degrees[375], -5.0)
  let s : @e1_elbow_control.Sample = {
    source_ns: 1L,
    receipt_ms: 0L,
    motors: Array::makei(24, i => {
      id: i,
      error: 0,
      velocity: 0.0,
      position: if i == 23 {
        12.5
      } else {
        -0.03
      },
    }),
  }
  let hold = s.stand_candidate()
  for i, m in hold {
    assert_eq(m.position, if i == 23 { 0.0 } else { -0.03 })
    assert_eq((m.velocity, m.torque), (0.0, 0.0))
    assert_eq(m.kp, if i == 23 { 0.0 } else { 50.0 })
    assert_eq(m.kd, if [9, 10, 20, 21].contains(i) { 1.0 } else { 5.0 })
  }
  let path = @e1_elbow_control.Path::new(clip, hold[:])
  let mut stop = -1
  for i in 0..<751 {
    let now = i.to_int64() * 20L
    let sample = { ..s, source_ns: now * 1000000L + 1L, receipt_ms: now, }
    ignore(path.next(sample, now)) catch {
      err => {
        assert_true(err.to_string().contains("elbow following error"))
        stop = i
        break
      }
    }
  }
  assert_true(stop > 0 && stop < 375)
}
