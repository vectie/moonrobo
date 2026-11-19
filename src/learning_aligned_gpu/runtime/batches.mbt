///|
pub(all) struct BatchLimits {
  max_reference_frames : Int32
  max_tensor_values : Int64
} derive(Debug, ToJson, FromJson)

///|
pub fn BatchLimits::default() -> BatchLimits {
  { max_reference_frames: 131072, max_tensor_values: 16777216L, }
}

///|
fn check_limits(
  limits : BatchLimits,
  frames : Int64,
  values : Int64,
) -> Unit raise {
  guard limits.max_reference_frames > 0 &&
    limits.max_tensor_values > 0L &&
    frames >= 0L &&
    frames <= limits.max_reference_frames.to_int64() &&
    values > 0L &&
    values <= limits.max_tensor_values &&
    values < 2147483648L else {
    fail("GPU batch exceeds declared reference/staging limits")
  }
}

///|
fn bounded_product(factors : Array[Int64], limit : Int64) -> Int64 raise {
  guard limit > 0L else { fail("positive batch bound required") }
  let mut result = 1L
  for factor in factors {
    guard factor > 0L && result <= limit / factor else {
      fail("GPU batch dimensions exceed declared memory bounds")
    }
    result *= factor
  }
  result
}

///|
fn upload(
  backend : @tensor.Backend,
  values : Array[Double],
  shape : Array[Int32],
  device : Int32,
  dtype : @tensor.DType,
) -> @tensor.Tensor raise {
  @tensor.profile_span("batch.validate_values", () => {
    guard values.all(@numeric.finite) else {
      fail("GPU batch contains nonfinite values")
    }
  })
  @tensor.profile_span("batch.upload", () => {
    backend.from_values(
      shape,
      values,
      cuda_device=device,
      requires_grad=false,
      dtype~,
    )
  })
}

///|
pub fn world_batch_from_windows(
  backend : @tensor.Backend,
  windows : Array[@aligned.ReplayWindow],
  cuda_device~ : Int32 = -1,
  dtype~ : @tensor.DType = Float32,
  limits~ : BatchLimits = BatchLimits::default(),
) -> @gpu.WorldBatch raise {
  guard !windows.is_empty() && !windows[0].transitions.is_empty() else {
    fail("nonempty world windows required")
  }
  let batch = windows.length()
  let width = windows[0].transitions.length()
  ignore(world_batch_shape_usage(batch, width, limits~))
  let blocks = WorldTensorBlocks::new()
  for begin = 0; begin < batch; {
    let end = begin + (batch - begin).min(ReferenceBlockSamples)
    append_world_block(
      backend,
      blocks,
      windows[begin:end],
      width,
      cuda_device,
      dtype,
    )
    continue end
  }
  blocks.finish(backend)
}

///|
struct WorldTensorBlocks {
  s : Array[@tensor.Tensor]
  s1 : Array[@tensor.Tensor]
  actions : Array[@tensor.Tensor]
  xi : Array[@tensor.Tensor]
  mask : Array[@tensor.Tensor]
}

///|
fn WorldTensorBlocks::new() -> WorldTensorBlocks {
  { s: [], s1: [], actions: [], xi: [], mask: [], }
}

///|
fn WorldTensorBlocks::finish(
  self : WorldTensorBlocks,
  backend : @tensor.Backend,
) -> @gpu.WorldBatch raise {
  {
    s: finish_tensor_blocks(backend, self.s),
    s1: finish_tensor_blocks(backend, self.s1),
    actions: finish_tensor_blocks(backend, self.actions),
    xi: finish_tensor_blocks(backend, self.xi),
    mask: finish_tensor_blocks(backend, self.mask),
  }
}

