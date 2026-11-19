///|
#borrow(backend)
extern "c" fn split_sections_available(backend : Backend) -> Int32 = "mr_tensor_has_split_sections"

///|
pub fn Backend::has_split_sections(self : Backend) -> Bool {
  split_sections_available(self) != 0
}

///|
#borrow(backend, input, sizes)
extern "c" fn split_sections_call(
  backend : Backend,
  input : NativeTensor,
  sizes : FixedArray[Int32],
  axis : Int32,
) -> FixedArray[NativeTensor] = "mr_tensor_split_sections_call"

///|
/// Positive sections covering one axis exactly, at most 64 views and 16M
/// input elements. Uses one native split autograd node, including unused views.
pub fn Tensor::split_sections(
  self : Tensor,
  sizes : Array[Int32],
  axis~ : Int32 = 1,
) -> Array[Tensor] raise TensorError {
  let values = split_sections_call(
    self.backend,
    self.native,
    FixedArray::from_array(sizes),
    axis,
  )
  self.backend.check()
  Array::makei(values.length(), i => Tensor::{
    backend: self.backend,
    native: values[i],
  })
}
