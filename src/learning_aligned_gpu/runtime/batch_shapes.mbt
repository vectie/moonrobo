///|
const BatchArithmeticLimit : Int64 = 9223372036854775807L

///|
/// Shape accounting, not admission or a process/device peak estimate. Values
/// exclude array spare capacity, object headers, allocator caches, FFI upload
/// copies, geometry temporaries and autograd. sampled_transition_values retains
/// the full logical compatibility inventory, not the blocked decoder live peak.
pub(all) struct BatchShapeUsage {
  kind : String
  batch : Int32
  sequence_length : Int32
  sample_block_size : Int32
  reference_frames : Int64
  logical_tensor_values : Int64
  tensor_float_values : Int64
  tensor_index_values : Int64
  reference_rotation_values : Int64
  device_f32_payload_bytes : Int64
  logical_source_f64_bytes : Int64
  largest_device_concat_values : Int64
  assembled_values_per_block : Int64
  reference_union_frames_per_block : Int64
  reference_state_values_per_block : Int64
  sampled_transition_values : Int64
  sampled_mask_values : Int64
  critic_permutation_values : Int64
  noise_values_per_block : Int64
} derive(Debug, ToJson)

///|
fn bounded_sum(values : Array[Int64], limit : Int64) -> Int64 raise {
  guard limit > 0L else { fail("positive batch sum bound required") }
  let mut result = 0L
  for value in values {
    guard value >= 0L && value <= limit - result else {
      fail("GPU batch dimensions exceed declared memory bounds")
    }
    result += value
  }
  result
}

///|
/// Explicit capacity for B=4096, H=32, history/preview=10, five critic epochs,
/// noise enabled, and all existing observation modes (largest: Observable 102).
/// This does not change CLI limits or authorize an allocation/learner run.
/// ```mbt check
/// test {
///   let limits = BatchLimits::paper_scale()
///   assert_eq(limits.max_reference_frames, 135168)
///   assert_eq(limits.max_tensor_values, 127016960L)
/// }
/// ```
pub fn BatchLimits::paper_scale() -> BatchLimits {
  { max_reference_frames: 135168, max_tensor_values: 127016960L, }
}

///|
/// Counts the full tensor payload, but only 256 sampled windows and assembled
/// source arrays at once. Caller-owned windows passed directly to
/// world_batch_from_windows remain caller-owned and are not included here.
/// ```mbt check
/// test {
///   let usage = world_batch_shape_usage(2048, 8)
///   assert_eq(usage.logical_tensor_values, 3358720L)
///   assert_eq(usage.sample_block_size, 256)
/// }
/// ```
pub fn world_batch_shape_usage(
  batch : Int32,
  width : Int32,
  limits~ : BatchLimits = BatchLimits::default(),
) -> BatchShapeUsage raise {
  let ceiling = limits.max_tensor_values.min(2147483647L)
  let b = batch.to_int64()
  let w = width.to_int64()
  let values = bounded_product([b, w, 205L], ceiling)
  check_limits(limits, 0L, values)
  let block = batch.min(ReferenceBlockSamples)
  let c = block.to_int64()
  {
    kind: "world",
    batch,
    sequence_length: width,
    sample_block_size: block,
    reference_frames: 0L,
    logical_tensor_values: values,
    tensor_float_values: values,
    tensor_index_values: 0L,
    reference_rotation_values: 0L,
    device_f32_payload_bytes: bounded_product(
      [values, 4L],
      BatchArithmeticLimit,
    ),
    logical_source_f64_bytes: bounded_product(
      [values, 8L],
      BatchArithmeticLimit,
    ),
    largest_device_concat_values: if batch > block {
      bounded_product([b, w, 71L], ceiling)
    } else {
      0L
    },
    assembled_values_per_block: bounded_product([c, w, 205L], ceiling),
    reference_union_frames_per_block: 0L,
    reference_state_values_per_block: 0L,
    sampled_transition_values: bounded_product(
      [c, w, 234L],
      BatchArithmeticLimit,
    ),
    sampled_mask_values: bounded_product([c, w], BatchArithmeticLimit),
    critic_permutation_values: 0L,
    noise_values_per_block: 0L,
  }
}

