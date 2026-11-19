///|
fn input_value(index : Int32, side : Int32) -> Double {
  // Exactly representable in both Float32 and Float64, with sub-TF32 mantissa
  // bits. No RNG and no precision difference introduced by host conversion.
  let coarse = ((index * (17 + side * 6) + 13 * side) % 4093 - 2046).to_double() /
    2048.0
  let fine = ((index + side) % 31).to_double() / 1048576.0
  coarse + fine
}

///|
fn verify_setting(
  settings : @tensor.CudaFp32Settings,
  matmul : Bool,
  conv : Bool,
  rnn : Bool,
) -> Unit raise {
  guard settings.matmul_precision ==
    (if matmul { @tensor.TF32 } else { @tensor.IEEE }) &&
    settings.cudnn_conv_precision ==
    (if conv { @tensor.TF32 } else { @tensor.IEEE }) &&
    settings.cudnn_rnn_precision ==
    (if rnn { @tensor.TF32 } else { @tensor.IEEE }) else {
    fail("TF32 per-op readback does not match the request")
  }
  if matmul {
    guard settings.matmul_permission == @tensor.LibraryMayUse else {
      fail("matmul TF32 runtime permission is blocked or unconfirmed")
    }
  }
}

///|
fn require_late_refusal(backend : @tensor.Backend) -> Unit raise {
  let before = backend.cuda_fp32_settings()
  guard before.startup_configuration_locked else {
    fail("tensor creation did not close startup scope")
  }
  try
    backend.configure_cuda_tf32(
      matmul=false,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=true,
    )
  catch {
    @tensor.TensorError::Native(message) => {
      guard message.contains("startup window closed") else {
        fail("wrong late-setting refusal: " + message)
      }
    }
  } noraise {
    _ => fail("late global precision mutation was not refused")
  }
  guard backend.cuda_fp32_settings() == before else {
    fail("late refusal changed settings")
  }
}

///|
fn compare_values(
  actual : Array[Double],
  reference : Array[Double],
) -> Json raise {
  guard actual.length() == reference.length() && actual.length() == 65536 else {
    fail("matmul probe output shape mismatch")
  }
  let mut max_abs = 0.0
  let mut diff_squared = 0.0
  let mut reference_squared = 0.0
  for i in 0..<actual.length() {
    guard !actual[i].is_nan() &&
      !actual[i].is_inf() &&
      !reference[i].is_nan() &&
      !reference[i].is_inf() else {
      fail("nonfinite matmul probe result")
    }
    let difference = actual[i] - reference[i]
    max_abs = max_abs.max(difference.abs())
    diff_squared += difference * difference
    reference_squared += reference[i] * reference[i]
  }
  guard reference_squared > 0.0 else { fail("zero reference norm") }
  let relative_l2 = (diff_squared / reference_squared).sqrt()
  // Fixed broad smoke bound, not the training/microbatch equivalence tolerance.
  guard relative_l2 <= 0.005 else {
    fail("matmul smoke relative L2 error exceeds 0.005")
  }
  {
    "values_compared": 65536,
    "max_absolute_error": Json(max_abs),
    "rms_error": Json((diff_squared / 65536.0).sqrt()),
    "relative_l2_error": Json(relative_l2),
    "smoke_relative_l2_limit": 0.005,
    "reference": "CUDA Float64 matmul of exactly the same representable inputs",
    "first_output": Json(actual[0]),
    "first_reference": Json(reference[0]),
    "training_equivalence_claimed": false,
    "kernel_tf32_proven": false,
  }
}

