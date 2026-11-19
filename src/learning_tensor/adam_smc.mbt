///|
#borrow(backend, optimizer)
extern "c" fn smc_adam_native(
  backend : Backend,
  optimizer : NativeAdam,
  clip_norm : Double,
  clip_value : Double,
) -> Int32 = "mr_adam_step_smc_call"

///|
/// Optional original-SMC foreach arithmetic for dense Float32 CUDA parameters.
/// Checks the finite L2 norm before modifying gradients or optimizer state.
/// Keeps LibTorch checkpoint state; refuses unsupported optimizer options.
pub fn Adam::step_smc(
  self : Adam,
  clip_norm~ : Double = 1.0,
  clip_value~ : Double = 0.0,
) -> Unit raise TensorError {
  if smc_adam_native(self.backend, self.native, clip_norm, clip_value) != 0 {
    self.backend.check()
  }
}
