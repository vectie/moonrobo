///|
test "sampled actor history uses the collector's embodiment posture" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let backend = @tensor.Backend::open(path)
  let (motion, replay, base) = block_fixture()
  let cfg = { ..base, policy_batch: 2, observation_noise: false, }
  let pose = Array::makei(29, i => if i < 23 { 0.2 } else { 0.0 })
  let rng = @numeric.Rng::new(7U)
  let starts = replay.sample_starts(
    2,
    cfg.hist,
    n => rng.index(n),
    clip_end=f => motion.clip_end[motion.clip_id[f]],
    horizon=cfg.horizon,
  )
  let sampled = sample_policy_batch(
    backend,
    replay,
    motion,
    cfg,
    Smc,
    @numeric.Rng::new(7U),
    dtype=Float64,
    default_q=pose,
  )
  let history = sampled.history.values()
  for i, start in starts {
    for t, tr in start.history {
      let state = @aligned.unflatten_state(tr.s)
      for j in 0..<29 {
        assert_eq(
          history[(i * cfg.hist + t) * 99 + j],
          state.q[j] - pose[j] - tr.xi[j + 1],
        )
      }
    }
  }
}

///|
test "actor replay block CPU tensors preserve all values and RNG at 256 257 and 4096" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP actor block tensor parity: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (motion, replay, base) = block_fixture()
  let cases : Array[(Int32, @aligned.ObservationMode, @tensor.DType)] = [
    (256, Paper, Float32),
    (257, Observable, Float64),
    (4096, Paper, Float32),
  ]
  for (batch, mode, dtype) in cases {
    // The 4096 case retains full batch/index/noise/critic-order coverage with
    // a short CPU-only horizon. Hist10 decoding itself is separately checked
    // bit-for-bit for 4096 starts without retaining a full compatibility graph.
    let config = {
      ..base,
      policy_batch: batch,
      hist: if batch == 4096 {
        2
      } else {
        10
      },
      goal_frames: if batch == 4096 {
        1
      } else {
        base.goal_frames
      },
      horizon: if batch == 4096 {
        2
      } else {
        base.horizon
      },
      critic_epochs: if batch == 4096 {
        1
      } else {
        2
      },
      observation_noise: true,
    }
    let old_rng = @numeric.Rng::new(0x12345678U)
    let new_rng = @numeric.Rng::new(0x12345678U)
    let starts = replay.sample_starts(
      batch,
      config.hist,
      n => old_rng.index(n),
      clip_end=f => motion.clip_end[motion.clip_id[f]],
      horizon=config.horizon,
    )
    let expected = legacy_policy_batch(
      backend, starts, motion, config, mode, old_rng, dtype,
    )
    let actual = sample_policy_batch(
      backend,
      replay,
      motion,
      config,
      mode,
      new_rng,
      dtype~,
    )
    same_policy(actual, expected)
    assert_eq(new_rng.state(), old_rng.state())
    for _ in 0..<16 {
      bit_equal([new_rng.uniform()], [old_rng.uniform()])
    }
  }
}
