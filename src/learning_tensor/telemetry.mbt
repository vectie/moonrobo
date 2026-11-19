///|
/// An active allocator/pool snapshot, in bytes. Peaks are since its
/// initialization or the last explicit peak reset by any caller in this process.
/// CUDA free/total are device-wide runtime observations, not allocator counters.
/// The two sources are sampled sequentially; this is not an atomic global view.
pub(all) struct CudaMemoryStats {
  device : Int32
  synchronized : Bool
  allocated_current_bytes : Int64
  allocated_peak_bytes : Int64
  reserved_current_bytes : Int64
  reserved_peak_bytes : Int64
  cuda_free_bytes : Int64
  cuda_total_bytes : Int64
} derive(Eq, Debug, ToJson, FromJson)

///|
#borrow(backend)
extern "c" fn has_cuda_telemetry_native(backend : Backend) -> Int32 = "mr_tensor_has_cuda_memory_telemetry"

///|
#borrow(backend, output)
extern "c" fn cuda_memory_stats_native(
  backend : Backend,
  device : Int32,
  synchronize : Int32,
  output : FixedArray[Int64],
) -> Int32 = "mr_tensor_cuda_memory_stats_call"

///|
#borrow(backend)
extern "c" fn cuda_reset_memory_peaks_native(
  backend : Backend,
  device : Int32,
  synchronize : Int32,
) -> Int32 = "mr_tensor_cuda_reset_memory_peaks_call"

///|
/// Whether both optional ABI symbols exist. This does not assert CUDA support,
/// an accessible GPU, or an initialized/supported allocator. Old plugins open
/// normally; attempting telemetry against them raises a checked missing error.
pub fn Backend::has_cuda_memory_telemetry(self : Backend) -> Bool {
  has_cuda_telemetry_native(self) != 0
}

///|
/// Reads aggregate current/peak allocated and reserved bytes without allocating
/// a tensor, resetting peaks, or emptying caches. By default it does not sync.
/// CPU, missing-extension and uninitialized/unsupported allocator calls raise.
/// Allocations outside the active allocator/pool are excluded. The native
/// allocator tracks LibTorch; cudaMallocAsync reports driver pool usage, which
/// can include another library sharing that pool.
/// Contract: caching is enabled and fixed for this process. Generic LibTorch
/// headers cannot verify external programmatic cache-disable/bypass operations.
pub fn Backend::cuda_memory_stats(
  self : Backend,
  device : Int32,
  synchronize~ : Bool = false,
) -> CudaMemoryStats raise TensorError {
  let values : FixedArray[Int64] = FixedArray::make(6, 0L)
  ignore(
    cuda_memory_stats_native(
      self,
      device,
      if synchronize {
        1
      } else {
        0
      },
      values,
    ),
  )
  self.check()
  {
    device,
    synchronized: synchronize,
    allocated_current_bytes: values[0],
    allocated_peak_bytes: values[1],
    reserved_current_bytes: values[2],
    reserved_peak_bytes: values[3],
    cuda_free_bytes: values[4],
    cuda_total_bytes: values[5],
  }
}

///|
/// Explicitly starts a process-wide allocator peak measurement window on one
/// device. Does not free memory or reset cumulative allocation counters. Other
/// users of this allocator share the reset. Sync defaults on to finish prior
/// work before reset; callers must invoke this outside CUDA graph capture.
pub fn Backend::reset_cuda_memory_peaks(
  self : Backend,
  device : Int32,
  synchronize~ : Bool = true,
) -> Unit raise TensorError {
  ignore(
    cuda_reset_memory_peaks_native(
      self,
      device,
      if synchronize {
        1
      } else {
        0
      },
    ),
  )
  self.check()
}
