///|
pub(all) enum ReduceOp {
  Sum
  Max
  Min
} derive(Eq, Debug)

///|
fn ReduceOp::native(self : ReduceOp) -> Int32 {
  match self {
    Sum => 0
    Max => 2
    Min => 3
  }
}

///|
type NativeCollective

///|
/// A synchronous CUDA-only NCCL communicator. One caller at a time; all ranks
/// must issue identical operations/shapes/dtypes in the same order. Any error
/// requires terminating every rank. No CPU or socket fallback is provided.
pub struct Collective {
  priv backend : Backend
  priv native : NativeCollective
  rank : Int32
  world_size : Int32
  cuda_device : Int32
}

///|
#borrow(backend)
extern "c" fn nccl_id_native(backend : Backend) -> Bytes = "mr_nccl_id_call"

///|
#borrow(backend, id)
extern "c" fn nccl_connect_native(
  backend : Backend,
  id : Bytes,
  rank : Int32,
  world_size : Int32,
  cuda_device : Int32,
  timeout_ms : Int32,
) -> NativeCollective = "mr_nccl_connect_call"

///|
#borrow(backend, collective)
extern "c" fn nccl_close_native(
  backend : Backend,
  collective : NativeCollective,
) -> Int32 = "mr_nccl_close_call"

///|
#borrow(backend, collective, tensor)
extern "c" fn nccl_reduce_native(
  backend : Backend,
  collective : NativeCollective,
  tensor : NativeTensor,
  op : Int32,
) -> NativeTensor = "mr_nccl_reduce_call"

///|
#borrow(backend, collective, tensor)
extern "c" fn nccl_broadcast_native(
  backend : Backend,
  collective : NativeCollective,
  tensor : NativeTensor,
  root : Int32,
) -> Int32 = "mr_nccl_broadcast_call"

///|
#borrow(backend, collective, parameters)
extern "c" fn nccl_gradients_native(
  backend : Backend,
  collective : NativeCollective,
  parameters : FixedArray[NativeTensor],
) -> Int32 = "mr_nccl_gradients_call"

///|
#borrow(backend)
extern "c" fn has_gradient_buckets_native(backend : Backend) -> Bool = "mr_nccl_has_gradient_buckets"

///|
#borrow(backend, collective, parameters)
extern "c" fn nccl_gradients_bucketed_native(
  backend : Backend,
  collective : NativeCollective,
  parameters : FixedArray[NativeTensor],
  bucket_bytes : Int32,
) -> Int32 = "mr_nccl_gradients_bucketed_call"

///|
#borrow(backend, collective, input, output)
extern "c" fn nccl_control_native(
  backend : Backend,
  collective : NativeCollective,
  input : FixedArray[Int64],
  output : FixedArray[Int64],
  op : Int32,
) -> Int32 = "mr_nccl_control_call"

///|
/// Generate exactly 128 bytes using the NCCL linked to this LibTorch plugin.
/// Rank zero must remain alive while distributing this ID to the other ranks.
pub fn Backend::nccl_id(self : Backend) -> Bytes raise TensorError {
  let id = nccl_id_native(self)
  self.check()
  id
}

///|
/// Requires NCCL 2.28.9 and 2..16 ranks. Polling waits are deadline-bound;
/// a process watchdog remains necessary for a stalled vendor/driver call.
pub fn Backend::nccl_connect(
  self : Backend,
  id : Bytes,
  rank~ : Int32,
  world_size~ : Int32,
  cuda_device~ : Int32,
  timeout_ms~ : Int32 = 30000,
) -> Collective raise TensorError {
  if id.length() != 128 ||
    world_size < 2 ||
    world_size > 16 ||
    rank < 0 ||
    rank >= world_size ||
    cuda_device < 0 ||
    timeout_ms < 100 ||
    timeout_ms > 300000 {
    raise Native("invalid NCCL ID/rank/world/device/timeout")
  }
  let native = nccl_connect_native(
    self, id, rank, world_size, cuda_device, timeout_ms,
  )
  self.check()
  { backend: self, native, rank, world_size, cuda_device, }
}

///|
/// Detached reduction result, retaining the input. The contiguous clone is
/// bounded to 256 MiB. Dtypes: Float32, Float64, BFloat16 and Int64.
pub fn Collective::all_reduce(
  self : Collective,
  tensor : Tensor,
  op~ : ReduceOp = Sum,
) -> Tensor raise TensorError {
  let native = nccl_reduce_native(
    self.backend,
    self.native,
    tensor.native,
    op.native(),
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Broadcast a contiguous tensor in place under no_grad.
pub fn Collective::broadcast(
  self : Collective,
  tensor : Tensor,
  root~ : Int32 = 0,
) -> Unit raise TensorError {
  let _ = nccl_broadcast_native(self.backend, self.native, tensor.native, root)
  self.backend.check()
}

///|
/// SUM/world into actual parameter.grad before clipping and Adam. Missing
/// gradients become zero; 4M-element slices avoid a full-model flat allocation.
pub fn Collective::average_gradients(
  self : Collective,
  parameters : Array[Tensor],
) -> Unit raise TensorError {
  let _ = nccl_gradients_native(
    self.backend,
    self.native,
    FixedArray::makei(parameters.length(), i => parameters[i].native),
  )
  self.backend.check()
}

///|
/// Optional ABI symbol availability; this does not assert CUDA/NCCL readiness.
/// Old plugins retain the original `average_gradients` operation.
pub fn Backend::has_gradient_buckets(self : Backend) -> Bool {
  has_gradient_buckets_native(self)
}

///|
/// SUM/world into parameter gradients using one 1..64 MiB cross-parameter
/// scratch buffer. Missing gradients become zero, as on the original route.
/// Every rank must provide identical parameter order/shapes/dtypes and bucket
/// capacity. Call after all local backwards and before clipping/Adam; this
/// synchronous operation does not overlap communication with backward.
pub fn Collective::average_gradients_bucketed(
  self : Collective,
  parameters : Array[Tensor],
  bucket_bytes~ : Int32,
) -> Unit raise TensorError {
  guard parameters.length() >= 1 &&
    parameters.length() <= 4096 &&
    bucket_bytes >= 1048576 &&
    bucket_bytes <= 67108864 else {
    raise Native("gradient buckets require 1..4096 parameters and 1..64 MiB")
  }
  let _ = nccl_gradients_bucketed_native(
    self.backend,
    self.native,
    FixedArray::makei(parameters.length(), i => parameters[i].native),
    bucket_bytes,
  )
  self.backend.check()
}

///|
/// Exact Int64 reduction for 1..8192 control values/counters. Every rank must
/// use the same vector length and operation. Floating metrics use all_reduce.
pub fn Collective::control(
  self : Collective,
  values : Array[Int64],
  op~ : ReduceOp = Sum,
) -> Array[Int64] raise TensorError {
  let input = FixedArray::makei(values.length(), i => values[i])
  let output = FixedArray::make(values.length(), 0L)
  let _ = nccl_control_native(
    self.backend,
    self.native,
    input,
    output,
    op.native(),
  )
  self.backend.check()
  Array::makei(values.length(), i => output[i])
}

///|
pub fn Collective::barrier(self : Collective) -> Unit raise TensorError {
  let _ = self.control([0L])
}

///|
/// Idempotently abort/close the communicator. Failed buffers are intentionally
/// retained until process exit to avoid freeing memory a failed kernel touches.
pub fn Collective::close(self : Collective) -> Unit raise TensorError {
  let _ = nccl_close_native(self.backend, self.native)
  self.backend.check()
}
