///|
pub(all) enum Fp32Precision {
  BackendDefault
  IEEE
  TF32
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Permission is not proof that a particular kernel used TF32 tensor cores.
pub(all) enum TF32Permission {
  ContextDisallows
  RuntimeOverrideBlocks
  LibraryMayUse
  OverrideUnconfirmed
  BackendUnavailable
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct CudaFp32Settings {
  matmul_precision : Fp32Precision
  cudnn_conv_precision : Fp32Precision
  cudnn_rnn_precision : Fp32Precision
  nvidia_tf32_override : String
  torch_allow_tf32_cublas_override : String
  cudnn_available : Bool
  startup_configuration_locked : Bool
  matmul_permission : TF32Permission
  cudnn_conv_permission : TF32Permission
  cudnn_rnn_permission : TF32Permission
} derive(Eq, Debug, ToJson, FromJson)

///|
#borrow(backend)
extern "c" fn has_cuda_fp32_native(backend : Backend) -> Int32 = "mr_tensor_has_cuda_fp32_control"

///|
#borrow(backend, output)
extern "c" fn cuda_fp32_settings_native(
  backend : Backend,
  output : FixedArray[Int32],
) -> Int32 = "mr_tensor_cuda_fp32_settings_call"

///|
#borrow(backend, output)
extern "c" fn configure_cuda_tf32_native(
  backend : Backend,
  matmul : Int32,
  conv : Int32,
  rnn : Int32,
  startup : Int32,
  output : FixedArray[Int32],
) -> Int32 = "mr_tensor_configure_cuda_tf32_call"

///|
fn fp32_precision(code : Int32) -> Fp32Precision raise TensorError {
  match code {
    0 => BackendDefault
    1 => IEEE
    2 => TF32
    _ => raise Native("invalid native FP32 precision code")
  }
}

///|
fn fp32_override(code : Int32) -> String raise TensorError {
  match code {
    -1 => "unset"
    0 => "0"
    1 => "1"
    _ => raise Native("invalid native TF32 override code")
  }
}

///|
fn fp32_permission(
  precision : Fp32Precision,
  nvidia : Int32,
  torch_force : Bool,
  available : Bool,
) -> TF32Permission {
  if !available {
    return BackendUnavailable
  }
  if nvidia == 0 {
    return RuntimeOverrideBlocks
  }
  if nvidia == 1 || (torch_force && precision != TF32) {
    return OverrideUnconfirmed
  }
  if precision == TF32 {
    LibraryMayUse
  } else {
    ContextDisallows
  }
}

///|
fn cuda_fp32_decode(
  values : FixedArray[Int32],
) -> CudaFp32Settings raise TensorError {
  let matmul = fp32_precision(values[0])
  let conv = fp32_precision(values[1])
  let rnn = fp32_precision(values[2])
  let nvidia = fp32_override(values[3])
  let torch_override = fp32_override(values[4])
  guard (values[5] == 0 || values[5] == 1) && (values[6] == 0 || values[6] == 1) else {
    raise Native("invalid native FP32 capability flags")
  }
  let cudnn = values[5] == 1
  {
    matmul_precision: matmul,
    cudnn_conv_precision: conv,
    cudnn_rnn_precision: rnn,
    nvidia_tf32_override: nvidia,
    torch_allow_tf32_cublas_override: torch_override,
    cudnn_available: cudnn,
    startup_configuration_locked: values[6] == 1,
    matmul_permission: fp32_permission(matmul, values[3], values[4] == 1, true),
    cudnn_conv_permission: fp32_permission(conv, values[3], false, cudnn),
    cudnn_rnn_permission: fp32_permission(rnn, values[3], false, cudnn),
  }
}

///|
/// Checks optional symbols only, not CUDA availability or supported Torch version.
pub fn Backend::has_cuda_fp32_control(self : Backend) -> Bool {
  has_cuda_fp32_native(self) != 0
}

///|
/// Reads actual per-op Context settings plus fixed-at-load environment overrides.
/// No flags are changed. A LibraryMayUse result is permission, not kernel proof.
pub fn Backend::cuda_fp32_settings(
  self : Backend,
) -> CudaFp32Settings raise TensorError {
  let output = FixedArray::make(7, 0)
  ignore(cuda_fp32_settings_native(self, output))
  self.check()
  cuda_fp32_decode(output)
}

///|
/// Changes process-global LibTorch precision before this plugin creates any
/// tensor (CPU or GPU), across all Backend handles. Requires explicit startup
/// acknowledgement. Caller must exclude external/concurrent LibTorch activity,
/// legacy flag changes, and environment mutation; these cannot all be intercepted.
/// Uses only Torch 2.11 per-op API and verifies all three settings before return.
/// Defaults are never changed by Backend::open or ordinary tensor operations.
pub fn Backend::configure_cuda_tf32(
  self : Backend,
  matmul~ : Bool,
  cudnn_conv~ : Bool,
  cudnn_rnn~ : Bool,
  before_first_tensor~ : Bool,
) -> CudaFp32Settings raise TensorError {
  let output = FixedArray::make(7, 0)
  ignore(
    configure_cuda_tf32_native(
      self,
      if matmul {
        1
      } else {
        0
      },
      if cudnn_conv {
        1
      } else {
        0
      },
      if cudnn_rnn {
        1
      } else {
        0
      },
      if before_first_tensor {
        1
      } else {
        0
      },
      output,
    ),
  )
  self.check()
  cuda_fp32_decode(output)
}
