///|
pub(all) enum DType {
  Float64
  Float32
  BFloat16
  Int64
  Bool
} derive(Eq, Debug)

///|
#borrow(backend)
extern "c" fn cuda_free_native(backend : Backend, device : Int32) -> Int64 = "mr_tensor_cuda_free_bytes_call"

///|
/// Queries the actual CUDA runtime before model allocation. CPU builds fail.
pub fn Backend::cuda_free_bytes(
  self : Backend,
  device : Int32,
) -> Int64 raise TensorError {
  let count = cuda_free_native(self, device)
  self.check()
  count
}

///|
fn DType::code(self : DType) -> Int32 {
  match self {
    Float64 => 0
    Float32 => 1
    BFloat16 => 2
    Int64 => 3
    Bool => 4
  }
}

///|
#borrow(backend, a)
extern "c" fn metadata_native(
  backend : Backend,
  a : NativeTensor,
  field : Int32,
) -> Int32 = "mr_tensor_metadata_call"

///|
#borrow(backend, a, args)
extern "c" fn shape_op_native(
  backend : Backend,
  a : NativeTensor,
  op : Int32,
  args : FixedArray[Int32],
) -> NativeTensor = "mr_tensor_shape_call"

///|
#borrow(backend, a)
extern "c" fn scalar_op_native(
  backend : Backend,
  a : NativeTensor,
  op : Int32,
  x : Double,
  y : Double,
) -> NativeTensor = "mr_tensor_scalar_call"

///|
#borrow(backend, inputs)
extern "c" fn join_native(
  backend : Backend,
  inputs : FixedArray[NativeTensor],
  axis : Int32,
  stack : Int32,
) -> NativeTensor = "mr_tensor_join_call"

///|
#borrow(backend, a, indices)
extern "c" fn select_native(
  backend : Backend,
  a : NativeTensor,
  indices : NativeTensor,
  axis : Int32,
) -> NativeTensor = "mr_tensor_index_select_call"

///|
#borrow(backend, output, input, cotangent)
extern "c" fn pullback_native(
  backend : Backend,
  output : NativeTensor,
  input : NativeTensor,
  cotangent : NativeTensor,
  retain_graph : Int32,
) -> NativeTensor = "mr_tensor_pullback_call"

///|
pub fn Tensor::dtype(self : Tensor) -> DType raise TensorError {
  let code = metadata_native(self.backend, self.native, 1)
  self.backend.check()
  match code {
    0 => Float64
    1 => Float32
    2 => BFloat16
    3 => Int64
    4 => Bool
    _ => raise Native("unsupported dtype")
  }
}

///|
/// CPU is -1; nonnegative IDs are CUDA devices.
pub fn Tensor::cuda_device(self : Tensor) -> Int32 raise TensorError {
  let device = metadata_native(self.backend, self.native, 0)
  self.backend.check()
  device
}

