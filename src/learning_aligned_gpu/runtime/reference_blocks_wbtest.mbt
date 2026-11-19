///|
fn bit_equal(actual : Array[Double], expected : Array[Double]) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(
      actual[i].reinterpret_as_int64(),
      expected[i].reinterpret_as_int64(),
    )
  }
}

///|
// Kept independent of the new shared append helper: this is the pre-gather
// scalar preview formula, including its Float64 operation order.
fn legacy_goal(
  motion : @aligned.MotionLibrary,
  frame : Int32,
  k : Int32,
) -> Array[Double] {
  let out : Array[Double] = []
  let current = motion.states[frame]
  let ht = @aligned.transpose(@aligned.yaw_mat(current.rotation))
  for f in motion.future_frames(frame, k) {
    let future = motion.states[f]
    out.append(@aligned.mat_vec(ht, @aligned.vec_sub(future.p, current.p)))
    out.append(@aligned.mat_to_6d(@aligned.mat_mul(ht, future.rotation)))
    out.append(@aligned.mat_vec(@aligned.transpose(future.rotation), future.v))
    out.append(@aligned.mat_vec(@aligned.transpose(future.rotation), future.w))
    out.append(future.q)
    out.append(@aligned.vec_scale(future.qd, 0.1))
  }
  out
}

///|
fn block_fixture() -> (
  @aligned.MotionLibrary,
  @aligned.ReplayBuffer,
  @aligned.LearnerConfig,
) raise {
  let (kin, _, c) = fixture()
  let clips : Array[@aligned.MotionClip] = Array::makei(2, clip => {
    let rows = Array::makei(16, i => {
      let angle = (clip * 16 + i).to_double() * 0.047
      let quat = @aligned.mat_to_quat(
        @aligned.so3_exp([angle * 0.4, angle * -0.2, angle]),
      )
      let row = [
        if i == 0 {
          -0.0
        } else {
          i.to_double() * 0.011
        },
        clip.to_double() * -0.07,
        0.81 + i.to_double() * 0.003,
        quat[1],
        quat[2],
        quat[3],
        quat[0],
      ]
      row.append(
        Array::makei(29, j => {
          if j == 0 {
            -0.0
          } else {
            (i + j).to_double() * 0.001
          }
        }),
      )
      row
    })
    { name: "block\{clip}", sha256: "block-hash\{clip}", rows, }
  })
  let original = @aligned.MotionLibrary::new(clips, kin, source_fps=50.0)
  // Force signed zero into non-normalized features as well as the source CSV.
  let states = Array::makei(original.states.length(), i => {
    let state = original.states[i]
    { ..state, v: [-0.0, state.v[1], state.v[2]], qd: Array::make(29, -0.0), }
  })
  let motion = { ..original, states: @aligned.FrameStore::eager(states), }
  let replay = @aligned.ReplayBuffer::new(16, 1)
  for frame in [0, 1, 2, 12, 16, 17, 18, 28] {
    replay.add([transition(motion, frame, frame % 16)])
  }
  (
    motion,
    replay,
    {
      ..c,
      hist: 4,
      goal_frames: 4,
      horizon: 3,
      policy_batch: 257,
      critic_epochs: 2,
    },
  )
}

///|
// The old full-host-array assembly is intentionally retained only in this
// bounded CPU test oracle. No new production path can call it.
fn legacy_policy_batch(
  b : @tensor.Backend,
  starts : Array[@aligned.ReplayStart],
  motion : @aligned.MotionLibrary,
  c : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  dtype : @tensor.DType,
) -> @gpu.PolicyBatch raise {
  let batch = starts.length()
  let dim = mode.dim()
  let state : Array[Double] = []
  let previous : Array[Double] = []
  let xi : Array[Double] = []
  let history : Array[Double] = []
  for start in starts {
    state.append(start.start.s)
    previous.append(start.start.a_prev)
    xi.append(start.start.xi)
    for past in start.history {
      let obs = @aligned.observation(
        @aligned.unflatten_state(past.s),
        past.a_prev,
        past.xi,
        @aligned.default_joint_positions(),
        motion.states[past.frame],
        mode,
      )
      if c.observation_noise {
        let widths = @aligned.observation_noise(mode)
        for j in 0..<obs.length() {
          obs[j] += (rng.uniform() * 2.0 - 1.0) * widths[j]
        }
      }
      history.append(obs)
    }
  }
  let references : Array[@geometry.State] = []
  let goals : Array[@tensor.Tensor] = []
  for t in 0..<(c.horizon + 1) {
    let frames = starts.map(start => start.start.frame + t)
    let refs = motion.states.gather(frames)
    let reference_values : Array[Double] = []
    let goal_values : Array[Double] = []
    for i, frame in frames {
      reference_values.append(@aligned.flatten_state(refs[i]))
      goal_values.append(legacy_goal(motion, frame, c.goal_frames))
    }
    references.push(
      @geometry.State::from_flat71(
        b,
        upload(b, reference_values, [batch, 71], -1, dtype),
      ),
    )
    goals.push(upload(b, goal_values, [batch, 73 * c.goal_frames], -1, dtype))
  }
  let step_noise : Array[@tensor.Tensor] = []
  if c.observation_noise {
    let widths = @aligned.observation_noise(mode)
    for _ in 0..<c.horizon {
      let values = Array::makei(batch * dim, i => {
        (rng.uniform() * 2.0 - 1.0) * widths[i % dim]
      })
      step_noise.push(upload(b, values, [batch, dim], -1, dtype))
    }
  }
  let critic_orders : Array[@tensor.Tensor] = []
  let count = batch * c.horizon
  for _ in 0..<c.critic_epochs {
    let order = Array::makei(count, i => i.to_double())
    for i = count - 1; i > 0; i = i - 1 {
      let j = rng.index(i + 1)
      let value = order[i]
      order[i] = order[j]
      order[j] = value
    }
    critic_orders.push(upload(b, order, [count], -1, Int64))
  }
  {
    state: upload(b, state, [batch, 71], -1, dtype),
    previous: upload(b, previous, [batch, 29], -1, dtype),
    xi: upload(b, xi, [batch, 33], -1, dtype),
    history: upload(b, history, [batch, c.hist, dim], -1, dtype),
    references,
    reference_fk: None,
    goals,
    step_noise,
    critic_orders,
  }
}

