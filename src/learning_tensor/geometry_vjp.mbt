///|
#borrow(backend)
extern "c" fn geometry_vjp_available(backend : Backend) -> Int32 = "mr_tensor_has_geometry_vjp"

///|
pub fn Backend::has_geometry_vjp(self : Backend) -> Bool {
  geometry_vjp_available(self) != 0
}

///|
#borrow(backend, a, b)
extern "c" fn fused_cross_vjp_call(
  backend : Backend,
  a : NativeTensor,
  b : NativeTensor,
) -> NativeTensor = "mr_tensor_fused_cross_vjp_call"

///|
/// Same forward as fused_cross_forward, jointly computes both cross VJPs.
/// Bounded FP32/64 [B,3], first-order autograd; original method stays available.
pub fn Tensor::fused_cross_vjp(
  self : Tensor,
  right : Tensor,
) -> Tensor raise TensorError {
  let native = fused_cross_vjp_call(self.backend, self.native, right.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, x)
extern "c" fn so3_coefficients_call(
  backend : Backend,
  x : NativeTensor,
) -> NativeTensor = "mr_tensor_so3_coefficients_call"

///|
/// Maps squared rotation norm [B,1] to Rodrigues a/b [B,2], with the original
/// ATen forward and a fused first-order VJP. B<=262144; FP32/64 CPU/CUDA.
pub fn Tensor::so3_coefficients(self : Tensor) -> Tensor raise TensorError {
  let native = so3_coefficients_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend)
extern "c" fn coefficient_forward_available(backend : Backend) -> Int32 = "mr_tensor_has_coefficient_forward"

///|
pub fn Backend::has_coefficient_forward(self : Backend) -> Bool {
  coefficient_forward_available(self) != 0
}

///|
#borrow(backend, x)
extern "c" fn so3_coefficient_forward_call(
  backend : Backend,
  x : NativeTensor,
) -> NativeTensor = "mr_tensor_so3_coefficient_forward_call"

///|
/// Maps squared rotation norm [B,1] to Rodrigues a/b [B,2], with the original
/// fused assembly, ATen transcendental functions and accepted first-order VJP. B<=262144; FP32/64 CPU/CUDA.
pub fn Tensor::so3_coefficient_forward(
  self : Tensor,
) -> Tensor raise TensorError {
  let native = so3_coefficient_forward_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend)
extern "c" fn coefficient_full_forward_available(backend : Backend) -> Int32 = "mr_tensor_has_coefficient_full_forward"

///|
pub fn Backend::has_coefficient_full_forward(self : Backend) -> Bool {
  coefficient_full_forward_available(self) != 0
}

///|
#borrow(backend, x)
extern "c" fn so3_coefficient_full_forward_call(
  backend : Backend,
  x : NativeTensor,
) -> NativeTensor = "mr_tensor_so3_coefficient_full_forward_call"

///|
/// Maps squared rotation norm [B,1] to Rodrigues a/b [B,2], with the original
/// fused scalar sqrt/sin/cos and coefficient assembly and accepted first-order VJP. B<=262144; FP32/64 CPU/CUDA.
pub fn Tensor::so3_coefficient_full_forward(
  self : Tensor,
) -> Tensor raise TensorError {
  let native = so3_coefficient_full_forward_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}
