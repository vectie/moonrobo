///|
extern "C" fn diagnostic_exit(code : Int32) -> Unit = "exit"

///|
let diagnostic_phase : Ref[String] = Ref::new("arguments")

///|
// Independent diagnostic only: this package never changes production geometry.
fn angle_values(
  backend : @tensor.Backend,
  a : @tensor.Tensor,
  b : @tensor.Tensor,
  smc : Bool,
) -> @tensor.Tensor raise {
  if smc {
    a
    .mul(b)
    .sum_dim(-1)
    .sum_dim(-1)
    .affine(0.5, bias=-0.5)
    .clamp(-1.0 + 1.0e-6, 1.0 - 1.0e-6)
    .acos()
    .square()
  } else {
    @geometry.so3_log(backend, a.matmul(b.transpose_dims(1, 2)))
    .square()
    .sum_dim(1)
  }
}

///|
fn input_values(rows : Int32) -> (Array[Double], Array[Double]) {
  let angles = [0.0, 0.0001, 0.02, 0.4, 1.2, 2.9, @math.PI - 0.0001, @math.PI]
  let a : Array[Double] = []
  let b : Array[Double] = []
  for i in 0..<rows {
    let base = @aligned.so3_exp([
      0.1 * (i % 3).to_double(),
      -0.2,
      0.05 * (i % 5).to_double(),
    ])
    a.append(
      @aligned.mat_mul(base, @aligned.so3_exp([0.0, 0.0, angles[i % 8]])),
    )
    b.append(base)
  }
  (a, b)
}

///|
fn finite_values(values : Array[Double]) -> Unit raise {
  guard values.all(x => !x.is_nan() && !x.is_inf()) else {
    fail("nonfinite orientation value or input gradient")
  }
}

///|
fn maximum_difference(a : Array[Double], b : Array[Double]) -> Double raise {
  guard a.length() == b.length() else { fail("different comparison shapes") }
  let mut result = 0.0
  for i in 0..<a.length() {
    result = result.max((a[i] - b[i]).abs())
  }
  result
}

///|
fn memory_boundary(backend : @tensor.Backend, device : Int32) -> Json raise {
  if device < 0 {
    return Json::null()
  }
  let memory = backend.cuda_memory_stats(device, synchronize=true)
  guard memory.cuda_free_bytes >= 17179869184L else {
    fail("orientation diagnostic reserve refused: less than 16 GiB CUDA free")
  }
  Json(memory)
}

///|
fn one_sample(
  backend : @tensor.Backend,
  device : Int32,
  a : @tensor.Tensor,
  b : @tensor.Tensor,
  smc : Bool,
  label : String,
  measured : Bool,
) -> Json raise {
  a.zero_gradient()
  b.zero_gradient()
  ignore(memory_boundary(backend, device))
  let total = if measured {
    @tensor.profile_begin(label + ".total")
  } else {
    0L
  }
  errdefer @tensor.profile_cancel(total)
  let forward = if measured {
    @tensor.profile_begin(label + ".forward")
  } else {
    0L
  }
  errdefer @tensor.profile_cancel(forward)
  let values = angle_values(backend, a, b, smc)
  let loss = values.mean()
  @tensor.profile_end(forward)
  let backward = if measured {
    @tensor.profile_begin(label + ".backward")
  } else {
    0L
  }
  errdefer @tensor.profile_cancel(backward)
  loss.backward()
  @tensor.profile_end(backward)
  @tensor.profile_end(total)
  // The explicit boundary follows all event markers. Readbacks and checks are
  // outside measured intervals. Nothing from this autograd graph is returned.
  let memory = memory_boundary(backend, device)
  let value = loss.values()
  let ga = a.gradient_values()
  let gb = b.gradient_values()
  finite_values(value)
  finite_values(ga)
  finite_values(gb)
  {
    "label": Json(label),
    "formula": Json(
      if smc {
        "smc_clamped_acos"
      } else {
        "native_quaternion_log"
      },
    ),
    "loss": Json(value[0]),
    "gradient_a_abs_max": Json(ga.fold(init=0.0, (x, y) => x.max(y.abs()))),
    "gradient_b_abs_max": Json(gb.fold(init=0.0, (x, y) => x.max(y.abs()))),
    "finite_values_and_both_gradients": true,
    "memory_after_synchronized_sample": memory,
  }
}

