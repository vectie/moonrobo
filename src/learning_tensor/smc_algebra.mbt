///|
#borrow(backend)
extern "c" fn has_smc_algebra_native(backend : Backend) -> Int32 = "mr_tensor_has_smc_algebra"

///|
pub fn Backend::has_smc_algebra(self : Backend) -> Bool {
  has_smc_algebra_native(self) != 0
}

///|
#borrow(backend)
extern "c" fn has_smc_source_order_native(backend : Backend) -> Int32 = "mr_tensor_has_smc_source_order"

///|
pub fn Backend::has_smc_source_order(self : Backend) -> Bool {
  has_smc_source_order_native(self) != 0
}

///|
#borrow(backend, x)
extern "c" fn smc_unary_native(
  backend : Backend,
  x : NativeTensor,
  kind : Int32,
) -> NativeTensor = "mr_tensor_smc_unary_call"

///|
#borrow(backend, r, d, tail)
extern "c" fn smc_return_native(
  backend : Backend,
  r : NativeTensor,
  d : NativeTensor,
  tail : NativeTensor,
  gamma : Double,
) -> NativeTensor = "mr_tensor_smc_return_call"

///|
/// SMC matrix-to-quaternion and quaternion-to-rotation-vector ATen expressions.
/// [B,3,3] -> [B,3], B <= 131072; FP32/FP64 CPU/CUDA, with native autograd.
pub fn Tensor::rotation_vector_smc(self : Tensor) -> Tensor raise TensorError {
  let native = smc_unary_native(self.backend, self.native, 0)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Preserve SMC's subtraction/division order for [B,33] domain parameters.
pub fn Tensor::normalize_xi_smc(self : Tensor) -> Tensor raise TensorError {
  let native = smc_unary_native(self.backend, self.native, 1)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Source-order SMC Rodrigues expression with native ATen autograd.
pub fn Tensor::rotation_matrix_smc(self : Tensor) -> Tensor raise TensorError {
  let native = smc_unary_native(self.backend, self.native, 2)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Source-order projected heading with native ATen autograd.
pub fn Tensor::heading_matrix_smc(self : Tensor) -> Tensor raise TensorError {
  let native = smc_unary_native(self.backend, self.native, 3)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Corrected projected heading used by the aligned MDP, with ATen source order.
pub fn Tensor::heading_matrix_stable(self : Tensor) -> Tensor raise TensorError {
  let native = smc_unary_native(self.backend, self.native, 4)
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// [H,B] rewards and failure probabilities, [B] critic tail -> [3,B]:
/// discounted return including tail, detached undiscounted weighted reward,
/// and final survival. Uses SMC cumprod/discount/reduction order; H<=64 and
/// H*B<=262144. The caller retains gradient clipping and optimizer checks.
pub fn Tensor::actor_return_smc(
  self : Tensor,
  failures : Tensor,
  tail : Tensor,
  gamma : Double,
) -> Tensor raise TensorError {
  let native = smc_return_native(
    self.backend,
    self.native,
    failures.native,
    tail.native,
    gamma,
  )
  self.backend.check()
  { backend: self.backend, native, }
}
