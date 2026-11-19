///|
#borrow(backend)
extern "c" fn geometry_tail_available(backend : Backend) -> Int32 = "mr_tensor_has_geometry_tail"

///|
pub fn Backend::has_geometry_tail(self : Backend) -> Bool {
  geometry_tail_available(self) != 0
}

///|
#borrow(backend, k, kk, a, b)
extern "c" fn so3_tail_call(
  backend : Backend,
  k : NativeTensor,
  kk : NativeTensor,
  a : NativeTensor,
  b : NativeTensor,
) -> NativeTensor = "mr_tensor_so3_tail_call"

///|
/// Fuses (I + K*a) + K2*b, preserving ATen reduction order in the VJP.
/// K and K2: [B,3,3], a/b: [B,1], B<=262144, matching FP32/64 CPU/CUDA.
/// CUDA needs the geometry extension. First-order autograd only.
pub fn Tensor::so3_tail(
  self : Tensor,
  square : Tensor,
  a : Tensor,
  b : Tensor,
) -> Tensor raise TensorError {
  let native = so3_tail_call(
    self.backend,
    self.native,
    square.native,
    a.native,
    b.native,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend, a, b)
extern "c" fn fused_cross_forward_call(
  backend : Backend,
  a : NativeTensor,
  b : NativeTensor,
) -> NativeTensor = "mr_tensor_fused_cross_forward_call"

///|
/// One multiply/subtract forward kernel; retains the existing ATen cross VJP.
/// Matching bounded FP32/64 [B,3] CPU/CUDA tensors, including strided views.
pub fn Tensor::fused_cross_forward(
  self : Tensor,
  right : Tensor,
) -> Tensor raise TensorError {
  let native = fused_cross_forward_call(self.backend, self.native, right.native)
  self.backend.check()
  { backend: self.backend, native, }
}
