///|
/// An optional LibTorch backend loaded explicitly from a shared library.
pub type Backend

///|
type NativeTensor

///|
/// Keeping the backend in every tensor keeps its native destructor valid.
pub struct Tensor {
  backend : Backend
  native : NativeTensor
}

///|
pub suberror TensorError {
  Native(String)
}

///|
#borrow(path)
extern "c" fn open_native(path : Bytes) -> Backend = "mr_tensor_open"

///|
#borrow(backend)
extern "c" fn error_native(backend : Backend) -> Bytes = "mr_tensor_error"

///|
#borrow(backend)
extern "c" fn version_native(backend : Backend) -> Bytes = "mr_tensor_torch_version"

///|
#borrow(backend)
extern "c" fn cuda_count_native(backend : Backend) -> Int32 = "mr_tensor_device_count"

///|
#borrow(backend, shape, values)
extern "c" fn create_native(
  backend : Backend,
  shape : FixedArray[Int32],
  values : FixedArray[Double],
  cuda_device : Int32,
  requires_grad : Int32,
  dtype : Int32,
) -> NativeTensor = "mr_tensor_create_bulk"

///|
#borrow(backend, a, b)
extern "c" fn binary_native(
  backend : Backend,
  a : NativeTensor,
  b : NativeTensor,
  op : Int32,
) -> NativeTensor = "mr_tensor_binary_call"

///|
#borrow(backend, a)
extern "c" fn unary_native(
  backend : Backend,
  a : NativeTensor,
  op : Int32,
) -> NativeTensor = "mr_tensor_unary_call"

///|
#borrow(backend, a)
extern "c" fn backward_native(
  backend : Backend,
  a : NativeTensor,
  retain_graph : Int32,
) -> Int32 = "mr_tensor_backward_call"

///|
#borrow(backend, a)
extern "c" fn zero_grad_native(backend : Backend, a : NativeTensor) -> Int32 = "mr_tensor_zero_grad_call"

///|
#borrow(backend, a)
extern "c" fn rank_native(backend : Backend, a : NativeTensor) -> Int32 = "mr_tensor_rank_call"

///|
#borrow(backend, a)
extern "c" fn shape_native(
  backend : Backend,
  a : NativeTensor,
  axis : Int32,
) -> Int32 = "mr_tensor_dim_call"

///|
#borrow(backend, a)
extern "c" fn size_native(backend : Backend, a : NativeTensor) -> Int32 = "mr_tensor_size_call"

///|
#borrow(backend, a, values)
extern "c" fn read_native(
  backend : Backend,
  a : NativeTensor,
  values : FixedArray[Double],
  gradient : Int32,
) -> Int32 = "mr_tensor_read_call"

///|
fn Backend::check(self : Backend) -> Unit raise TensorError {
  let message = @utf8.decode_lossy(error_native(self))
  if message != "" {
    raise Native(message)
  }
}

///|
pub fn Backend::open(path : String) -> Backend raise TensorError {
  let backend = open_native(@utf8.encode(path))
  backend.check()
  backend
}

///|
pub fn Backend::version(self : Backend) -> String {
  @utf8.decode_lossy(version_native(self))
}

///|
pub fn Backend::cuda_device_count(self : Backend) -> Int32 {
  cuda_count_native(self)
}

///|
/// Values are copied to CPU or a selected CUDA device. A device of -1
/// selects CPU; nonnegative device IDs select CUDA. The tensor is a leaf.
/// Float64 remains the default for existing callers; training selects Float32.
pub fn Backend::from_values(
  self : Backend,
  shape : Array[Int32],
  values : Array[Double],
  cuda_device~ : Int32,
  requires_grad~ : Bool,
  dtype~ : DType = Float64,
) -> Tensor raise TensorError {
  if shape.length() > 8 || cuda_device < -1 {
    raise Native("invalid rank or CUDA device")
  }
  let mut count = 1
  for dim in shape {
    if dim < 0 || (dim > 0 && count > 2147483647 / dim) {
      raise Native("invalid or oversized tensor shape")
    }
    count *= dim
  }
  if count != values.length() {
    raise Native("shape does not match number of values")
  }
  let native = create_native(
    self,
    FixedArray::makei(shape.length(), i => shape[i]),
    FixedArray::makei(values.length(), i => values[i]),
    cuda_device,
    if requires_grad {
      1
    } else {
      0
    },
    dtype.code(),
  )
  self.check()
  { backend: self, native, }
}

