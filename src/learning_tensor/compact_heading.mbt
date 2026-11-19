///|
#borrow(backend)
extern "c" fn compact_heading_available(backend : Backend) -> Int32 = "mr_tensor_has_compact_heading"

///|
pub fn Backend::has_compact_heading(self : Backend) -> Bool {
  compact_heading_available(self) != 0
}

///|
#borrow(backend, rotation)
extern "c" fn compact_heading_call(
  backend : Backend,
  rotation : NativeTensor,
) -> NativeTensor = "mr_tensor_compact_heading_call"

///|
/// SMC projected heading with epsilon=1e-9; FP32/64 [B,3,3], B<=262144.
/// Input and output gradients may be strided. First-order gradients only.
pub fn Tensor::compact_heading(self : Tensor) -> Tensor raise TensorError {
  let native = compact_heading_call(self.backend, self.native)
  self.backend.check()
  { backend: self.backend, native, }
}
