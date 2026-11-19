///|
test "actor block replay fixes all indices before consuming and matches legacy bits through 4096" {
  let replay = ReplayBuffer::new(7, 3)
  let rows : Array[Array[Transition]] = []
  for step in 0..<12 {
    let row = Array::makei(3, env => {
      let start = env * 40 + (if step < 8 { 0 } else { 20 })
      let episode = if step < 8 { step } else { step - 8 }
      fixture_transition(
        start + episode,
        episode,
        terminated=step == 7 && env == 0,
        truncated=step == 7 && env == 1,
      )
    })
    replay.add(row)
    if step >= 5 {
      rows.push(row)
    }
  }
  let ends = frame => frame / 40 * 40 + 26
  for batch in [1, 256, 257, 4096] {
    let rng = @numeric.Rng::new(731U)
    let old_rng = @numeric.Rng::new(731U)
    let bounds : Array[Int32] = []
    let old_bounds : Array[Int32] = []
    // The independent pre-slab oracle reuses the tiny fixture's Transition
    // objects, so the test itself does not materialize a full 4096*11 graph.
    let expected = replay_legacy_starts(
      rows,
      batch,
      10,
      n => {
        old_bounds.push(n)
        old_rng.index(n)
      },
      ends,
      4,
    )
    let selected_rng_state = old_rng.state()
    let seen = [0]
    let sizes : Array[Int32] = []
    replay.with_sampled_start_blocks(
      batch,
      10,
      n => {
        bounds.push(n)
        rng.index(n)
      },
      starts => {
        assert_eq(bounds, old_bounds)
        assert_eq(bounds.length(), batch)
        if seen[0] == 0 {
          assert_eq(rng.state(), selected_rng_state)
        }
        assert_true(starts.length() > 0 && starts.length() <= 256)
        sizes.push(starts.length())
        for actual in starts {
          let wanted = expected[seen[0]]
          replay_test_equal(actual.start, wanted.start)
          assert_eq(actual.history.length(), 10)
          for j in 0..<10 {
            replay_test_equal(actual.history[j], wanted.history[j])
          }
          // Consumer-side random draws cannot influence later replay indices.
          for _ in 0..<3 {
            assert_eq(
              rng.uniform().reinterpret_as_int64(),
              old_rng.uniform().reinterpret_as_int64(),
            )
          }
          seen[0] += 1
        }
      },
      clip_end=ends,
      horizon=4,
    )
    assert_eq(seen[0], batch)
    assert_eq(sizes.length(), (batch + 255) / 256)
    assert_eq(sizes[sizes.length() - 1], (batch - 1) % 256 + 1)
    assert_eq(rng.state(), old_rng.state())
  }
}

///|
test "actor block replay rejects empty horizon without draws and propagates consumer failure" {
  let replay = ReplayBuffer::new(3, 1)
  for frame in 0..<3 {
    replay.add([fixture_transition(frame, frame)])
  }
  let draws = [0]
  let consumed = [0]
  replay_expect_failure(() => {
    replay.with_sampled_start_blocks(
      4096,
      10,
      _ => {
        draws[0] += 1
        0
      },
      _ => consumed[0] += 1,
      clip_end=_ => 3,
      horizon=4,
    )
  })
  assert_eq(draws[0], 0)
  assert_eq(consumed[0], 0)
  replay_expect_failure(() => {
    replay.with_sampled_start_blocks(
      257,
      10,
      _ => {
        draws[0] += 1
        0
      },
      starts => {
        assert_eq(starts.length(), 256)
        consumed[0] += 1
        fail("consumer stop")
      },
    )
  })
  assert_eq(draws[0], 257)
  assert_eq(consumed[0], 1)
}