///|
/// Upload an owned primitive buffer without constructing an intermediate
/// Array[Double] copy. The existing synchronous ABI copies the borrowed input;
/// no MoonBit storage is retained by LibTorch after this call returns.
pub fn Backend::from_fixed_values(
  self : Backend,
  shape : Array[Int32],
  values : FixedArray[Double],
  cuda_device~ : Int32,
  requires_grad~ : Bool,
  dtype~ : DType = Float64,
) -> Tensor raise TensorError {
  if shape.length() > 8 || cuda_device < -1 {
    raise Native("invalid rank or CUDA device")
  }
  let mut count = 1
  for dim in shape {
    if dim < 0 || (dim > 0 && count > 2147483647 / dim) {
      raise Native("invalid or oversized tensor shape")
    }
    count *= dim
  }
  if count != values.length() {
    raise Native("shape does not match number of values")
  }
  let native = create_native(
    self,
    FixedArray::makei(shape.length(), i => shape[i]),
    values,
    cuda_device,
    if requires_grad {
      1
    } else {
      0
    },
    dtype.code(),
  )
  self.check()
  { backend: self, native, }
}

///|
fn Tensor::binary(
  self : Tensor,
  other : Tensor,
  op : Int32,
) -> Tensor raise TensorError {
  let native = binary_native(self.backend, self.native, other.native, op)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
fn Tensor::unary(self : Tensor, op : Int32) -> Tensor raise TensorError {
  let native = unary_native(self.backend, self.native, op)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::add(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 0)
}

///|
pub fn Tensor::sub(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 1)
}

///|
pub fn Tensor::mul(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 2)
}

///|
pub fn Tensor::matmul(
  self : Tensor,
  other : Tensor,
) -> Tensor raise TensorError {
  self.binary(other, 3)
}

///|
pub fn Tensor::div(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 4)
}

///|
pub fn Tensor::sum(self : Tensor) -> Tensor raise TensorError {
  self.unary(0)
}

///|
pub fn Tensor::mean(self : Tensor) -> Tensor raise TensorError {
  self.unary(1)
}

///|
pub fn Tensor::tanh(self : Tensor) -> Tensor raise TensorError {
  self.unary(2)
}

///|
pub fn Tensor::relu(self : Tensor) -> Tensor raise TensorError {
  self.unary(3)
}

///|
pub fn Tensor::exp(self : Tensor) -> Tensor raise TensorError {
  self.unary(4)
}

///|
pub fn Tensor::square(self : Tensor) -> Tensor raise TensorError {
  self.unary(5)
}

///|
/// Elementwise inverse cosine. Requires unary opcode 18 in the native plugin;
/// older plugins report an unsupported operation instead of approximating it.
/// Values outside [-1, 1] follow ATen NaN semantics; clamp explicitly if desired.
pub fn Tensor::acos(self : Tensor) -> Tensor raise TensorError {
  self.unary(18)
}

///|
/// ATen's exact (erf) GELU, including its native backward.
pub fn Tensor::gelu(self : Tensor) -> Tensor raise TensorError {
  self.unary(19)
}

///|
pub fn Tensor::copy_values_from(
  self : Tensor,
  value : Tensor,
) -> Unit raise TensorError {
  ignore(self.binary(value, 9))
}

