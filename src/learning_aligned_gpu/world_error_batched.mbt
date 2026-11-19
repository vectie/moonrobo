///|
// Rollout remains sequential and differentiable through every model step.
// Only the independent per-step error graphs are batched. Returning time slices
// preserves the original B x T stack, mask and loss reduction order.
fn Learner::batched_world_errors(
  self : Learner,
  predicted : Array[@geometry.State],
  targets : @tensor.Tensor,
  std : @tensor.Tensor,
  rows : Int32,
) -> Array[@tensor.Tensor] raise {
  let range = @tensor.operator_range_begin("diag.world.batched_state_error")
  errdefer @tensor.operator_range_cancel(range)
  let packed_targets = @geometry.State::from_flat71(
    self.backend,
    targets.transpose_dims(0, 1).reshape([-1, 71]),
  )
  let error = @geometry.state_error(
      self.backend,
      concat_states(self.backend, predicted),
      packed_targets,
      smc_rotation=self.optimizations.smc_world_rotation,
      heading_mode=self.optimizations.heading_mode,
      compact_heading=self.optimizations.compact_heading,
    )
    .div(std)
    .square()
    .mean_dim(-1)
  let errors = Array::makei(predicted.length(), j => {
    error.narrow(0, j * rows, rows)
  })
  @tensor.operator_range_end(range)
  errors
}