///|
fn Tensor::shape_op(
  self : Tensor,
  op : Int32,
  args : Array[Int32],
) -> Tensor raise TensorError {
  let native = shape_op_native(
    self.backend,
    self.native,
    op,
    FixedArray::makei(args.length(), i => args[i]),
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::reshape(
  self : Tensor,
  shape : Array[Int32],
) -> Tensor raise TensorError {
  self.shape_op(0, shape)
}

///|
pub fn Tensor::narrow(
  self : Tensor,
  axis : Int32,
  start : Int32,
  length : Int32,
) -> Tensor raise TensorError {
  self.shape_op(1, [axis, start, length])
}

///|
pub fn Tensor::transpose_dims(
  self : Tensor,
  first : Int32,
  second : Int32,
) -> Tensor raise TensorError {
  self.shape_op(2, [first, second])
}

///|
pub fn Tensor::sum_dim(
  self : Tensor,
  axis : Int32,
  keepdim~ : Bool = false,
) -> Tensor raise TensorError {
  self.shape_op(3, [axis, if keepdim { 1 } else { 0 }])
}

///|
pub fn Tensor::mean_dim(
  self : Tensor,
  axis : Int32,
  keepdim~ : Bool = false,
) -> Tensor raise TensorError {
  self.shape_op(4, [axis, if keepdim { 1 } else { 0 }])
}

///|
/// Population variance (correction=0), using ATen's native reduction.
/// Requires an adapter with shape operation 5; older adapters fail explicitly.
pub fn Tensor::population_variance_dim(
  self : Tensor,
  axis : Int32,
  keepdim~ : Bool = false,
) -> Tensor raise TensorError {
  self.shape_op(5, [axis, if keepdim { 1 } else { 0 }])
}

///|
pub fn Tensor::affine(
  self : Tensor,
  scale : Double,
  bias~ : Double = 0.0,
) -> Tensor raise TensorError {
  let native = scalar_op_native(self.backend, self.native, 0, scale, bias)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::clamp(
  self : Tensor,
  lower : Double,
  upper : Double,
) -> Tensor raise TensorError {
  let native = scalar_op_native(self.backend, self.native, 1, lower, upper)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::sigmoid(self : Tensor) -> Tensor raise TensorError {
  self.unary(9)
}

///|
pub fn Tensor::silu(self : Tensor) -> Tensor raise TensorError {
  self.unary(10)
}

///|
pub fn Tensor::elu(self : Tensor) -> Tensor raise TensorError {
  self.unary(13)
}

///|
/// Shares storage while cutting autograd history; no parameter-sized copy.
pub fn Tensor::stop_gradient(self : Tensor) -> Tensor raise TensorError {
  self.unary(14)
}

///|
pub fn Tensor::sin(self : Tensor) -> Tensor raise TensorError {
  self.unary(15)
}

///|
pub fn Tensor::cos(self : Tensor) -> Tensor raise TensorError {
  self.unary(16)
}

///|
pub fn Tensor::abs(self : Tensor) -> Tensor raise TensorError {
  self.unary(17)
}

///|
pub fn Tensor::maximum(
  self : Tensor,
  other : Tensor,
) -> Tensor raise TensorError {
  self.binary(other, 5)
}

///|
pub fn Tensor::atan2(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 6)
}

///|
pub fn Tensor::less(self : Tensor, other : Tensor) -> Tensor raise TensorError {
  self.binary(other, 7)
}

///|
pub fn Tensor::greater(
  self : Tensor,
  other : Tensor,
) -> Tensor raise TensorError {
  self.binary(other, 8)
}

///|
#borrow(backend, condition, yes, no)
extern "c" fn where_native(
  backend : Backend,
  condition : NativeTensor,
  yes : NativeTensor,
  no : NativeTensor,
) -> NativeTensor = "mr_tensor_where_call"

///|
pub fn Tensor::select_where(
  self : Tensor,
  yes : Tensor,
  no : Tensor,
) -> Tensor raise TensorError {
  let native = where_native(self.backend, self.native, yes.native, no.native)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::sqrt(self : Tensor) -> Tensor raise TensorError {
  self.unary(11)
}

///|
pub fn Tensor::log(self : Tensor) -> Tensor raise TensorError {
  self.unary(12)
}

///|
fn Backend::join(
  self : Backend,
  inputs : Array[Tensor],
  axis : Int32,
  stack : Bool,
) -> Tensor raise TensorError {
  let native = join_native(
    self,
    FixedArray::makei(inputs.length(), i => inputs[i].native),
    axis,
    if stack {
      1
    } else {
      0
    },
  )
  self.check()
  { backend: self, native, }
}

///|
pub fn Backend::concat(
  self : Backend,
  inputs : Array[Tensor],
  axis~ : Int32 = 0,
) -> Tensor raise TensorError {
  self.join(inputs, axis, false)
}

///|
pub fn Backend::stack(
  self : Backend,
  inputs : Array[Tensor],
  axis~ : Int32 = 0,
) -> Tensor raise TensorError {
  self.join(inputs, axis, true)
}

///|
pub fn Tensor::index_select(
  self : Tensor,
  indices : Tensor,
  axis~ : Int32 = 0,
) -> Tensor raise TensorError {
  let native = select_native(self.backend, self.native, indices.native, axis)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Computes a vector-Jacobian product without accumulating leaf gradients.
pub fn Tensor::pullback(
  self : Tensor,
  input : Tensor,
  cotangent : Tensor,
  retain_graph~ : Bool = false,
) -> Tensor raise TensorError {
  let native = pullback_native(
    self.backend,
    self.native,
    input.native,
    cotangent.native,
    if retain_graph {
      1
    } else {
      0
    },
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn Tensor::new_zeros(
  self : Tensor,
  dims : Array[Int32],
) -> Tensor raise TensorError {
  self.shape_op(6, dims)
}

///|
pub fn Tensor::randperm(
  self : Tensor,
  count : Int32,
) -> Tensor raise TensorError {
  self.shape_op(7, [count])
}

///|
/// torch.nn.Linear.reset_parameters on the CPU, before moving the module to
/// its training device. LayerNorm scale and offset have no random draws.
pub fn Tensor::linear_parameters(
  self : Tensor,
  nin : Int32,
  nout : Int32,
  with_norm~ : Bool,
) -> (Tensor, Tensor, Tensor?, Tensor?) raise TensorError {
  let w = self.shape_op(8, [nin, nout, 0])
  let bias = self.shape_op(8, [nin, nout, 1])
  if with_norm {
    (
      w,
      bias,
      Some(self.shape_op(8, [nin, nout, 2])),
      Some(self.shape_op(8, [nin, nout, 3])),
    )
  } else {
    (w, bias, None, None)
  }
}

///|
pub fn Tensor::sample_with_replacement(
  self : Tensor,
  n : Int32,
) -> Tensor raise TensorError {
  self.shape_op(9, [n])
}

///|
pub fn Tensor::uniform_samples(
  self : Tensor,
  n : Int32,
) -> Tensor raise TensorError {
  self.shape_op(10, [n])
}

///|
pub fn Tensor::softmax0(self : Tensor) -> Tensor raise TensorError {
  self.unary(20)
}

///|
#borrow(backend, values, indices)
extern "c" fn group_sum_native(
  backend : Backend,
  values : NativeTensor,
  indices : NativeTensor,
  groups : Int32,
) -> NativeTensor = "mr_tensor_group_sum_call"

///|
pub fn Tensor::group_sum(
  self : Tensor,
  indices : Tensor,
  groups : Int32,
) -> Tensor raise TensorError {
  let native = group_sum_native(
    self.backend,
    self.native,
    indices.native,
    groups,
  )
  self.backend.check()
  { backend: self.backend, native, }
}
