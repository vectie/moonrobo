///|
#borrow(backend, angle)
extern "c" fn axis_angle_submitted_native(
  backend : Backend,
  angle : NativeTensor,
  x : Double,
  y : Double,
  z : Double,
) -> NativeTensor = "mr_tensor_axis_angle_submitted_call"

///|
/// Submit the original Rodrigues ATen graph in one FFI call. The immutable
/// axis is supplied by the kinematics model; no reduction or precision changes.
pub fn Tensor::axis_angle_submitted(
  self : Tensor,
  x : Double,
  y : Double,
  z : Double,
) -> Tensor raise TensorError {
  let native = axis_angle_submitted_native(self.backend, self.native, x, y, z)
  self.backend.check()
  { backend: self.backend, native, }
}
