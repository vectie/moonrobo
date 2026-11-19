///|
type NativeAdam

///|
/// Owns LibTorch optimizer state and parameter tensors on their selected device.
pub struct Adam {
  backend : Backend
  native : NativeAdam
}

///|
#borrow(backend, parameters)
extern "c" fn adam_native(
  backend : Backend,
  parameters : FixedArray[NativeTensor],
  lr : Double,
  beta1 : Double,
  beta2 : Double,
  eps : Double,
) -> NativeAdam = "mr_adam_create_call"

///|
#borrow(backend, optimizer)
extern "c" fn step_native(
  backend : Backend,
  optimizer : NativeAdam,
  clip_norm : Double,
  clip_value : Double,
) -> Int32 = "mr_adam_step_call"

///|
#borrow(backend, optimizer)
extern "c" fn zero_adam_native(
  backend : Backend,
  optimizer : NativeAdam,
) -> Int32 = "mr_adam_zero_call"

///|
#borrow(backend, optimizer)
extern "c" fn lr_native(
  backend : Backend,
  optimizer : NativeAdam,
  lr : Double,
) -> Int32 = "mr_adam_rate_call"

///|
#borrow(backend, optimizer, path)
extern "c" fn checkpoint_native(
  backend : Backend,
  optimizer : NativeAdam,
  path : Bytes,
  load : Int32,
) -> Int32 = "mr_adam_checkpoint_call"

///|
pub fn Backend::adam(
  self : Backend,
  parameters : Array[Tensor],
  learning_rate~ : Double = 0.0002,
  beta1~ : Double = 0.9,
  beta2~ : Double = 0.999,
  eps~ : Double = 1.0e-8,
) -> Adam raise TensorError {
  let native = adam_native(
    self,
    FixedArray::makei(parameters.length(), i => parameters[i].native),
    learning_rate,
    beta1,
    beta2,
    eps,
  )
  self.check()
  { backend: self, native, }
}

///|
/// Refuses missing/nonfinite gradients before changing any parameters.
/// A zero clip_norm disables gradient clipping.
pub fn Adam::step(
  self : Adam,
  clip_norm~ : Double = 0.0,
  clip_value~ : Double = 0.0,
) -> Unit raise TensorError {
  if step_native(self.backend, self.native, clip_norm, clip_value) != 0 {
    self.backend.check()
  }
}

///|
pub fn Adam::zero_grad(self : Adam) -> Unit raise TensorError {
  if zero_adam_native(self.backend, self.native) != 0 {
    self.backend.check()
  }
}

///|
pub fn Adam::set_learning_rate(
  self : Adam,
  learning_rate : Double,
) -> Unit raise TensorError {
  if lr_native(self.backend, self.native, learning_rate) != 0 {
    self.backend.check()
  }
}

///|
/// Saves ordered parameters and Adam moments/steps/hyperparameters atomically.
/// Enclosing training code must additionally checkpoint RNG, replay and norms.
pub fn Adam::save(self : Adam, path : String) -> Unit raise TensorError {
  if checkpoint_native(self.backend, self.native, @utf8.encode(path), 0) != 0 {
    self.backend.check()
  }
}

///|
/// Restores into existing parameters, validating all shapes/dtypes beforehand.
pub fn Adam::load(self : Adam, path : String) -> Unit raise TensorError {
  if checkpoint_native(self.backend, self.native, @utf8.encode(path), 1) != 0 {
    self.backend.check()
  }
}

///|
#borrow(backend, optimizer)
extern "c" fn adam_audit_metadata_native(
  backend : Backend,
  optimizer : NativeAdam,
) -> Bytes = "mr_adam_audit_metadata_call"

///|
#borrow(backend, optimizer)
extern "c" fn adam_audit_tensor_native(
  backend : Backend,
  optimizer : NativeAdam,
  index : Int32,
  kind : Int32,
) -> NativeTensor = "mr_adam_audit_tensor_call"

///|
/// Deterministic JSON: parameter_count; states[{present,step}]; groups with
/// ordered indices, learning_rate, beta1, beta2, eps, weight_decay and amsgrad.
/// Int64 steps are decimal strings; options retain Double roundtrip precision.
/// No process-local pointers are included. Requires the optional audit extension.
pub fn Adam::audit_metadata(self : Adam) -> String raise TensorError {
  let metadata = adam_audit_metadata_native(self.backend, self.native)
  self.backend.check()
  @utf8.decode_lossy(metadata)
}

///|
/// Detached view for bounded semantic audit. Treat the shared storage as read
/// only. kind=0 parameter, 1 exp_avg, 2 exp_avg_sq, 3 max_exp_avg_sq (AMSGrad).
/// Missing state/tensor is an error. Slice before values() to bound host memory.
pub fn Adam::audit_tensor(
  self : Adam,
  parameter_index : Int32,
  kind~ : Int32 = 0,
) -> Tensor raise TensorError {
  let native = adam_audit_tensor_native(
    self.backend,
    self.native,
    parameter_index,
    kind,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
#borrow(b, a, all)
extern "c" fn adam_author(
  b : Backend,
  a : NativeAdam,
  all : FixedArray[NativeTensor],
  clip : Double,
) -> Int32 = "mr_adam_author_call"

///|
/// Clip all active gradients jointly, then perform the fused ATen Adam step
/// on the Adam partition. The caller applies Muon to its remaining matrices.
pub fn Adam::step_gencoord(
  self : Adam,
  all : Array[Tensor],
  clip_value~ : Double,
) -> Unit raise TensorError {
  let params = FixedArray::makei(all.length(), i => all[i].native)
  if adam_author(self.backend, self.native, params, clip_value) != 0 {
    self.backend.check()
  }
}
