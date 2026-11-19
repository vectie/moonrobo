///|
fn replay_test_values(t : Transition) -> Array[Double] {
  let values = t.s.copy()
  values.append(t.s1)
  values.append(t.a)
  values.append(t.a_prev)
  values.append(t.xi)
  values.push(t.r)
  values
}

///|
fn replay_test_equal(a : Transition, b : Transition) -> Unit raise {
  let av = replay_test_values(a)
  let bv = replay_test_values(b)
  assert_eq(av.length(), 234)
  for i in 0..<234 {
    assert_eq(av[i].reinterpret_as_int64(), bv[i].reinterpret_as_int64())
  }
  assert_eq(a.frame, b.frame)
  assert_eq(a.ep_step, b.ep_step)
  assert_eq(a.terminated, b.terminated)
  assert_eq(a.truncated, b.truncated)
}

///|
test "compact replay allocates lazy bounded slabs and wraps whole physical rows" {
  let future = ReplayBuffer::new(1000, 4096)
  assert_eq(future.storage_usage().allocated_payload_bytes, 0L)
  assert_eq(future.storage_usage().capacity_payload_bytes, 7708672000L)
  let b = ReplayBuffer::new(350, 3)
  for i in 0..<341 {
    b.add(Array::makei(3, e => stream_transition(i * 3 + e)))
  }
  assert_eq(b.storage_usage().logical_records, 1023L)
  assert_eq(b.storage_usage().allocated_records, 1024L)
  // The next single physical row straddles the 1024-record slab boundary.
  b.add(Array::makei(3, e => stream_transition(341 * 3 + e)))
  assert_eq(b.storage_usage().slab_count, 2)
  assert_eq(b.slabs[1].values.length(), 26 * 234)
  assert_eq(b.storage_usage().allocated_records, 1050L)
  for i in 342..<375 {
    b.add(Array::makei(3, e => stream_transition(i * 3 + e)))
  }
  assert_eq(b.size(), 350)
  assert_eq(b.storage_usage().allocated_payload_bytes, 1050L * 1882L)
  for age in 0..<350 {
    for e in 0..<3 {
      replay_test_equal(
        b.transition(b.record(age, e)),
        stream_transition((age + 25) * 3 + e),
      )
    }
  }
  b.restore([])
  assert_eq(b.storage_usage().allocated_records, 0L)
  assert_eq(b.storage_usage().logical_records, 0L)
}

///|
test "compact replay preserves every float64 bit and never aliases input or samples" {
  let bits = [
    0L,
    (-0.0).reinterpret_as_int64(),
    1L,
    0x7fefffffffffffffL,
    0x7ff0000000000000L,
    0x7ff8000000000042L,
  ]
  let tr = stream_transition(12)
  for values in [tr.s, tr.s1, tr.a, tr.a_prev, tr.xi] {
    for i in 0..<values.length() {
      values[i] = bits[i % bits.length()].reinterpret_as_double()
    }
  }
  let b = ReplayBuffer::new(2, 1)
  b.add([tr])
  let copied = b.sample_windows(1, 1, _ => 0)[0].transitions[0]
  replay_test_equal(copied, tr)
  tr.s[0] = 77.0
  copied.a[0] = 99.0
  let unchanged = b.sample_windows(1, 1, _ => 0)[0].transitions[0]
  assert_eq(unchanged.s[0].reinterpret_as_int64(), 0L)
  assert_eq(unchanged.a[0].reinterpret_as_int64(), 0L)
}

///|
// Frozen object-based oracle from the pre-slab sampling algorithm. The small
// fixture is deliberately independent of the slab addressing helpers.
fn replay_legacy_starts(
  rows : Array[Array[Transition]],
  batch : Int32,
  hist : Int32,
  random_index : (Int32) -> Int32,
  clip_end : (Int32) -> Int32,
  horizon : Int32,
) -> Array[ReplayStart] raise {
  let candidates : Array[(Int32, Int32)] = []
  for age, row in rows {
    for env, tr in row {
      if horizon <= clip_end(tr.frame) - tr.frame {
        candidates.push((age, env))
      }
    }
  }
  Array::makei(batch, _ => {
    let (age, env) = candidates[random_index(candidates.length())]
    let history = [rows[age][env]]
    let mut cursor = age
    let mut active = true
    for _ in 1..<hist {
      let prior = (cursor - 1).max(0)
      let a = rows[prior][env]
      let b = rows[cursor][env]
      active = active &&
        cursor > 0 &&
        !a.done() &&
        b.ep_step == a.ep_step + 1 &&
        b.frame == a.frame + 1
      if active {
        cursor = prior
      }
      history.push(rows[cursor][env])
    }
    { start: rows[age][env], history: history.rev(), }
  })
}

