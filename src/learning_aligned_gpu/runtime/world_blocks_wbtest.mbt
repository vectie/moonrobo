///|
// Independent bounded CPU oracle of the original full-host-array assembly.
fn legacy_world_batch(
  backend : @tensor.Backend,
  windows : Array[@aligned.ReplayWindow],
  dtype : @tensor.DType,
) -> @gpu.WorldBatch raise {
  let batch = windows.length()
  let width = windows[0].transitions.length()
  let s : Array[Double] = []
  let s1 : Array[Double] = []
  let actions : Array[Double] = []
  let xi : Array[Double] = []
  let mask : Array[Double] = []
  for window in windows {
    for tr in window.transitions {
      s.append(tr.s)
      s1.append(tr.s1)
      actions.append(tr.a)
      xi.append(tr.xi)
    }
    mask.append(window.mask)
  }
  {
    s: upload(backend, s, [batch, width, 71], -1, dtype),
    s1: upload(backend, s1, [batch, width, 71], -1, dtype),
    actions: upload(backend, actions, [batch, width, 29], -1, dtype),
    xi: upload(backend, xi, [batch, width, 33], -1, dtype),
    mask: upload(backend, mask, [batch, width], -1, dtype),
  }
}

///|
fn same_world(a : @gpu.WorldBatch, b : @gpu.WorldBatch) -> Unit raise {
  same_tensor(a.s, b.s)
  same_tensor(a.s1, b.s1)
  same_tensor(a.actions, b.actions)
  same_tensor(a.xi, b.xi)
  same_tensor(a.mask, b.mask)
}

///|
test "world 256 plus tail sampling retains masks tensor bits and RNG on wrapped replay" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP world block parity: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (_, motion, base) = fixture()
  let replay = @aligned.ReplayBuffer::new(6, 2)
  for i, frame in [0, 1, 2, 6, 7, 8, 10, 11] {
    let tr = transition(motion, frame, i, done=i == 4)
    replay.add([
      {
        ..tr,
        a: Array::makei(29, j => {
          if j == 0 {
            -0.0
          } else {
            j.to_double() * 0.002
          }
        }),
      },
      { ..tr, a: Array::make(29, 0.04), },
    ])
  }
  for dtype in [@tensor.Float32, @tensor.Float64] {
    for count in [1, 257] {
      let c = { ..base, wm_batch: count, wm_window: 4, }
      let old_rng = @numeric.Rng::new(0x5a3f1234U)
      let new_rng = @numeric.Rng::new(0x5a3f1234U)
      let windows = replay.sample_windows(count, 4, n => old_rng.index(n))
      let expected = legacy_world_batch(backend, windows, dtype)
      let actual = sample_world_batch(backend, replay, c, new_rng, dtype~)
      same_world(actual, expected)
      same_world(world_batch_from_windows(backend, windows, dtype~), expected)
      assert_eq(new_rng.state(), old_rng.state())
      for _ in 0..<16 {
        bit_equal([new_rng.uniform()], [old_rng.uniform()])
      }
      assert_true(expected.mask.values().contains(0.0))
    }
  }
}
