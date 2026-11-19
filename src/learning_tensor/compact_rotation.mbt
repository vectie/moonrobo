///|
#borrow(backend)
extern "c" fn compact_rotation_available(backend : Backend) -> Int32 = "mr_tensor_has_compact_rotation"

///|
pub fn Backend::has_compact_rotation(self : Backend) -> Bool {
  compact_rotation_available(self) != 0
}

///|
#borrow(backend, angle)
extern "c" fn compact_axis_call(
  backend : Backend,
  angle : NativeTensor,
  axis : Int32,
  sign : Double,
) -> NativeTensor = "mr_tensor_compact_axis_call"

///|
/// Exact signed coordinate axis only, bounded FP32/64 [B,1], B<=262144.
/// Preserves the reference forward and supplies the analytic angle derivative.
pub fn Tensor::compact_axis_rotation(
  self : Tensor,
  axis : Int32,
  sign : Double,
) -> Tensor raise TensorError {
  let native = compact_axis_call(self.backend, self.native, axis, sign)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, vector)
extern "c" fn compact_skew_call(
  backend : Backend,
  vector : NativeTensor,
) -> NativeTensor = "mr_tensor_compact_skew_call"

///|
/// Bounded FP32/64 [B,3], B<=262144. Exact linear skew map and its VJP.
pub fn Tensor::compact_skew(self : Tensor) -> Tensor raise TensorError {
  let native = compact_skew_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}
