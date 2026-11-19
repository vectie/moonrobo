///|
// Opt-in experimental execution of the two original SMC world boundaries.
// Each exported package needs its own complete BF16 world-update gate against
// original SMC. A passing world package does not validate actor/critic training.
// Live weights/statistics are inputs; Adam, clipping and update order are shared
// with the existing path. No packages are loaded implicitly or on resume.
fn Learner::fit_compiled_world_window(
  self : Learner,
  batch : WorldBatch,
  rollout : @tensor.CompiledBlock,
  error : @tensor.CompiledBlock,
) -> WorldMetrics raise {
  let outputs = @tensor.profile_span("world.forward", () => {
    let predicted = rollout.forward_many(
      [
        batch.s,
        batch.actions,
        batch.xi,
        ..self.world.net.parameters(),
        self.world.input_norm.mean,
        self.world.input_norm.variance,
        self.world.output_norm.mean,
        self.world.output_norm.variance,
      ],
    )
    error.forward(
      [
        ..predicted,
        batch.s1,
        batch.mask,
        self.world.output_norm.variance,
        self.error_floor,
      ],
    )
  })
  let loss = outputs.narrow(0, 0, 1).sum()
  self.opt_world.zero_grad()
  @tensor.profile_span("world.backward", () => loss.backward())
  @tensor.profile_span("world.adam", () => {
    self.optimizer_step(self.opt_world, clip_norm=1.0)
  })
  let values = outputs.values()
  {
    wm_loss: values[0] / self.config.wm_window.to_double(),
    wm_error_last: values[1],
    wm_updates: 1,
  }
}
