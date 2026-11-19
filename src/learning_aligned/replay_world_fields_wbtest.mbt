///|
test "packed world replay matches wrapped slabs decoded windows masks and RNG bits" {
  let replay = ReplayBuffer::new(350, 3)
  for step in 0..<400 {
    replay.add(
      Array::makei(3, env => {
        let tr = stream_transition(step * 3 + env)
        {
          ..tr,
          frame: step,
          ep_step: step,
          terminated: step % 19 == env,
          truncated: step % 23 == env,
        }
      }),
    )
  }
  for batch in [1, 256, 257, 2048] {
    let a = @numeric.Rng::new(0x12345678U)
    let b = @numeric.Rng::new(0x12345678U)
    let actual = replay.sample_world_fields(
      batch,
      8,
      n => b.index(n),
      max_values=batch.to_int64() * 8L * 205L,
    )
    for begin = 0; begin < batch; {
      let count = (batch - begin).min(256)
      let windows = replay.sample_windows(count, 8, n => a.index(n))
      for i, window in windows {
        for j, tr in window.transitions {
          let row = (begin + i) * 8 + j
          for
            (field, expected, width) in [
              (actual.s, tr.s, 71),
              (actual.s1, tr.s1, 71),
              (actual.actions, tr.a, 29),
              (actual.xi, tr.xi, 33),
            ] {
            for k in 0..<width {
              assert_eq(
                field[row * width + k].reinterpret_as_int64(),
                expected[k].reinterpret_as_int64(),
              )
            }
          }
          assert_eq(actual.mask[row], window.mask[j])
        }
      }
      continue begin + count
    }
    assert_eq(a.state(), b.state())
  }
  let draws = [0]
  for
    (batch, width, cap) in [
      (0, 8, 1L),
      (1, 0, 1L),
      (2048, 8, 3358719L),
      (2147483647, 2147483647, 9223372036854775807L),
    ] {
    assert_true(
      (try? replay.sample_world_fields(
        batch,
        width,
        _ => {
          draws[0] += 1
          0
        },
        max_values=cap,
      ))
      is Err(_),
    )
  }
  assert_eq(draws[0], 0)
}
