///|
#borrow(backend)
extern "c" fn has_native_cross_native(backend : Backend) -> Int32 = "mr_tensor_has_native_cross"

///|
pub fn Backend::has_native_cross(self : Backend) -> Bool {
  has_native_cross_native(self) != 0
}

///|
#borrow(backend, left, right)
extern "c" fn cross_native_call(
  backend : Backend,
  left : NativeTensor,
  right : NativeTensor,
) -> NativeTensor = "mr_tensor_native_cross_call"

///|
/// ATen cross over the last dimension, including ATen's input gradients.
/// Matching FP32/FP64 CPU/CUDA [B,3] tensors; 1 <= B <= 262144.
pub fn Tensor::native_cross(
  self : Tensor,
  right : Tensor,
) -> Tensor raise TensorError {
  let native = cross_native_call(self.backend, self.native, right.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend)
extern "c" fn has_cross_preserve_native(backend : Backend) -> Int32 = "mr_tensor_has_cross_preserve_forward"

///|
pub fn Backend::has_cross_preserve_forward(self : Backend) -> Bool {
  has_cross_preserve_native(self) != 0
}

///|
#borrow(backend, left, right)
extern "c" fn cross_preserve_call(
  backend : Backend,
  left : NativeTensor,
  right : NativeTensor,
) -> NativeTensor = "mr_tensor_cross_preserve_forward_call"

///|
/// Reference multiply/subtract forward with native exact cross-product VJP.
/// Same bounded shape/device contract as native_cross; no detached inputs.
pub fn Tensor::cross_preserve_forward(
  self : Tensor,
  right : Tensor,
) -> Tensor raise TensorError {
  let native = cross_preserve_call(self.backend, self.native, right.native)
  self.backend.check()
  { backend: self.backend, native, }
}