///|
fn same_tensor(a : @tensor.Tensor, b : @tensor.Tensor) -> Unit raise {
  assert_eq(a.shape(), b.shape())
  assert_eq(a.dtype(), b.dtype())
  bit_equal(a.values(), b.values())
}

///|
fn same_policy(a : @gpu.PolicyBatch, b : @gpu.PolicyBatch) -> Unit raise {
  same_tensor(a.state, b.state)
  same_tensor(a.previous, b.previous)
  same_tensor(a.xi, b.xi)
  same_tensor(a.history, b.history)
  assert_eq(a.references.length(), b.references.length())
  for t in 0..<a.references.length() {
    let x = a.references[t]
    let y = b.references[t]
    for
      (left, right) in [
        (x.p, y.p),
        (x.rotation, y.rotation),
        (x.v, y.v),
        (x.w, y.w),
        (x.q, y.q),
        (x.qd, y.qd),
      ] {
      same_tensor(left, right)
    }
    same_tensor(a.goals[t], b.goals[t])
  }
  assert_eq(a.step_noise.length(), b.step_noise.length())
  for i in 0..<a.step_noise.length() {
    same_tensor(a.step_noise[i], b.step_noise[i])
  }
  assert_eq(a.critic_orders.length(), b.critic_orders.length())
  for i in 0..<a.critic_orders.length() {
    same_tensor(a.critic_orders[i], b.critic_orders[i])
  }
}

///|
test "bounded gather CPU tensors match old ordering bits and RNG across 256 plus tail" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP bounded reference tensor parity: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let (motion, replay, base) = block_fixture()
  let cases : Array[
    (Int32, Bool, @aligned.ObservationMode, @tensor.DType, Int32),
  ] = [
    (257, true, Paper, Float32, 131072),
    (257, true, Observable, Float64, 131072),
    (3, false, Smc, Float64, 131072),
    (1, true, Paper, Float64, 4),
  ]
  for (count, noisy, mode, dtype, max_frames) in cases {
    let c = { ..base, policy_batch: count, observation_noise: noisy, }
    let old_rng = @numeric.Rng::new(0x12345678U)
    let new_rng = @numeric.Rng::new(0x12345678U)
    let starts = replay.sample_starts(
      count,
      c.hist,
      n => old_rng.index(n),
      clip_end=f => motion.clip_end[motion.clip_id[f]],
      horizon=c.horizon,
    )
    let expected = legacy_policy_batch(
      b, starts, motion, c, mode, old_rng, dtype,
    )
    let actual = sample_policy_batch(
      b,
      replay,
      motion,
      c,
      mode,
      new_rng,
      dtype~,
      limits={ max_reference_frames: max_frames, max_tensor_values: 16777216L, },
    )
    same_policy(actual, expected)
    assert_eq(new_rng.state(), old_rng.state())
    for _ in 0..<16 {
      bit_equal([new_rng.uniform()], [old_rng.uniform()])
    }
    if count > 1 {
      assert_true(
        starts.any(start => start.history[0].frame == start.history[1].frame),
      )
    }
    if count == 257 {
      assert_true(
        starts.any(start => start.start.frame == 12 || start.start.frame == 28),
      )
    }
  }
}

///|
test "reference block reads only unique sorted needed frames and preserves tail padding bits" {
  let (motion, replay, c) = block_fixture()
  let starts = replay.sample_starts(
    256,
    c.hist,
    _ => 7,
    clip_end=f => motion.clip_end[motion.clip_id[f]],
    horizon=c.horizon,
  )
  let reads : Array[Int32] = []
  let frames = reference_block_frames(
    motion,
    starts[:],
    c,
    BatchLimits::default(),
  )
  let block = read_reference_block(frames, frame => {
    reads.push(frame)
    motion.states[frame]
  })
  assert_eq(reads, [28, 29, 30, 31])
  assert_eq(block.states.length(), 4)
  for t in 0..<(c.horizon + 1) {
    bit_equal(
      block.goal(motion, 28 + t, c.goal_frames),
      legacy_goal(motion, 28 + t, c.goal_frames),
    )
  }
  let futures = motion.future_frames(31, c.goal_frames)
  assert_eq(futures, [31, 31, 31, 31])
  bit_equal(
    @aligned.goal_from_states(
      motion.states[31],
      futures.map(f => motion.states[f]),
    ),
    legacy_goal(motion, 31, c.goal_frames),
  )
  assert_eq(
    block.at(28).v[0].reinterpret_as_int64(),
    (-0.0).reinterpret_as_int64(),
  )
  let scalar = gather_reference_block(motion, starts[:], c, {
    max_reference_frames: 3,
    max_tensor_values: 16777216L,
  })
  assert_eq(scalar.states.length(), 0)
  for t in 0..<(c.horizon + 1) {
    bit_equal(
      scalar.goal(motion, 28 + t, c.goal_frames),
      legacy_goal(motion, 28 + t, c.goal_frames),
    )
  }
  let too_many = starts.copy()
  too_many.push(starts[0])
  try
    gather_reference_block(motion, too_many[:], c, BatchLimits::default())
  catch {
    _ => ()
  } noraise {
    _ => fail("reference sample block exceeded 256")
  }
}