///|
fn run_probe() -> Unit raise {
  let args = @env.args()
  guard args.length() == 3 &&
    ["ieee", "tf32-matmul", "tf32-all", "override-negative"].contains(args[2]) else {
    fail(
      "usage: tf32_probe /absolute/plugin.so ieee|tf32-matmul|tf32-all|override-negative",
    )
  }
  let mode = args[2]
  let backend = @tensor.Backend::open(args[1])
  guard backend.has_cuda_fp32_control() else {
    fail("plugin lacks CUDA FP32 control extension")
  }
  let initial = backend.cuda_fp32_settings()
  guard !initial.startup_configuration_locked else {
    fail("probe requires a fresh process")
  }
  try
    backend.configure_cuda_tf32(
      matmul=false,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=false,
    )
  catch {
    @tensor.TensorError::Native(message) => {
      guard message.contains("before_first_tensor=true") else {
        fail("wrong missing-ack refusal")
      }
    }
  } noraise {
    _ => fail("startup acknowledgement unexpectedly optional")
  }
  if mode == "override-negative" {
    guard initial.nvidia_tf32_override == "0" else {
      fail("negative mode requires NVIDIA_TF32_OVERRIDE=0 before launch")
    }
    try
      backend.configure_cuda_tf32(
        matmul=true,
        cudnn_conv=true,
        cudnn_rnn=true,
        before_first_tensor=true,
      )
    catch {
      @tensor.TensorError::Native(message) => {
        guard message.contains("NVIDIA_TF32_OVERRIDE=0 blocks requested TF32") else {
          fail("wrong override refusal: " + message)
        }
      }
    } noraise {
      _ => fail("runtime override conflict was not refused")
    }
    guard backend.cuda_fp32_settings() == initial else {
      fail("conflict refusal changed precision")
    }
    let configured = backend.configure_cuda_tf32(
      matmul=false,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=true,
    )
    verify_setting(configured, false, false, false)
    let leaf = backend.from_values(
      [1],
      [2.0],
      cuda_device=0,
      requires_grad=false,
      dtype=Float32,
    )
    guard leaf.square().values() == [4.0] else {
      fail("GPU arithmetic failed after conflict refusal")
    }
    require_late_refusal(@tensor.Backend::open(args[1]))
    let report : Json = {
      "format": "moonrobo.cuda-tf32-probe.v1",
      "status": "passed",
      "mode": Json(mode),
      "torch_version": Json(backend.version()),
      "initial": Json(initial),
      "configured": Json(configured),
      "override_conflict_refused_without_mutation": true,
      "subsequent_gpu_tensor_verified": true,
      "all_backend_startup_lock_verified": true,
      "kernel_tf32_proven": false,
    }
    println(report.stringify())
    return
  }
  let matmul = mode != "ieee"
  let cudnn = mode == "tf32-all"
  let configured = backend.configure_cuda_tf32(
    matmul~,
    cudnn_conv=cudnn,
    cudnn_rnn=cudnn,
    before_first_tensor=true,
  )
  verify_setting(configured, matmul, cudnn, cudnn)
  let second_backend = @tensor.Backend::open(args[1])
  guard second_backend.cuda_fp32_settings() == configured else {
    fail("Backend handles disagree on global settings")
  }
  let left = Array::makei(65536, i => input_value(i, 0))
  let right = Array::makei(65536, i => input_value(i, 1))
  let a = backend.from_values(
    [256, 256],
    left,
    cuda_device=0,
    requires_grad=false,
    dtype=Float32,
  )
  let b = backend.from_values(
    [256, 256],
    right,
    cuda_device=0,
    requires_grad=false,
    dtype=Float32,
  )
  let actual = a.matmul(b).values()
  let reference_a = backend.from_values(
    [256, 256],
    left,
    cuda_device=0,
    requires_grad=false,
    dtype=Float64,
  )
  let reference_b = backend.from_values(
    [256, 256],
    right,
    cuda_device=0,
    requires_grad=false,
    dtype=Float64,
  )
  let reference = reference_a.matmul(reference_b).values()
  let numerical = compare_values(actual, reference)
  require_late_refusal(second_backend)
  let report : Json = {
    "format": "moonrobo.cuda-tf32-probe.v1",
    "status": "passed",
    "mode": Json(mode),
    "torch_version": Json(backend.version()),
    "device": 0,
    "shape": [256, 256, 256],
    "initial": Json(initial),
    "configured": Json(configured),
    "after": Json(backend.cuda_fp32_settings()),
    "numerical": numerical,
    "all_backend_startup_lock_verified": true,
    "missing_startup_ack_refused": true,
    "cudnn_kernels_executed": false,
    "kernel_tf32_proven": false,
    "training_executed": false,
    "scope": "independent startup configuration and bounded matmul smoke; no kernel-dispatch or speed claim",
  }
  println(report.stringify())
}

///|
fn main {
  run_probe() catch {
    error => {
      println(
        Json({
          "format": "moonrobo.cuda-tf32-probe.v1",
          "status": "failed",
          "error": error.to_string(),
        }).stringify(),
      )
      abort(error.to_string())
    }
  }
}
