///|
/// One imagined time step is staged at a time; generation blocks stay <=256.
pub(all) struct NoiseStagingUsage {
  logical_values : Int64
  host_array_payload_bytes : Int64
  generation_block_values : Int64
  extra_reserve_bytes : Int64
  upload_calls_per_step : Int32
  device_concat_calls_per_step : Int32
} derive(Debug, ToJson)

///|
/// The cap covers additional storage, leaving every original envelope intact.
pub fn noise_staging_usage(
  batch : Int32,
  dim : Int32,
  max_bytes~ : Int64 = 16777216L,
  limits~ : BatchLimits = BatchLimits::default(),
) -> NoiseStagingUsage raise {
  let values = bounded_product([batch.to_int64(), dim.to_int64()], 2147483647L)
  check_limits(limits, 0L, values)
  let block = batch.min(ReferenceBlockSamples).to_int64() * dim.to_int64()
  // Full Double array + FFI FixedArray + CPU Float64 + FP32 conversion/device:
  // 8+8+8+4+4 bytes/value. Float64 uses no conversion and 8 device bytes.
  // Additionally charge one Double generation block and 64 KiB fixed metadata.
  let reserve = bounded_sum(
    [
      bounded_product([values, 32L], BatchArithmeticLimit),
      bounded_product([block, 8L], BatchArithmeticLimit),
      65536L,
    ],
    BatchArithmeticLimit,
  )
  guard max_bytes > 0L && reserve <= max_bytes else {
    fail("imagined noise staging exceeds explicit additional-memory cap")
  }
  {
    logical_values: values,
    host_array_payload_bytes: values * 8L,
    generation_block_values: block,
    extra_reserve_bytes: reserve,
    upload_calls_per_step: 1,
    device_concat_calls_per_step: 0,
  }
}

///|
fn check_noise_staging(
  batch : Int32,
  dim : Int32,
  dtype : @tensor.DType,
  limits : BatchLimits,
  max_bytes : Int64,
) -> Unit raise {
  ignore(noise_staging_usage(batch, dim, max_bytes~, limits~))
  guard dtype == Float32 || dtype == Float64 else {
    fail("imagined noise staging requires Float32 or Float64")
  }
}

///|
fn stage_noise_values(
  batch : Int32,
  widths : Array[Double],
  draw : () -> Double,
  limits : BatchLimits,
  max_bytes : Int64,
) -> Array[Double] raise {
  let dim = widths.length()
  ignore(noise_staging_usage(batch, dim, max_bytes~, limits~))
  let values = Array::make(batch * dim, 0.0)
  for begin = 0; begin < batch; {
    let count = (batch - begin).min(ReferenceBlockSamples)
    // Match the old Array::makei evaluation order and complete the entire
    // current block before checking finite values. Early per-element failure
    // would incorrectly consume fewer RNG draws than the original upload path.
    let block = Array::makei(count * dim, i => {
      (draw() * 2.0 - 1.0) * widths[i % dim]
    })
    @tensor.profile_span("batch.validate_values", () => {
      guard block.all(@numeric.finite) else {
        fail("GPU batch contains nonfinite values")
      }
    })
    for i, value in block {
      values[begin * dim + i] = value
    }
    continue begin + count
  }
  values
}

///|
fn staged_step_noise(
  backend : @tensor.Backend,
  batch : Int32,
  widths : Array[Double],
  draw : () -> Double,
  device : Int32,
  dtype : @tensor.DType,
  limits : BatchLimits,
  max_bytes : Int64,
) -> @tensor.Tensor raise {
  check_noise_staging(batch, widths.length(), dtype, limits, max_bytes)
  let values = stage_noise_values(batch, widths, draw, limits, max_bytes)
  // Every private field was validated at the same RNG block boundary above.
  // Keep the original Float64-to-requested-dtype conversion; do not rescan.
  @tensor.profile_span("batch.upload", () => {
    backend.from_values(
      [batch, widths.length()],
      values,
      cuda_device=device,
      requires_grad=false,
      dtype~,
    )
  })
}
