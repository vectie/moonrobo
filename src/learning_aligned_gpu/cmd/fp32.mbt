///|
// Stable Context/override evidence only. The transient startup lock is excluded
// from run identity, so post-allocation observations cannot change resume keys.
struct NativeFp32Policy {
  format : String
  allow_tf32 : Bool
  matmul_precision : @tensor.Fp32Precision
  cudnn_conv_precision : @tensor.Fp32Precision
  cudnn_rnn_precision : @tensor.Fp32Precision
  nvidia_tf32_override : String
  torch_allow_tf32_cublas_override : String
  cudnn_available : Bool
  matmul_permission : @tensor.TF32Permission
  cudnn_conv_permission : @tensor.TF32Permission
  cudnn_rnn_permission : @tensor.TF32Permission
} derive(Eq, Debug, ToJson, FromJson)

///|
fn fp32_request(config : Json) -> Bool? raise {
  guard config is Object(fields) else {
    fail("precision config must be object")
  }
  match fields.get("allow_tf32") {
    None => None
    Some(value) => Some(@json.from_json(value))
  }
}

///|
fn NativeFp32Policy::validate(self : NativeFp32Policy) -> Unit raise {
  let precision = if self.allow_tf32 { @tensor.TF32 } else { @tensor.IEEE }
  let permission = if self.nvidia_tf32_override == "0" {
    @tensor.RuntimeOverrideBlocks
  } else if self.allow_tf32 {
    @tensor.LibraryMayUse
  } else {
    @tensor.ContextDisallows
  }
  guard self.format == "moonrobo.native-cuda-fp32-policy.v1" &&
    self.cudnn_available &&
    ["unset", "0"].contains(self.nvidia_tf32_override) &&
    ["unset", "0", "1"].contains(self.torch_allow_tf32_cublas_override) &&
    (!self.allow_tf32 || self.nvidia_tf32_override == "unset") &&
    (self.allow_tf32 || self.torch_allow_tf32_cublas_override != "1") &&
    self.matmul_precision == precision &&
    self.cudnn_conv_precision == precision &&
    self.cudnn_rnn_precision == precision &&
    self.matmul_permission == permission &&
    self.cudnn_conv_permission == permission &&
    self.cudnn_rnn_permission == permission else {
    fail(
      "CUDA FP32 policy request, resolved per-op settings or runtime overrides disagree",
    )
  }
}

///|
fn fp32_policy_from_settings(
  requested : Bool,
  actual : @tensor.CudaFp32Settings,
) -> NativeFp32Policy raise {
  let policy : NativeFp32Policy = {
    format: "moonrobo.native-cuda-fp32-policy.v1",
    allow_tf32: requested,
    matmul_precision: actual.matmul_precision,
    cudnn_conv_precision: actual.cudnn_conv_precision,
    cudnn_rnn_precision: actual.cudnn_rnn_precision,
    nvidia_tf32_override: actual.nvidia_tf32_override,
    torch_allow_tf32_cublas_override: actual.torch_allow_tf32_cublas_override,
    cudnn_available: actual.cudnn_available,
    matmul_permission: actual.matmul_permission,
    cudnn_conv_permission: actual.cudnn_conv_permission,
    cudnn_rnn_permission: actual.cudnn_rnn_permission,
  }
  policy.validate()
  policy
}

///|
// Injected operations let CPU contract tests prove absence never queries or
// mutates CUDA and invalid capability/device fails before the setter.
fn apply_fp32_request(
  request : Bool?,
  device : Int32,
  available : () -> Bool,
  configure : (Bool) -> @tensor.CudaFp32Settings raise,
) -> NativeFp32Policy? raise {
  guard request is Some(requested) else { return None }
  guard device >= 0 else {
    fail(
      "explicit allow_tf32 requires CUDA; omit it for the legacy CPU profile",
    )
  }
  guard available() else {
    fail(
      "explicit allow_tf32 requires the optional CUDA FP32 control extension",
    )
  }
  let actual = configure(requested)
  guard !actual.startup_configuration_locked else {
    fail(
      "CUDA FP32 policy must be configured before any tensor or NCCL control",
    )
  }
  Some(fp32_policy_from_settings(requested, actual))
}

///|
fn configure_fp32_policy(
  backend : @tensor.Backend,
  config : Json,
  device : Int32,
) -> NativeFp32Policy? raise {
  apply_fp32_request(
    fp32_request(config),
    device,
    () => backend.has_cuda_fp32_control(),
    requested => {
      backend.configure_cuda_tf32(
        matmul=requested,
        cudnn_conv=requested,
        cudnn_rnn=requested,
        before_first_tensor=true,
      )
    },
  )
}

///|
fn with_fp32_policy(value : Json, policy : NativeFp32Policy?) -> Json raise {
  guard policy is Some(policy) else { return value }
  policy.validate()
  guard value is Object(fields) else {
    fail("precision evidence requires an object")
  }
  let result = fields.copy()
  guard !result.contains("cuda_fp32_policy") else {
    fail("duplicate CUDA FP32 policy evidence")
  }
  result["cuda_fp32_policy"] = Json(policy)
  Json::object(result)
}

///|
// Legacy absence stays absent; explicit old configs without verified evidence
// cannot be retroactively interpreted as having run TF32 or IEEE.
fn source_fp32_policy(identity : Json) -> NativeFp32Policy? raise {
  let request = fp32_request(identity_field(identity, "config"))
  guard identity is Object(fields) else {
    fail("source identity must be object")
  }
  match (request, fields.get("cuda_fp32_policy")) {
    (None, None) => None
    (Some(requested), Some(value)) => {
      let policy : NativeFp32Policy = @json.from_json(value)
      policy.validate()
      guard policy.allow_tf32 == requested else {
        fail("source config and recorded CUDA FP32 request differ")
      }
      Some(policy)
    }
    _ =>
      fail(
        "source CUDA FP32 policy is missing or has no matching explicit config; refusing to infer historical precision",
      )
  }
}

///|
fn verify_fp32_source(
  expected : NativeFp32Policy?,
  actual : NativeFp32Policy?,
) -> Unit raise {
  guard expected == actual else {
    fail(
      "inference CUDA FP32 runtime policy differs from the saved source policy",
    )
  }
}

///|
fn fp32_inference_report(
  report : Json,
  policy : NativeFp32Policy?,
  applied : Bool,
) -> Json raise {
  guard policy is Some(policy) else { return report }
  let result = with_fp32_policy(report, Some(policy))
  guard result is Object(fields) else {
    fail("precision report must be object")
  }
  fields["cuda_fp32_policy_applied"] = Json(applied)
  fields["cuda_fp32_policy_scope"] = Json(
    if applied {
      "source policy applied before tensors; per-op permission is not kernel dispatch evidence"
    } else {
      "source policy preserved in actor.source.identity; CPU export does not configure CUDA or execute policy matmul"
    },
  )
  result
}
