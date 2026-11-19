///|
#borrow(backend)
extern "c" fn has_layer_norm_native(backend : Backend) -> Int32 = "mr_tensor_has_layer_norm"

///|
#borrow(backend)
extern "c" fn has_ln_silu_tail_native(backend : Backend) -> Int32 = "mr_tensor_has_ln_silu_tail"

///|
#borrow(backend, centered, variance, weight, bias)
extern "c" fn ln_silu_tail_native(
  backend : Backend,
  centered : NativeTensor,
  variance : NativeTensor,
  weight : NativeTensor,
  bias : NativeTensor,
  eps : Double,
) -> NativeTensor = "mr_tensor_ln_silu_tail_call"

///|
pub fn Backend::has_ln_silu_tail(self : Backend) -> Bool {
  has_ln_silu_tail_native(self) != 0
}

///|
/// Fuse normalization's pointwise tail, followed by unchanged ATen SiLU.
/// Retain caller mean/variance reductions and first-order autograd. CUDA
/// FP32/FP64 only. The larger fusion including SiLU failed the full-update gate.
pub fn Tensor::ln_silu_tail(
  self : Tensor,
  variance : Tensor,
  weight : Tensor,
  bias : Tensor,
  eps~ : Double = 1.0e-5,
) -> Tensor raise TensorError {
  let native = ln_silu_tail_native(
    self.backend,
    self.native,
    variance.native,
    weight.native,
    bias.native,
    eps,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, input, weight, bias)
extern "c" fn layer_norm_native(
  backend : Backend,
  input : NativeTensor,
  weight : NativeTensor,
  bias : NativeTensor,
  eps : Double,
) -> NativeTensor = "mr_tensor_layer_norm_call"

///|
/// Optional ABI-2 extension. Availability does not imply a measured speedup.
pub fn Backend::has_layer_norm(self : Backend) -> Bool {
  has_layer_norm_native(self) != 0
}

///|
#borrow(backend)
extern "c" fn has_layer_norm_submitted_native(backend : Backend) -> Int32 = "mr_tensor_has_layer_norm_submitted"

///|
#borrow(backend, input, weight, bias)
extern "c" fn layer_norm_submitted_native(
  backend : Backend,
  input : NativeTensor,
  weight : NativeTensor,
  bias : NativeTensor,
  eps : Double,
) -> NativeTensor = "mr_tensor_layer_norm_submitted_call"

///|
pub fn Backend::has_layer_norm_submitted(self : Backend) -> Bool {
  has_layer_norm_submitted_native(self) != 0
}

///|
/// Submit the original expanded formula in one FFI call. This preserves its
/// ATen operator/reduction order and autograd, without native-LN substitution.
pub fn Tensor::layer_norm_submitted(
  self : Tensor,
  weight : Tensor,
  bias : Tensor,
  eps~ : Double = 1.0e-5,
) -> Tensor raise TensorError {
  guard eps > 0.0 && !eps.is_inf() else {
    raise Native("LayerNorm epsilon must be positive and finite")
  }
  let native = layer_norm_submitted_native(
    self.backend,
    self.native,
    weight.native,
    bias.native,
    eps,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, a, b)
extern "c" fn cross_submitted_native(
  backend : Backend,
  a : NativeTensor,
  b : NativeTensor,
) -> NativeTensor = "mr_tensor_cross_submitted_call"

///|
/// One submission of the original slice/multiply/subtract/concatenate graph.
pub fn Tensor::cross_submitted(
  self : Tensor,
  other : Tensor,
) -> Tensor raise TensorError {
  let native = cross_submitted_native(self.backend, self.native, other.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Native affine LayerNorm over the final dimension, using population variance.
/// All inputs must have the same floating dtype and CPU/CUDA device; weight and
/// bias must be vectors matching the last input dimension. Autograd is retained.
/// A plugin without this optional extension returns a checked error, never a
/// silent switch to the expanded implementation.
pub fn Tensor::layer_norm(
  self : Tensor,
  weight : Tensor,
  bias : Tensor,
  eps~ : Double = 1.0e-5,
) -> Tensor raise TensorError {
  guard eps > 0.0 && !eps.is_inf() else {
    raise Native("LayerNorm epsilon must be positive and finite")
  }
  let native = layer_norm_native(
    self.backend,
    self.native,
    weight.native,
    bias.native,
    eps,
  )
  self.backend.check()
  { backend: self.backend, native, }
}