///|
fn append_world_block(
  backend : @tensor.Backend,
  blocks : WorldTensorBlocks,
  windows : ArrayView[@aligned.ReplayWindow],
  width : Int32,
  cuda_device : Int32,
  dtype : @tensor.DType,
) -> Unit raise {
  let packing = @tensor.profile_begin("batch.world.pack")
  errdefer @tensor.profile_cancel(packing)
  let batch = windows.length()
  guard batch > 0 && batch <= ReferenceBlockSamples else {
    fail("world staging block must contain 1..256 windows")
  }
  let s : Array[Double] = []
  let s1 : Array[Double] = []
  let actions : Array[Double] = []
  let xi : Array[Double] = []
  let mask : Array[Double] = []
  for window in windows {
    guard window.transitions.length() == width && window.mask.length() == width else {
      fail("world window dimensions differ")
    }
    for tr in window.transitions {
      guard tr.s.length() == 71 &&
        tr.s1.length() == 71 &&
        tr.a.length() == 29 &&
        tr.xi.length() == 33 else {
        fail("invalid world transition shape")
      }
      s.append(tr.s)
      s1.append(tr.s1)
      actions.append(tr.a)
      xi.append(tr.xi)
    }
    guard window.mask.all(x => x == 0.0 || x == 1.0) else {
      fail("world masks must be binary")
    }
    mask.append(window.mask)
  }
  @tensor.profile_end(packing)
  blocks.s.push(upload(backend, s, [batch, width, 71], cuda_device, dtype))
  blocks.s1.push(upload(backend, s1, [batch, width, 71], cuda_device, dtype))
  blocks.actions.push(
    upload(backend, actions, [batch, width, 29], cuda_device, dtype),
  )
  blocks.xi.push(upload(backend, xi, [batch, width, 33], cuda_device, dtype))
  blocks.mask.push(upload(backend, mask, [batch, width], cuda_device, dtype))
}

///|
pub fn sample_world_batch(
  backend : @tensor.Backend,
  replay : @aligned.ReplayBuffer,
  config : @aligned.LearnerConfig,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  dtype~ : @tensor.DType = Float32,
  limits~ : BatchLimits = BatchLimits::default(),
  staging_max_bytes~ : Int64? = None,
  packed_replay~ : Bool = false,
) -> @gpu.WorldBatch raise {
  guard !packed_replay || staging_max_bytes is Some(_) else {
    fail("packed replay requires admitted world staging")
  }
  if staging_max_bytes is Some(max_bytes) {
    if packed_replay {
      return sample_world_batch_packed(
        backend, replay, config, rng, cuda_device, dtype, limits, max_bytes,
      )
    }
    return sample_world_batch_staged(
      backend, replay, config, rng, cuda_device, dtype, limits, max_bytes,
    )
  }
  ignore(world_batch_shape_usage(config.wm_batch, config.wm_window, limits~))
  let blocks = WorldTensorBlocks::new()
  // sample_windows draws start/env once per sample and scans no candidate
  // table. Splitting this call changes neither draws nor transition order.
  for begin = 0; begin < config.wm_batch; {
    let count = (config.wm_batch - begin).min(ReferenceBlockSamples)
    let windows = @tensor.profile_span("batch.world.replay", () => {
      replay.sample_windows(count, config.wm_window, n => rng.index(n))
    })
    append_world_block(
      backend,
      blocks,
      windows[:],
      config.wm_window,
      cuda_device,
      dtype,
    )
    continue begin + count
  }
  @tensor.profile_span("batch.world.concatenate", () => blocks.finish(backend))
}

///|
fn observation_with_noise(
  state : @aligned.State,
  previous : Array[Double],
  xi : Array[Double],
  reference : @aligned.State,
  mode : @aligned.ObservationMode,
  default_q : Array[Double],
  enabled : Bool,
  rng : @numeric.Rng,
) -> Array[Double] {
  let obs = @aligned.observation(
    state, previous, xi, default_q, reference, mode,
  )
  if enabled {
    let widths = @aligned.observation_noise(mode)
    Array::makei(obs.length(), j => {
      obs[j] + (rng.uniform() * 2.0 - 1.0) * widths[j]
    })
  } else {
    obs
  }
}

///|
fn check_policy_limits(
  config : @aligned.LearnerConfig,
  batch : Int32,
  dim : Int32,
  limits : BatchLimits,
) -> Unit raise {
  ignore(policy_shape_usage(config, batch, dim, limits))
}

///|
pub fn policy_batch_from_starts(
  backend : @tensor.Backend,
  starts : Array[@aligned.ReplayStart],
  motion : @aligned.MotionLibrary,
  config : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  dtype~ : @tensor.DType = Float32,
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  limits~ : BatchLimits = BatchLimits::default(),
  resident_references~ : ResidentReferences? = None,
  noise_staging_max_bytes~ : Int64? = None,
) -> @gpu.PolicyBatch raise {
  let batch = starts.length()
  let dim = mode.dim()
  check_policy_limits(config, batch, dim, limits)
  if noise_staging_max_bytes is Some(cap) {
    check_noise_staging(batch, dim, dtype, limits, cap)
  }
  guard default_q.length() == 29 else {
    fail("default joint pose must have 29 values")
  }
  let staged = stage_policy_inputs(
    backend,
    starts,
    motion,
    config,
    mode,
    rng,
    cuda_device,
    dtype,
    default_q,
    limits,
    resident_references~,
  )
  finish_policy_batch(
    backend,
    staged,
    batch,
    config,
    mode,
    rng,
    cuda_device,
    dtype,
    noise_staging_max_bytes~,
    limits~,
  )
}

