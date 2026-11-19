///|
fn refusal_matches(message : String, uncached~ : Bool) -> Bool {
  if uncached {
    message.contains("uncached allocations bypass tracked statistics")
  } else {
    message.contains("allocator is unavailable or uninitialized") ||
    message.contains("selected device has no initialized primary context")
  }
}

///|
fn require_refusals(backend : @tensor.Backend, uncached~ : Bool) -> Unit raise {
  try backend.cuda_memory_stats(0) catch {
    @tensor.TensorError::Native(message) => {
      guard refusal_matches(message, uncached~) else {
        fail("unexpected telemetry refusal: " + message)
      }
    }
  } noraise {
    _ => fail("telemetry query unexpectedly succeeded in negative case")
  }
  try backend.reset_cuda_memory_peaks(0) catch {
    @tensor.TensorError::Native(message) => {
      guard refusal_matches(message, uncached~) else {
        fail("unexpected peak reset refusal: " + message)
      }
    }
  } noraise {
    _ => fail("telemetry peak reset unexpectedly succeeded in negative case")
  }
}

///|
fn with_live_allocation(
  backend : @tensor.Backend,
) -> @tensor.CudaMemoryStats raise {
  // Fixed 1 MiB GPU payload, bounded 2 MiB host Double input. No training.
  let values = Array::make(262144, 1.0)
  let tensor = backend.from_values(
    [262144],
    values,
    cuda_device=0,
    requires_grad=false,
    dtype=Float32,
  )
  let snapshot = backend.cuda_memory_stats(0, synchronize=true)
  // Use after query so the allocation is demonstrably still alive at sampling.
  guard tensor.sum().values() == [262144.0] else {
    fail("probe reduction mismatch")
  }
  snapshot
}

///|
fn main {
  try {
    let args = @env.args()
    guard args.length() == 2 ||
      (args.length() == 3 && args[2] == "--uncached-negative") else {
      fail(
        "usage: memory_probe /absolute/libmoonrobo_learning_tensor.so [--uncached-negative] (fixed CUDA device 0)",
      )
    }
    let backend = @tensor.Backend::open(args[1])
    guard backend.has_cuda_memory_telemetry() else {
      fail("plugin lacks CUDA memory telemetry extension")
    }
    guard backend.cuda_device_count() > 0 else {
      fail(
        "CUDA probe requires an actual accessible device; CPU is not a negative-case pass",
      )
    }
    if args.length() == 3 {
      guard @env.get_env_var("PYTORCH_NO_CUDA_MEMORY_CACHING") == Some("1") else {
        fail(
          "uncached negative mode requires PYTORCH_NO_CUDA_MEMORY_CACHING=1 before launch",
        )
      }
      require_refusals(backend, uncached=true)
      let leaf = backend.from_values(
        [1],
        [1.0],
        cuda_device=0,
        requires_grad=false,
        dtype=Float32,
      )
      guard leaf.square().values() == [1.0] else {
        fail("GPU tensor operation failed after refused telemetry")
      }
      let report : Json = {
        "format": "moonrobo.cuda-allocator-probe.v1",
        "status": "passed",
        "mode": "uncached-negative",
        "torch_version": Json(backend.version()),
        "query_refused_for_uncached_mode": true,
        "reset_refused_for_uncached_mode": true,
        "subsequent_gpu_tensor_verified": true,
        "programmatic_cache_disable_checked": false,
        "counters_reported": false,
      }
      println(report.stringify())
      return
    }
    require_refusals(backend, uncached=false)
    // Initialize the actual allocator before measurement. Keep this leaf alive
    // through the final sample; this is not a pre-allocation admission check.
    let anchor = backend.from_values(
      [1],
      [1.0],
      cuda_device=0,
      requires_grad=false,
      dtype=Float32,
    )
    let before = backend.cuda_memory_stats(0, synchronize=true)
    backend.reset_cuda_memory_peaks(0)
    let baseline = backend.cuda_memory_stats(0, synchronize=true)
    guard baseline.allocated_peak_bytes == baseline.allocated_current_bytes &&
      baseline.reserved_peak_bytes == baseline.reserved_current_bytes else {
      fail("peak reset did not establish the current baseline")
    }
    let live = with_live_allocation(backend)
    let released = backend.cuda_memory_stats(0, synchronize=true)
    guard live.allocated_current_bytes >=
      baseline.allocated_current_bytes + 1048576L &&
      released.allocated_current_bytes < live.allocated_current_bytes &&
      released.allocated_peak_bytes >= live.allocated_current_bytes &&
      live.reserved_current_bytes >= live.allocated_current_bytes else {
      fail(
        "CUDA allocator current/peak counters did not track the bounded live allocation",
      )
    }
    backend.reset_cuda_memory_peaks(0)
    let reset = backend.cuda_memory_stats(0, synchronize=true)
    guard reset.allocated_peak_bytes == reset.allocated_current_bytes &&
      reset.reserved_peak_bytes == reset.reserved_current_bytes else {
      fail("second peak reset did not preserve current counters")
    }
    guard anchor.values() == [1.0] else { fail("probe anchor changed") }
    let report : Json = {
      "format": "moonrobo.cuda-allocator-probe.v1",
      "torch_version": Json(backend.version()),
      "status": "passed",
      "mode": "allocation-and-uninitialized-negative",
      "uninitialized_query_and_reset_refused": true,
      "programmatic_cache_disable_checked": false,
      "caching_precondition": "enabled, fixed allocator configuration; external programmatic bypass unsupported",
      "payload_bytes": "1048576",
      "before": before.to_json(),
      "baseline": baseline.to_json(),
      "live": live.to_json(),
      "released": released.to_json(),
      "reset": reset.to_json(),
      "scope": "active allocator/pool; allocations outside that allocator/pool excluded; no training",
    }
    println(report.stringify())
  } catch {
    error => {
      println(
        Json({
          "format": "moonrobo.cuda-allocator-probe.v1",
          "status": "failed",
          "error": error.to_string(),
        }).stringify(),
      )
      abort(error.to_string())
    }
  }
}