///|
test "compact replay matches old candidate order random draws padding and terminal masks" {
  let b = ReplayBuffer::new(7, 3)
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
    b.add(row)
    if step >= 5 {
      rows.push(row)
    }
  }
  let rng = @numeric.Rng::new(731U)
  let old_rng = @numeric.Rng::new(731U)
  let bounds : Array[Int32] = []
  let old_bounds : Array[Int32] = []
  let ends = frame => frame / 40 * 40 + 26
  let actual = b.sample_starts(
    40,
    10,
    n => {
      bounds.push(n)
      rng.index(n)
    },
    clip_end=ends,
    horizon=4,
  )
  let expected = replay_legacy_starts(
    rows,
    40,
    10,
    n => {
      old_bounds.push(n)
      old_rng.index(n)
    },
    ends,
    4,
  )
  assert_eq(bounds, old_bounds)
  assert_eq(rng.state(), old_rng.state())
  for i in 0..<40 {
    replay_test_equal(actual[i].start, expected[i].start)
    for j in 0..<10 {
      replay_test_equal(actual[i].history[j], expected[i].history[j])
    }
  }
  let window_bounds : Array[Int32] = []
  let windows = b.sample_windows(20, 5, n => {
    window_bounds.push(n)
    rng.index(n)
  })
  for i in 0..<20 {
    let start = old_rng.index(3)
    let env = old_rng.index(3)
    assert_eq(window_bounds[i * 2], 3)
    assert_eq(window_bounds[i * 2 + 1], 3)
    let mut alive = true
    for j in 0..<5 {
      replay_test_equal(windows[i].transitions[j], rows[start + j][env])
      if j > 0 {
        let a = rows[start + j - 1][env]
        let c = rows[start + j][env]
        alive = alive &&
          !a.done() &&
          c.ep_step == a.ep_step + 1 &&
          c.frame == a.frame + 1
      }
      assert_eq(windows[i].mask[j], if alive { 1.0 } else { 0.0 })
    }
  }
  assert_eq(rng.state(), old_rng.state())
}

///|
test "compact replay validates whole row and legacy restore before live commit" {
  let b = ReplayBuffer::new(2, 2)
  b.add([stream_transition(0), stream_transition(1)])
  b.add([stream_transition(2), stream_transition(3)])
  let prior = b.snapshot()
  let bad = { ..stream_transition(7), xi: [], }
  replay_expect_failure(() => b.add([stream_transition(6), bad]))
  assert_eq(Json(b.snapshot()), Json(prior))
  replay_expect_failure(() => {
    b.restore([
      [stream_transition(4), stream_transition(5)],
      [stream_transition(6), bad],
    ])
  })
  assert_eq(Json(b.snapshot()), Json(prior))
  replay_expect_failure(() => b.commit_checkpoint_v2(b))
  let staged = ReplayBuffer::new(2, 2)
  staged.add([stream_transition(50), stream_transition(51)])
  b.commit_checkpoint_v2(staged)
  assert_eq(b.snapshot()[0][0].frame, 50)
  assert_eq(staged.storage_usage().allocated_records, 0L)
  replay_expect_failure(() => {
    staged.add([stream_transition(0), stream_transition(1)])
  })
  replay_expect_failure(() => b.commit_checkpoint_v2(staged))
  assert_eq(b.snapshot()[0][0].frame, 50)
}

///|
fn replay_expect_failure(f : () -> Unit raise) -> Unit raise {
  try f() catch {
    _ => ()
  } noraise {
    _ => fail("expected replay rejection")
  }
}

///|
async test "compact replay v2 crosses slabs preserves encoding and rejects late finite failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-replay-slabs-")
    let second = @fs.tmpdir(prefix="moonrobo-replay-slabs-copy-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    group.add_defer(() => @fs.rmdir(second, recursive=true))
    let b = ReplayBuffer::new(350, 3)
    for i in 0..<370 {
      b.add(Array::makei(3, e => stream_transition(i * 3 + e)))
    }
    let saved = b.write_checkpoint_v2(root)
    let target = ReplayBuffer::new(350, 3)
    target.add([
      stream_transition(1),
      stream_transition(2),
      stream_transition(3),
    ])
    let staged = target.prepare_checkpoint_v2(root, saved, _ => ())
    assert_eq(target.size(), 1)
    assert_eq(staged.storage_usage().slab_count, 2)
    target.commit_checkpoint_v2(staged)
    for age in 0..<350 {
      for e in 0..<3 {
        replay_test_equal(
          target.transition(target.record(age, e)),
          stream_transition((age + 20) * 3 + e),
        )
      }
    }
    let encoded = target.write_checkpoint_v2(second)
    assert_eq(encoded.values.sha256, saved.values.sha256)
    assert_eq(encoded.indices.sha256, saved.indices.sha256)
    assert_eq(encoded.flags.sha256, saved.flags.sha256)
    // A valid-hash archive containing a late NaN must still reject. Live add
    // preserves bits as before; checkpoint finite-value policy is not relaxed.
    @fs.remove(root + "/" + saved.values.file)
    let corrupt = @checkpoint_stream.write_f64le(
      root,
      saved.values.file,
      [350, 3, 234],
      (offset, count) => {
        Array::makei(count, i => {
          let flat = offset.to_int() + i
          if flat == 350 * 3 * 234 - 1 {
            0x7ff8000000000042L.reinterpret_as_double()
          } else {
            b.value(b.chronological_record(flat / 234), flat % 234)
          }
        })
      },
    )
    let old_slabs = target.slabs
    try
      target.prepare_checkpoint_v2(root, { ..saved, values: corrupt, }, _ => ())
    catch {
      _ => ()
    } noraise {
      _ => fail("nonfinite stream replay accepted")
    }
    assert_true(physical_equal(target.slabs, old_slabs))
    assert_eq(target.size(), 350)
    replay_test_equal(
      target.transition(target.record(349, 2)),
      stream_transition(1109),
    )
  }
}