///|
// History noise is fully generated by staging before any imagined-step noise
// or critic permutation draws. Preserve this RNG/optimizer-input order.
fn finish_policy_batch(
  backend : @tensor.Backend,
  staged : PolicyInputTensors,
  batch : Int32,
  config : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  cuda_device : Int32,
  dtype : @tensor.DType,
  noise_staging_max_bytes~ : Int64? = None,
  limits~ : BatchLimits = BatchLimits::default(),
) -> @gpu.PolicyBatch raise {
  let dim = mode.dim()
  let step_noise : Array[@tensor.Tensor] = []
  if config.observation_noise {
    let widths = @aligned.observation_noise(mode)
    for _ in 0..<config.horizon {
      match noise_staging_max_bytes {
        Some(cap) =>
          step_noise.push(
            staged_step_noise(
              backend,
              batch,
              widths,
              () => rng.uniform(),
              cuda_device,
              dtype,
              limits,
              cap,
            ),
          )
        None => {
          let parts : Array[@tensor.Tensor] = []
          for begin = 0; begin < batch; {
            let count = (batch - begin).min(ReferenceBlockSamples)
            let values = Array::makei(count * dim, i => {
              (rng.uniform() * 2.0 - 1.0) * widths[i % dim]
            })
            parts.push(
              upload(backend, values, [count, dim], cuda_device, dtype),
            )
            continue begin + count
          }
          step_noise.push(finish_tensor_blocks(backend, parts))
        }
      }
    }
  }
  let critic_orders : Array[@tensor.Tensor] = []
  let count = batch * config.horizon
  for _ in 0..<config.critic_epochs {
    let order = Array::makei(count, i => i.to_double())
    for i = count - 1; i > 0; i = i - 1 {
      let j = rng.index(i + 1)
      let value = order[i]
      order[i] = order[j]
      order[j] = value
    }
    critic_orders.push(upload(backend, order, [count], cuda_device, Int64))
  }
  {
    state: staged.state,
    previous: staged.previous,
    xi: staged.xi,
    history: staged.history,
    references: staged.references,
    reference_fk: staged.reference_fk,
    goals: staged.goals,
    step_noise,
    critic_orders,
  }
}

///|
pub fn sample_policy_batch(
  backend : @tensor.Backend,
  replay : @aligned.ReplayBuffer,
  motion : @aligned.MotionLibrary,
  config : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  dtype~ : @tensor.DType = Float32,
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  limits~ : BatchLimits = BatchLimits::default(),
  resident_references~ : ResidentReferences? = None,
  noise_staging_max_bytes~ : Int64? = None,
) -> @gpu.PolicyBatch raise {
  guard default_q.length() == 29 else {
    fail("expected 29 embedded default joint positions")
  }
  check_policy_limits(config, config.policy_batch, mode.dim(), limits)
  if noise_staging_max_bytes is Some(cap) {
    check_noise_staging(config.policy_batch, mode.dim(), dtype, limits, cap)
  }
  let staged = @tensor.profile_span("batch.policy.references_history", () => {
    stage_policy_input_blocks(
      backend,
      motion,
      config,
      mode,
      rng,
      cuda_device,
      dtype,
      default_q,
      limits,
      consume => {
        replay.with_sampled_start_blocks(
          config.policy_batch,
          config.hist,
          n => rng.index(n),
          starts => consume(starts[:]),
          clip_end=f => motion.clip_end[motion.clip_id[f]],
          horizon=config.horizon,
        )
      },
      resident_references~,
    )
  })
  @tensor.profile_span("batch.policy.noise_permutations", () => {
    finish_policy_batch(
      backend,
      staged,
      config.policy_batch,
      config,
      mode,
      rng,
      cuda_device,
      dtype,
      noise_staging_max_bytes~,
      limits~,
    )
  })
}