///|
fn numerical_differences(
  backend : @tensor.Backend,
  device : Int32,
) -> Json raise {
  let (av, bv) = input_values(8)
  let a = backend.from_values(
    [8, 3, 3],
    av,
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let b = backend.from_values(
    [8, 3, 3],
    bv,
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let native = angle_values(backend, a, b, false)
  native.mean().backward()
  let native_values = native.values()
  let native_ga = a.gradient_values()
  let native_gb = b.gradient_values()
  a.zero_gradient()
  b.zero_gradient()
  let smc = angle_values(backend, a, b, true)
  smc.mean().backward()
  let smc_values = smc.values()
  let smc_ga = a.gradient_values()
  let smc_gb = b.gradient_values()
  for
    values in [native_values, native_ga, native_gb, smc_values, smc_ga, smc_gb] {
    finite_values(values)
  }
  {
    "relative_angles_radians": Json([
      0.0,
      0.0001,
      0.02,
      0.4,
      1.2,
      2.9,
      @math.PI - 0.0001,
      @math.PI,
    ]),
    "native_angle_squared": Json(native_values),
    "smc_angle_squared": Json(smc_values),
    "maximum_absolute_value_difference": Json(
      maximum_difference(native_values, smc_values),
    ),
    "maximum_absolute_matrix_gradient_a_difference": Json(
      maximum_difference(native_ga, smc_ga),
    ),
    "maximum_absolute_matrix_gradient_b_difference": Json(
      maximum_difference(native_gb, smc_gb),
    ),
    "gradient_scope": "ambient 3x3 matrix leaves, mean of eight angle-squared values; not SO(3) tangent derivatives",
    "equivalent_semantics_claimed": false,
  }
}

///|
fn validate_profile(report : Json, device : Int32) -> Unit raise {
  guard report
    is {
      "recorded_spans": Number(60),
      "dropped_spans": Number(0),
      "open_spans": Number(0),
      "spans": Array(spans),
      ..
    } else {
    fail("orientation diagnostic profile incomplete")
  }
  for span in spans {
    if device >= 0 {
      guard span
        is {
          "gpu_status": String("complete"),
          "gpu_elapsed_ms": Number(ms),
          ..
        } &&
        ms >= 0.0 &&
        !ms.is_inf() else {
        fail("orientation event did not complete with a finite duration")
      }
    }
  }
}

///|
fn timing_summary(report : Json, device : Int32) -> Json raise {
  guard report is { "spans": Array(spans), .. } else {
    fail("profile spans absent")
  }
  let totals = Array::make(20, 0.0)
  let forwards = Array::make(20, 0.0)
  let backwards = Array::make(20, 0.0)
  let field = if device >= 0 { "gpu_elapsed_ms" } else { "cpu_submit_us" }
  for span in spans {
    guard span is Object(fields) &&
      fields.get("label") is Some(String(label)) &&
      fields.get(field) is Some(Number(duration, ..)) else {
      fail("measured span incomplete")
    }
    let parts = label.split(".").to_array()
    guard parts.length() == 3 && parts[0] == "sample" else {
      fail("invalid sample label")
    }
    let index = @string.parse_int(parts[1])
    guard index >= 0 && index < 20 else { fail("invalid sample index") }
    let ms = if device >= 0 { duration } else { duration / 1000.0 }
    match parts[2] {
      "total" => totals[index] = ms
      "forward" => forwards[index] = ms
      "backward" => backwards[index] = ms
      _ => fail("invalid sample phase")
    }
  }
  let averages = (values : Array[Double]) => {
    let mut a = 0.0
    let mut b = 0.0
    for i, value in values {
      if i % 4 == 1 || i % 4 == 2 {
        b += value
      } else {
        a += value
      }
    }
    (a / 10.0, b / 10.0)
  }
  let (na, sa) = averages(totals)
  let (nf, sf) = averages(forwards)
  let (nb, sb) = averages(backwards)
  let pairs : Array[Json] = []
  for i in 0..<5 {
    for (a, b) in [(4 * i, 4 * i + 1), (4 * i + 3, 4 * i + 2)] {
      guard totals[b] > 0.0 else {
        fail("zero candidate interval cannot form ratio")
      }
      pairs.push({
        "native_sample": Json(a),
        "smc_sample": Json(b),
        "native_total_ms": Json(totals[a]),
        "smc_total_ms": Json(totals[b]),
        "native_over_smc_ratio": Json(totals[a] / totals[b]),
      })
    }
  }
  {
    "clock": Json(
      if device >= 0 {
        "CUDA events"
      } else {
        "CPU submission only; not GPU duration"
      },
    ),
    "native_total_mean_ms": Json(na),
    "smc_total_mean_ms": Json(sa),
    "native_forward_mean_ms": Json(nf),
    "smc_forward_mean_ms": Json(sf),
    "native_backward_mean_ms": Json(nb),
    "smc_backward_mean_ms": Json(sb),
    "pairs": Json(pairs),
    "inclusive_totals_not_added_to_child_intervals": true,
    "scope": "two eager LibTorch formulas; not Python torch.compile or full training throughput",
  }
}

///|
fn run() -> Unit raise {
  let args = @env.args()
  guard args.length() == 4 && ["cpu", "cuda"].contains(args[2]) else {
    fail("usage: orientation_bench /absolute/plugin.so cpu|cuda rows(8..57344)")
  }
  let rows = @string.parse_int(args[3])
  guard rows >= 8 && rows <= 57344 else {
    fail("rows outside bounded 8..57344")
  }
  let device = if args[2] == "cuda" { 0 } else { -1 }
  diagnostic_phase.val = "open_backend"
  let backend = @tensor.Backend::open(args[1])
  if device >= 0 {
    diagnostic_phase.val = "cuda_capability"
    guard backend.cuda_device_count() > 0 && backend.has_cuda_memory_telemetry() else {
      fail("CUDA diagnostic needs device and allocator telemetry")
    }
    guard backend.has_cuda_fp32_control() else {
      fail("CUDA diagnostic requires explicit TF32 setting")
    }
    diagnostic_phase.val = "configure_tf32"
    ignore(
      backend.configure_cuda_tf32(
        matmul=true,
        cudnn_conv=true,
        cudnn_rnn=true,
        before_first_tensor=true,
      ),
    )
    // The allocator telemetry capability can exist before ATen creates its
    // device allocator. Initialize it with one value, outside every timing
    // interval, before asking for the first synchronized memory snapshot.
    diagnostic_phase.val = "initialize_cuda_allocator"
    ignore(
      backend
      .from_values(
        [1],
        [0.0],
        cuda_device=device,
        dtype=Float32,
        requires_grad=false,
      )
      .values(),
    )
  }
  diagnostic_phase.val = "initial_memory_boundary"
  let before = memory_boundary(backend, device)
  diagnostic_phase.val = "numerical_differences"
  let differences = numerical_differences(backend, device)
  diagnostic_phase.val = "input_preparation"
  let (av, bv) = input_values(rows)
  let a = backend.from_values(
    [rows, 3, 3],
    av,
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let b = backend.from_values(
    [rows, 3, 3],
    bv,
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  // Warm both routes equally. Repeated forward/backward graphs are discarded
  // within one_sample, and neither formula retains a 32-step training rollout.
  for i in 0..<4 {
    diagnostic_phase.val = "warmup.\{i}"
    ignore(
      one_sample(
        backend,
        device,
        a,
        b,
        i % 4 == 1 || i % 4 == 2,
        "warmup",
        false,
      ),
    )
  }
  if device >= 0 {
    diagnostic_phase.val = "reset_cuda_peaks"
    backend.reset_cuda_memory_peaks(device, synchronize=true)
  }
  diagnostic_phase.val = "configure_profile"
  @tensor.configure_profiling(
    backend,
    cuda_device=device,
    max_spans=60,
    nvtx=false,
  )
  errdefer (@tensor.clear_profiling() catch { _ => () })
  let samples : Array[Json] = []
  for i in 0..<20 {
    diagnostic_phase.val = "sample.\{i}"
    let smc = i % 4 == 1 || i % 4 == 2
    samples.push(one_sample(backend, device, a, b, smc, "sample.\{i}", true))
  }
  let after = memory_boundary(backend, device)
  diagnostic_phase.val = "validate_and_report"
  let profile = @json.parse(@tensor.profiling_report())
  validate_profile(profile, device)
  @tensor.clear_profiling()
  let report : Json = {
    "format": "moonrobo.orientation-primitive-benchmark.v1",
    "status": "passed",
    "device": Json(args[2]),
    "torch_version": Json(backend.version()),
    "dtype": "Float32",
    "tf32_allowed_cuda": Json(device >= 0),
    "rows": Json(rows),
    "matrix_shape": Json([rows, 3, 3]),
    "ordering": "ABBA repeated five times; A native quaternion log, B SMC clamped acos",
    "measured_samples": 20,
    "warmup_samples": 4,
    "cuda_event_capacity": 120,
    "minimum_cuda_free_bytes": "17179869184",
    "numerical_differences": differences,
    "samples": Json(samples),
    "profile": profile,
    "timing_summary": timing_summary(profile, device),
    "memory_before": before,
    "memory_after": after,
    "timing_scope": "forward including loss reduction; backward; inclusive total; readbacks/finite checks/sync outside event intervals; CUDA intervals include stream waits and launch gaps",
    "memory_scope": "process CUDA allocator plus cudaMemGetInfo; host/cgroup safety remains caller responsibility",
    "equivalent_training_semantics_claimed": false,
    "training_speedup_claimed": false,
    "production_geometry_changed": false,
  }
  println(report.stringify())
}

///|
fn main {
  run() catch {
    error => {
      let message = match error {
        @tensor.TensorError::Native(message) => message
        _ => error.to_string()
      }
      println(
        Json({
          "format": "moonrobo.orientation-primitive-benchmark.v1",
          "status": "failed",
          "phase": diagnostic_phase.val,
          "error": message,
        }).stringify(),
      )
      // libc exit flushes buffered stdout and returns a nonzero process status.
      // abort() can discard the only checked-error diagnostic under timeout.
      diagnostic_exit(1)
    }
  }
}
