///|
fn Learner::normalize_xi(
  self : Learner,
  xi : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.optimizations.smc_xi_normalization {
    xi.normalize_xi_smc()
  } else {
    @geometry.normalize_xi(self.backend, xi)
  }
}