///|
fn policy_shape_usage(
  config : @aligned.LearnerConfig,
  batch : Int32,
  dim : Int32,
  limits : BatchLimits,
) -> BatchShapeUsage raise {
  guard batch > 0 &&
    dim > 0 &&
    config.hist > 0 &&
    config.goal_frames > 0 &&
    config.horizon > 0 &&
    config.critic_epochs > 0 else {
    fail("invalid policy batch dimensions")
  }
  let b = batch.to_int64()
  let h = config.horizon.to_int64()
  let k = config.goal_frames.to_int64()
  let history = config.hist.to_int64()
  let d = dim.to_int64()
  let ceiling = limits.max_tensor_values.min(2147483647L)
  let references = bounded_product(
    [(h + 1L).max(k).max(history), b],
    limits.max_reference_frames.to_int64(),
  )
  let goal_width = bounded_product([73L, k], ceiling)
  let base = bounded_product([b, 133L], ceiling)
  let hist_width = bounded_product([history, d], ceiling)
  let history_values = bounded_product([b, hist_width], ceiling)
  let flat_references = bounded_product([b, h + 1L, 71L], ceiling)
  let goals = bounded_product([b, h + 1L, goal_width], ceiling)
  let noise = if config.observation_noise {
    bounded_product([b, h, d], ceiling)
  } else {
    0L
  }
  let order = bounded_product([b, config.critic_epochs.to_int64(), h], ceiling)
  let floats = bounded_sum(
    [base, history_values, flat_references, goals, noise],
    ceiling,
  )
  let values = bounded_sum([floats, order], ceiling)
  check_limits(limits, references, values)
  let rotations = bounded_product([b, h + 1L, 9L], BatchArithmeticLimit)
  let block = batch.min(ReferenceBlockSamples)
  let c = block.to_int64()
  // Each sample contributes at most hist history frames and H+K+1 future
  // frames. The reader additionally intersects this with FrameStore's bound.
  let union_frames = bounded_product(
    [c, bounded_sum([history, h, k, 1L], BatchArithmeticLimit)],
    BatchArithmeticLimit,
  ).min(limits.max_reference_frames.to_int64())
  {
    kind: "policy",
    batch,
    sequence_length: (h + 1L).to_int(),
    sample_block_size: block,
    reference_frames: references,
    logical_tensor_values: values,
    tensor_float_values: floats,
    tensor_index_values: order,
    reference_rotation_values: rotations,
    // Reference component views retain flat71 storage; the decoded 3x3
    // rotations have separate storage. Critic permutations are Int64 tensors.
    device_f32_payload_bytes: bounded_sum(
      [
        bounded_product(
          [bounded_sum([floats, rotations], BatchArithmeticLimit), 4L],
          BatchArithmeticLimit,
        ),
        bounded_product([order, 8L], BatchArithmeticLimit),
      ],
      BatchArithmeticLimit,
    ),
    logical_source_f64_bytes: bounded_product(
      [values, 8L],
      BatchArithmeticLimit,
    ),
    largest_device_concat_values: if batch > block {
      bounded_product([b, hist_width.max(goal_width).max(71L).max(d)], ceiling)
    } else {
      0L
    },
    assembled_values_per_block: bounded_product(
      [
        c,
        bounded_sum([133L, hist_width, 71L, goal_width], BatchArithmeticLimit),
      ],
      BatchArithmeticLimit,
    ),
    reference_union_frames_per_block: union_frames,
    reference_state_values_per_block: bounded_product(
      [union_frames, 76L],
      BatchArithmeticLimit,
    ),
    // Logical compatibility inventory is retained for API/accounting stability.
    // sample_policy_batch now fixes all B primitive indices, then decodes only
    // min(B,256)*(history+1) transitions at a time. Direct callers supplying a
    // full array to policy_batch_from_starts still own that full inventory.
    sampled_transition_values: bounded_product(
      [b, history + 1L, 234L],
      BatchArithmeticLimit,
    ),
    sampled_mask_values: 0L,
    critic_permutation_values: bounded_product([b, h], ceiling),
    noise_values_per_block: if config.observation_noise {
      bounded_product([c, d], ceiling)
    } else {
      0L
    },
  }
}

///|
/// Pure checked arithmetic before sampling/allocation. The source Float64
/// total describes logical contents, not a full host allocation: reference,
/// history, goal and noise uploads are assembled in sample blocks <=256.
pub fn policy_batch_shape_usage(
  config : @aligned.LearnerConfig,
  batch : Int32,
  mode : @aligned.ObservationMode,
  limits~ : BatchLimits = BatchLimits::default(),
) -> BatchShapeUsage raise {
  policy_shape_usage(config, batch, mode.dim(), limits)
}
