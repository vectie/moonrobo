///|
#borrow(backend)
extern "c" fn fused_rotation_available(backend : Backend) -> Int32 = "mr_tensor_has_fused_rotation"

///|
pub fn Backend::has_fused_rotation(self : Backend) -> Bool {
  fused_rotation_available(self) != 0
}

///|
#borrow(backend, angle)
extern "c" fn fused_axis_call(
  backend : Backend,
  angle : NativeTensor,
  axis : Int32,
  sign : Double,
) -> NativeTensor = "mr_tensor_fused_axis_call"

///|
/// Exact signed coordinate axis only, bounded FP32/64 [B,1], B<=262144.
/// Preserves the reference forward and supplies the analytic angle derivative.
/// CUDA requires MR_ENABLE_GEOMETRY_FUSION; CPU uses the compact ATen path.
/// Supports first-order training gradients, including strided angle views.
pub fn Tensor::fused_axis_rotation(
  self : Tensor,
  axis : Int32,
  sign : Double,
) -> Tensor raise TensorError {
  let native = fused_axis_call(self.backend, self.native, axis, sign)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, vector)
extern "c" fn fused_skew_call(
  backend : Backend,
  vector : NativeTensor,
) -> NativeTensor = "mr_tensor_fused_skew_call"

///|
/// Bounded FP32/64 [B,3], B<=262144. Exact linear skew map and its VJP.
/// CUDA requires MR_ENABLE_GEOMETRY_FUSION. First-order gradients only.
pub fn Tensor::fused_skew(self : Tensor) -> Tensor raise TensorError {
  let native = fused_skew_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}