///|
#borrow(b, p, buffer)
extern "c" fn muon_update_native(
  b : Backend,
  p : NativeTensor,
  buffer : NativeTensor,
  lr : Double,
) -> Int32 = "mr_muon_update_call"

///|
pub fn Tensor::muon_update(
  self : Tensor,
  momentum : Tensor,
  lr : Double,
) -> Unit raise TensorError {
  if muon_update_native(self.backend, self.native, momentum.native, lr) != 0 {
    self.backend.check()
  }
}

///|
pub fn Tensor::gradient(self : Tensor) -> Tensor raise TensorError {
  self.unary(6)
}

///|
pub fn Tensor::detach(self : Tensor) -> Tensor raise TensorError {
  self.unary(7)
}

///|
pub fn Tensor::transpose(self : Tensor) -> Tensor raise TensorError {
  self.unary(8)
}

///|
pub fn Tensor::backward(
  self : Tensor,
  retain_graph~ : Bool = false,
) -> Unit raise TensorError {
  if backward_native(
      self.backend,
      self.native,
      if retain_graph {
        1
      } else {
        0
      },
    ) !=
    0 {
    self.backend.check()
  }
}

///|
pub fn Tensor::zero_gradient(self : Tensor) -> Unit raise TensorError {
  if zero_grad_native(self.backend, self.native) != 0 {
    self.backend.check()
  }
}

///|
pub fn Tensor::shape(self : Tensor) -> Array[Int32] raise TensorError {
  let rank = rank_native(self.backend, self.native)
  self.backend.check()
  Array::makei(rank, i => {
    let dim = shape_native(self.backend, self.native, i)
    self.backend.check()
    dim
  })
}

///|
pub fn Tensor::values(self : Tensor) -> Array[Double] raise TensorError {
  self.read_values(0)
}

///|
pub fn Tensor::gradient_values(
  self : Tensor,
) -> Array[Double] raise TensorError {
  self.read_values(1)
}

///|
fn Tensor::read_values(
  self : Tensor,
  gradient : Int32,
) -> Array[Double] raise TensorError {
  let count = size_native(self.backend, self.native)
  self.backend.check()
  let values = FixedArray::make(count, 0.0)
  if read_native(self.backend, self.native, values, gradient) != 0 {
    self.backend.check()
  }
  Array::makei(count, i => values[i])
}

///|
type NativeMjlab

///|
pub struct Mjlab {
  backend : Backend
  session : NativeMjlab
}

///|
#borrow(b, config)
extern "c" fn mjlab_open(b : Backend, config : Bytes) -> NativeMjlab = "mr_mjlab_open_call"

///|
#borrow(b, sim, args)
extern "c" fn mjlab_exchange(
  b : Backend,
  sim : NativeMjlab,
  op : Int32,
  args : FixedArray[NativeTensor],
) -> NativeTensor = "mr_mjlab_exchange_call"

///|
pub fn Backend::open_mjlab(
  self : Backend,
  config : String,
) -> Mjlab raise TensorError {
  let session = mjlab_open(self, @utf8.encode(config))
  self.check()
  { backend: self, session, }
}

///|
pub fn Mjlab::exchange(
  self : Mjlab,
  op : Int32,
  input? : Tensor,
) -> Tensor raise TensorError {
  let args : FixedArray[NativeTensor] = match input {
    Some(t) => [t.native]
    None => []
  }
  let native = mjlab_exchange(self.backend, self.session, op, args)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(b, t, path)
extern "c" fn tensor_checkpoint(
  b : Backend,
  t : NativeTensor,
  path : Bytes,
  load : Int32,
) -> Int32 = "mr_tensor_checkpoint_call"

///|
pub fn Tensor::checkpoint(
  self : Tensor,
  path : String,
  load~ : Bool,
) -> Unit raise TensorError {
  if tensor_checkpoint(
      self.backend,
      self.native,
      @utf8.encode(path),
      if load {
        1
      } else {
        0
      },
    ) !=
    0 {
    self.backend.check()
  }
}
