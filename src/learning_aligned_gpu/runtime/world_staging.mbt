///|
/// Additional bound for the optional five-field logical-batch staging path.
/// The decoded replay compatibility objects remain limited to 256 windows.
pub(all) struct WorldStagingUsage {
  logical_values : Int64
  host_array_payload_bytes : Int64
  extra_reserve_bytes : Int64
  decode_block_windows : Int32
  upload_calls : Int32
  device_concat_calls : Int32
} derive(Debug, ToJson)

///|
/// Validate before allocating staging arrays or consuming replay RNG draws.
/// The cap applies to the conservative additional reserve, not just payload.
/// Keep the old admission envelope as well: no freed GPU concat is credited.
pub fn world_staging_usage(
  batch : Int32,
  width : Int32,
  max_bytes~ : Int64 = 134217728L,
  limits~ : BatchLimits = BatchLimits::default(),
) -> WorldStagingUsage raise {
  let shape = world_batch_shape_usage(batch, width, limits~)
  // Preallocated Array[Double] (8/value), FFI FixedArray copy (8), CPU
  // Float64 tensor (8), and FP32 conversion/device storage (4+4). Float64
  // skips the dtype-conversion allocation and uses 8 device bytes instead.
  // Charging 32 bytes for every field conservatively covers even overlapping
  // field uploads; headers and fixed shape/profile metadata get another 64 KiB.
  let reserve = bounded_sum(
    [
      bounded_product([shape.logical_tensor_values, 32L], BatchArithmeticLimit),
      65536L,
    ],
    BatchArithmeticLimit,
  )
  guard max_bytes > 0L && reserve <= max_bytes else {
    fail("world logical staging exceeds explicit additional-memory cap")
  }
  {
    logical_values: shape.logical_tensor_values,
    host_array_payload_bytes: shape.logical_source_f64_bytes,
    extra_reserve_bytes: reserve,
    decode_block_windows: shape.sample_block_size,
    upload_calls: 5,
    device_concat_calls: 0,
  }
}

///|
struct WorldStaging {
  batch : Int32
  width : Int32
  s : Array[Double]
  s1 : Array[Double]
  actions : Array[Double]
  xi : Array[Double]
  mask : Array[Double]
  mut filled : Int32
}

///|
fn WorldStaging::new(batch : Int32, width : Int32) -> WorldStaging {
  // The caller has validated batch*width*205 <= Int32.max before this point.
  let rows = batch * width
  {
    batch,
    width,
    s: Array::make(rows * 71, 0.0),
    s1: Array::make(rows * 71, 0.0),
    actions: Array::make(rows * 29, 0.0),
    xi: Array::make(rows * 33, 0.0),
    mask: Array::make(rows, 0.0),
    filled: 0,
  }
}

///|
fn copy_world_field(
  target : Array[Double],
  row : Int32,
  width : Int32,
  source : Array[Double],
) -> Unit raise {
  guard source.length() == width else { fail("invalid world transition shape") }
  let offset = row * width
  for i in 0..<width {
    // Reject a bad decoded block before drawing the next block, as in the
    // preserved upload-per-block path. Private staging is only written here.
    guard @numeric.finite(source[i]) else {
      fail("GPU batch contains nonfinite values")
    }
    target[offset + i] = source[i]
  }
}

///|
fn WorldStaging::append(
  self : WorldStaging,
  windows : Array[@aligned.ReplayWindow],
) -> Unit raise {
  guard !windows.is_empty() &&
    windows.length() <= ReferenceBlockSamples &&
    windows.length() <= self.batch - self.filled else {
    fail("world staging decode block exceeds declared bounds")
  }
  @tensor.profile_span("batch.world.pack", () => {
    for i, window in windows {
      guard window.transitions.length() == self.width &&
        window.mask.length() == self.width else {
        fail("world window dimensions differ")
      }
      for j, tr in window.transitions {
        let row = (self.filled + i) * self.width + j
        copy_world_field(self.s, row, 71, tr.s)
        copy_world_field(self.s1, row, 71, tr.s1)
        copy_world_field(self.actions, row, 29, tr.a)
        copy_world_field(self.xi, row, 33, tr.xi)
        let mask = window.mask[j]
        guard mask == 0.0 || mask == 1.0 else {
          fail("world masks must be binary")
        }
        self.mask[row] = mask
      }
    }
    self.filled += windows.length()
  })
}

///|
fn upload_validated_world_field(
  backend : @tensor.Backend,
  values : Array[Double],
  shape : Array[Int32],
  device : Int32,
  dtype : @tensor.DType,
) -> @tensor.Tensor raise {
  // append has checked every value (and binary masks) before marking a block
  // filled. Avoid rescanning the private complete staging arrays at upload.
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
fn WorldStaging::finish(
  self : WorldStaging,
  backend : @tensor.Backend,
  device : Int32,
  dtype : @tensor.DType,
) -> @gpu.WorldBatch raise {
  guard self.filled == self.batch else {
    fail("incomplete world staging batch")
  }
  // Preserve field order and the original conversion path after append's
  // finite validation. A failed append cannot produce a complete batch.
  // Each field is uploaded exactly once; no GPU concatenation is necessary.
  {
    s: upload_validated_world_field(
      backend,
      self.s,
      [self.batch, self.width, 71],
      device,
      dtype,
    ),
    s1: upload_validated_world_field(
      backend,
      self.s1,
      [self.batch, self.width, 71],
      device,
      dtype,
    ),
    actions: upload_validated_world_field(
      backend,
      self.actions,
      [self.batch, self.width, 29],
      device,
      dtype,
    ),
    xi: upload_validated_world_field(
      backend,
      self.xi,
      [self.batch, self.width, 33],
      device,
      dtype,
    ),
    mask: upload_validated_world_field(
      backend,
      self.mask,
      [self.batch, self.width],
      device,
      dtype,
    ),
  }
}

///|
fn sample_world_batch_staged(
  backend : @tensor.Backend,
  replay : @aligned.ReplayBuffer,
  config : @aligned.LearnerConfig,
  rng : @numeric.Rng,
  cuda_device : Int32,
  dtype : @tensor.DType,
  limits : BatchLimits,
  max_bytes : Int64,
) -> @gpu.WorldBatch raise {
  ignore(
    world_staging_usage(config.wm_batch, config.wm_window, max_bytes~, limits~),
  )
  guard dtype == Float32 || dtype == Float64 else {
    fail("world logical staging requires Float32 or Float64")
  }
  guard replay.can_sample_windows(config.wm_window) else {
    fail("insufficient replay for world staging")
  }
  let staging = WorldStaging::new(config.wm_batch, config.wm_window)
  for begin = 0; begin < config.wm_batch; {
    let count = (config.wm_batch - begin).min(ReferenceBlockSamples)
    let windows = @tensor.profile_span("batch.world.replay", () => {
      replay.sample_windows(count, config.wm_window, n => rng.index(n))
    })
    staging.append(windows)
    continue begin + count
  }
  staging.finish(backend, cuda_device, dtype)
}
