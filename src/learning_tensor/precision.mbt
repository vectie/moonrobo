///|
#borrow(backend)
extern "c" fn has_linear_native(backend : Backend) -> Bool = "mr_tensor_has_linear"

///|
pub fn Backend::has_linear(self : Backend) -> Bool {
  has_linear_native(self)
}

///|
#borrow(backend, input, weight, bias)
extern "c" fn linear_native(
  backend : Backend,
  input : NativeTensor,
  weight : NativeTensor,
  bias : NativeTensor,
) -> NativeTensor = "mr_tensor_linear_call"

///|
/// ATen Linear, like PyTorch nn.Linear: weight[out,in], bias[out]. Preserves
/// input/parameter gradients and the backend's FP32 policy; no autocast.
pub fn Tensor::linear(
  self : Tensor,
  weight : Tensor,
  bias : Tensor,
) -> Tensor raise TensorError {
  let native = linear_native(
    self.backend,
    self.native,
    weight.native,
    bias.native,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(backend)
extern "c" fn has_bf16_linear_native(backend : Backend) -> Bool = "mr_tensor_has_bf16_linear"

///|
#borrow(backend, input)
extern "c" fn cast_float_native(
  backend : Backend,
  input : NativeTensor,
  dtype : Int32,
) -> NativeTensor = "mr_tensor_cast_float_call"

///|
#borrow(backend, input, weight, bias)
extern "c" fn linear_bf16_native(
  backend : Backend,
  input : NativeTensor,
  weight : NativeTensor,
  bias : NativeTensor,
) -> NativeTensor = "mr_tensor_linear_bf16_call"

///|
/// Optional symbols exist; actual device/kernel support is checked by dispatch.
pub fn Backend::has_bf16_linear(self : Backend) -> Bool {
  has_bf16_linear_native(self)
}

///|
/// Differentiable floating dtype conversion on the existing device.
/// It does not detach, replace master parameters, or change optimizer state.
pub fn Tensor::cast_float(
  self : Tensor,
  dtype : DType,
) -> Tensor raise TensorError {
  let native = cast_float_native(self.backend, self.native, dtype.code())
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Scoped BF16 autocast Linear including bias, with FP32 master parameters.
/// Returns BF16; caller restores FP32 before geometry, losses and normalizers.
/// Autocast state is restored on success/error and weight casts are not cached
/// across optimizer updates. CPU is supported for bounded semantic tests.
pub fn Tensor::linear_bf16(
  self : Tensor,
  weight : Tensor,
  bias : Tensor,
) -> Tensor raise TensorError {
  let native = linear_bf16_native(
    self.backend,
    self.native,
    weight.native,
    bias.native,
  )
  self.backend.check()
  { backend: self.backend, native, }
}
