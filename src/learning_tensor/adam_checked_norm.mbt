///|
#borrow(backend)
extern "c" fn has_checked_norm_adam_native(backend : Backend) -> Bool = "mr_adam_has_checked_norm"

///|
#borrow(backend, optimizer)
extern "c" fn checked_norm_adam_native(
  backend : Backend,
  optimizer : NativeAdam,
  clip_norm : Double,
  clip_value : Double,
) -> Int32 = "mr_adam_step_checked_norm_call"

///|
/// Optional ABI-2 extension. The original Adam::step remains the default.
pub fn Backend::has_checked_norm_adam(self : Backend) -> Bool {
  has_checked_norm_adam_native(self)
}

///|
/// Use the unchanged ordered L2 clipping norm as the finite-gradient certificate.
/// Positive norm clipping needs one ordinary-path device-to-host check. A
/// nonfinite norm distinguishes invalid gradients from finite-gradient overflow
/// and rejects either before changing gradients, parameters or Adam state.
/// Norm-then-value clipping and Adam arithmetic are unchanged. A zero clip_norm
/// uses the original finite-mask path. Missing optional support is an error.
/// Call outside CUDA graph capture and after any distributed gradient reduction.
pub fn Adam::step_checked_norm(
  self : Adam,
  clip_norm~ : Double = 0.0,
  clip_value~ : Double = 0.0,
) -> Unit raise TensorError {
  if checked_norm_adam_native(self.backend, self.native, clip_norm, clip_value) !=
    0 {
    self.backend.check()
  }
}
