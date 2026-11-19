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
  if self.optimizations.smc_source_order {
    // SMC stacks complete states on the second (B,T) axis before its error
    // graph. Preserve that dataflow and its backward accumulation order.
    let pack = (values : Array[@tensor.Tensor], width : Int32) => {
      self.backend.stack(values, axis=1).reshape([-1, width])
    }
    let states : @geometry.State = {
      p: pack(predicted.map(s => s.p), 3),
      rotation: self.backend
      .stack(predicted.map(s => s.rotation), axis=1)
      .reshape([-1, 3, 3]),
      v: pack(predicted.map(s => s.v), 3),
      w: pack(predicted.map(s => s.w), 3),
      q: pack(predicted.map(s => s.q), 29),
      qd: pack(predicted.map(s => s.qd), 29),
    }
    let reference = @geometry.State::from_flat71(
      self.backend,
      targets.reshape([-1, 71]),
    )
    let error = @geometry.state_error(
        self.backend,
        states,
        reference,
        smc_rotation=true,
        heading_mode=self.optimizations.heading_mode,
        compact_heading=self.optimizations.compact_heading,
      )
      .div(std)
      .square()
      .mean_dim(-1)
      .reshape([rows, predicted.length()])
    return Array::makei(predicted.length(), j => {
      error.narrow(1, j, 1).reshape([rows])
    })
  }
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
