///|
fn check_values(actual : Array[Double], expected : Array[Double]) -> Unit raise {
  guard actual == expected else {
    fail("profiling changed fixed Float32 forward or gradient values")
  }
  guard actual.all(value => !value.is_nan() && !value.is_inf()) else {
    fail("probe observed nonfinite arithmetic")
  }
}

///|
fn forward_backward(
  backend : @tensor.Backend,
  device : Int32,
) -> (@tensor.Tensor, @tensor.Tensor) raise {
  let x = @tensor.profile_span("probe.upload", () => {
    backend.from_values(
      [2, 3],
      [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
      cuda_device=device,
      requires_grad=true,
      dtype=Float32,
    )
  })
  let loss = @tensor.profile_span("probe.forward", () => x.square().mean())
  @tensor.profile_span("probe.backward", () => loss.backward())
  (x, loss)
}

///|
fn validate_report(report : Json, cuda : Bool, complete : Bool) -> Int32 raise {
  guard report
    is {
      "schema": String("moonrobo.execution-profile.v1"),
      "enabled": True,
      "synchronized": False,
      "max_spans": Number(6),
      "recorded_spans": Number(6),
      "dropped_spans": Number(1),
      "open_spans": Number(0),
      "spans": Array(spans),
      ..
    } else {
    fail("profile schema, cap, drop count, or closed nesting mismatch")
  }
  guard spans.length() == 6 else { fail("unexpected recorded span count") }
  let mut completed = 0
  for i, span in spans {
    guard span
      is {
        "id": Number(id),
        "parent_id": Number(parent),
        "cpu_start_us": Number(start),
        "cpu_submit_us": Number(elapsed),
        "cpu_inclusive": True,
        ..
      } else {
      fail("span lacks CPU interval and nesting metadata: " + span.stringify())
    }
    guard id == (i + 1).to_double() &&
      parent == (if i == 0 { 0.0 } else { 1.0 }) &&
      start >= 0.0 &&
      elapsed >= 0.0 &&
      !start.is_inf() &&
      !elapsed.is_inf() else {
      fail("invalid CPU interval or parent ID")
    }
    if i == 4 {
      guard span
        is {
          "cancelled": True,
          "gpu_status": String("cancelled"),
          "gpu_elapsed_ms": Null,
          ..
        } else {
        fail("cancelled scope was reported as complete")
      }
    } else if !cuda {
      guard span
        is {
          "cancelled": False,
          "stream_id": Null,
          "gpu_status": String("disabled"),
          "gpu_elapsed_ms": Null,
          ..
        } else {
        fail("CPU probe invented CUDA measurements")
      }
    } else {
      guard span is { "stream_id": String(_), "cancelled": False, .. } else {
        fail("CUDA interval has no current-stream identity")
      }
      match span {
        { "gpu_status": String("complete"), "gpu_elapsed_ms": Number(ms), .. } => {
          guard ms >= 0.0 && !ms.is_inf() else {
            fail("invalid CUDA elapsed interval")
          }
          completed += 1
        }
        { "gpu_status": String("pending"), "gpu_elapsed_ms": Null, .. } => {
          guard !complete else {
            fail("CUDA interval remains pending after explicit probe boundary")
          }
        }
        _ => fail("invalid CUDA completion status")
      }
    }
  }
  completed
}

///|
fn run_probe() -> Unit raise {
  let args = @env.args()
  guard args.length() == 3 && ["cpu", "cuda"].contains(args[2]) else {
    fail("usage: profile_probe /absolute/plugin.so cpu|cuda (CUDA device 0)")
  }
  let cuda = args[2] == "cuda"
  let device = if cuda { 0 } else { -1 }
  let backend = @tensor.Backend::open(args[1])
  let free_before : Int64? = if cuda {
    guard backend.cuda_device_count() > 0 else {
      fail("CUDA mode requires an actual accessible CUDA device")
    }
    guard backend.has_cuda_memory_telemetry() else {
      fail("CUDA mode needs the explicit final synchronization boundary")
    }
    let available = backend.cuda_free_bytes(0)
    guard available >= 1073741824L else {
      fail("bounded probe requires at least 1 GiB CUDA free memory")
    }
    Some(available)
  } else {
    None
  }
  guard !@tensor.profiling_enabled() else {
    fail("probe needs a fresh session")
  }
  let (baseline_x, baseline_loss) = forward_backward(backend, device)
  let baseline_values = baseline_loss.values()
  let baseline_gradient = baseline_x.gradient_values()
  guard baseline_values.length() == 1 &&
    (baseline_values[0] - 91.0 / 6.0).abs() <= 0.000002 &&
    baseline_gradient.length() == 6 else {
    fail("fixed arithmetic baseline is incorrect")
  }
  for i in 0..<6 {
    guard (baseline_gradient[i] - (i + 1).to_double() / 3.0).abs() <= 0.000001 else {
      fail("fixed analytical gradient check failed")
    }
  }
  @tensor.configure_profiling(
    backend,
    cuda_device=device,
    max_spans=6,
    nvtx=true,
  )
  let parent = @tensor.profile_begin("probe.outer")
  errdefer @tensor.profile_cancel(parent)
  let (profiled_x, profiled_loss) = forward_backward(backend, device)
  try
    @tensor.profile_span("probe.cancelled", () => {
      fail("intentional probe failure")
    })
  catch {
    error => {
      guard error.to_string().contains("intentional probe failure") else {
        fail("profiling cleanup replaced the callback failure")
      }
    }
  } noraise {
    _ => fail("error cleanup probe unexpectedly returned")
  }
  let recovery = @tensor.profile_span("probe.recovery", () => {
    profiled_x.square()
  })
  @tensor.profile_end(parent)
  guard @tensor.profile_begin("probe.dropped") == 0L else {
    fail("profiling exceeded its bounded event capacity")
  }
  // This snapshot queries completion without waiting. It is valid for an
  // already-finished tiny workload to report zero pending intervals here.
  let before_boundary = @json.parse(@tensor.profiling_report())
  let completed_before = validate_report(before_boundary, cuda, false)
  let memory : Json = if cuda {
    // The ONLY explicit synchronization added by this standalone probe.
    // Training profiling itself has no implicit synchronization boundary.
    backend.cuda_memory_stats(0, synchronize=true).to_json()
  } else {
    Json::null()
  }
  let after_boundary = @json.parse(@tensor.profiling_report())
  let completed_after = validate_report(after_boundary, cuda, true)
  check_values(profiled_loss.values(), baseline_values)
  check_values(profiled_x.gradient_values(), baseline_gradient)
  check_values(recovery.values(), [1.0, 4.0, 9.0, 16.0, 25.0, 36.0])
  @tensor.clear_profiling()
  guard !@tensor.profiling_enabled() else {
    fail("profiling session did not clear")
  }
  let report : Json = {
    "format": "moonrobo.execution-profile-probe.v1",
    "status": "passed",
    "mode": Json(args[2]),
    "torch_version": Json(backend.version()),
    "device": Json(device),
    "shape": [2, 3],
    "dtype": "Float32",
    "profiled_forward_gradient_exactly_match_unprofiled": true,
    "analytical_forward_gradient_checked": true,
    "error_cleanup_and_subsequent_math_checked": true,
    "max_spans": 6,
    "cuda_event_count_bound": Json(if cuda { 12 } else { 0 }),
    "cuda_free_before_bytes": Json(free_before),
    "explicit_probe_sync_boundaries": Json(if cuda { 1 } else { 0 }),
    "completed_gpu_intervals_before_boundary": Json(completed_before),
    "completed_gpu_intervals_after_boundary": Json(completed_after),
    "profile_before_boundary": before_boundary,
    "profile_after_boundary": after_boundary,
    "memory_at_boundary": memory,
    "training_executed": false,
    "speed_claimed": false,
  }
  println(report.stringify())
}

///|
fn main {
  run_probe() catch {
    error => {
      println(
        Json({
          "format": "moonrobo.execution-profile-probe.v1",
          "status": "failed",
          "error": error.to_string(),
        }).stringify(),
      )
      abort(error.to_string())
    }
  }
}
