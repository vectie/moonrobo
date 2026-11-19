///|
/// Execution-only controls: zero retains the original complete-batch path.
/// These do not change logical batches, horizons, sample counts or any cap.
/// Callers must include this plan in durable run/resume identity when enabled.
pub(all) struct BatchExecutionPlan {
  world_microbatch : Int32
  actor_microbatch : Int32
} derive(ToJson, FromJson, Eq, Debug)

///|
fn BatchExecutionPlan::validate(
  self : BatchExecutionPlan,
  config : @aligned.LearnerConfig,
) -> Unit raise {
  guard self.world_microbatch >= 0 &&
    self.actor_microbatch >= 0 &&
    self.world_microbatch <= config.wm_batch &&
    self.actor_microbatch <= config.policy_batch else {
    fail("microbatch sizes must be zero or within the unchanged logical batch")
  }
}

///|
pub fn Learner::batch_execution(self : Learner) -> BatchExecutionPlan {
  self.execution
}

///|
fn world_batch_slice(
  batch : WorldBatch,
  start : Int32,
  count : Int32,
) -> WorldBatch raise {
  {
    s: batch.s.narrow(0, start, count),
    s1: batch.s1.narrow(0, start, count),
    actions: batch.actions.narrow(0, start, count),
    xi: batch.xi.narrow(0, start, count),
    mask: batch.mask.narrow(0, start, count),
  }
}

///|
// The local scope releases each complete time-unrolled graph after backward.
// Detached scalar tensors keep metric readback outside the chunk loop without
// retaining an earlier activation graph or changing the CPU accumulation order.
fn Learner::backward_world_chunk(
  self : Learner,
  batch : WorldBatch,
  logical_batch : Int32,
) -> (@tensor.Tensor, @tensor.Tensor, @tensor.Tensor) raise {
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let world_forward_timing = @tensor.profile_begin("world.forward")
  errdefer @tensor.profile_cancel(world_forward_timing)
  let shape = batch.s.shape()
  let n = shape[0]
  let mut state = @geometry.State::from_flat71(
    self.backend,
    time_slice(batch.s, 0, 71),
  )
  let std = self.world.output_norm.std().maximum(self.error_floor)
  let norms = self.snapshot_world_norms()
  let errors = []
  let predicted = []
  for j in 0..<shape[1] {
    let step_range = if diagnostic {
      @tensor.operator_range_begin("diag.world.step.\{j}")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(step_range)
    let action = time_slice(batch.actions, j, 29)
    let xi_n = self.normalize_xi(time_slice(batch.xi, j, 33))
    let delta = self.world.delta_fitting(
      @geometry.world_inputs(
        self.backend,
        state,
        action,
        xi_n,
        heading_mode=self.optimizations.heading_mode,
        compact_heading=self.optimizations.compact_heading,
      ),
      norms,
    )
    state = self.context.project_state(
      @geometry.world_integrate(
        self.backend,
        state,
        delta,
        heading_mode=self.optimizations.heading_mode,
        compact_heading=self.optimizations.compact_heading,
        detached_constants=self.optimizations.detached_rotation_constants,
        compact_skew=self.optimizations.compact_skew,
        fused_skew=self.optimizations.fused_skew,
        fused_so3_tail=self.optimizations.fused_so3_tail,
        fused_so3_coefficients=self.optimizations.fused_so3_coefficients,
        fused_so3_coefficients_forward=self.optimizations.fused_so3_coefficients_forward,
        fused_so3_coefficients_full=self.optimizations.fused_so3_coefficients_full,
        split_so3_coefficients=self.optimizations.split_so3_coefficients,
        split_delta=self.optimizations.split_world_delta,
      ),
    )
    if self.optimizations.world_error_batched {
      predicted.push(state)
    } else {
      let target = @geometry.State::from_flat71(
        self.backend,
        time_slice(batch.s1, j, 71),
      )
      errors.push(
        @geometry.state_error(
          self.backend,
          state,
          target,
          heading_mode=self.optimizations.heading_mode,
          compact_heading=self.optimizations.compact_heading,
          smc_rotation=self.optimizations.smc_world_rotation,
        )
        .div(std)
        .square()
        .mean_dim(-1),
      )
    }
    @tensor.operator_range_end(step_range)
  }
  if self.optimizations.world_error_batched {
    errors.append(self.batched_world_errors(predicted, batch.s1, std, n))
  }
  let loss = self.backend
    .stack(errors, axis=1)
    .mul(batch.mask)
    .sum()
    .affine(1.0 / logical_batch.to_double())
  @tensor.profile_end(world_forward_timing)
  @tensor.profile_span("world.backward", () => loss.backward())
  let mask = batch.mask.narrow(1, shape[1] - 1, 1).reshape([n])
  (
    loss.stop_gradient(),
    errors[shape[1] - 1].stop_gradient().mul(mask).sum().stop_gradient(),
    mask.sum().stop_gradient(),
  )
}

///|
fn Learner::fit_world_microbatches(
  self : Learner,
  batch : WorldBatch,
  logical_batch : Int32,
) -> WorldMetrics raise {
  self.opt_world.zero_grad()
  let metrics = []
  for start = 0; start < logical_batch; {
    let count = self.execution.world_microbatch.min(logical_batch - start)
    let (chunk_loss, chunk_last, chunk_count) = self.backward_world_chunk(
      world_batch_slice(batch, start, count),
      logical_batch,
    )
    metrics.push(chunk_loss)
    metrics.push(chunk_last)
    metrics.push(chunk_count)
    continue start + count
  }
  // Stack copies scalar values only; reduction stays in Double on the CPU in
  // the original chunk order, rather than introducing a device-side reduction.
  let values = self.backend.stack(metrics).values()
  metrics.clear()
  let mut loss = 0.0
  let mut last_sum = 0.0
  let mut last_count = 0.0
  for i = 0; i < values.length(); i = i + 3 {
    loss += values[i]
    last_sum += values[i + 1]
    last_count += values[i + 2]
  }
  if self.collective is Some(_) {
    @tensor.profile_span("world.communication", () => {
      self.average_gradients(self.world.net.parameters())
    })
  }
  @tensor.profile_span("world.adam", () => {
    self.optimizer_step(self.opt_world, clip_norm=1.0)
  })
  {
    wm_loss: loss / self.config.wm_window.to_double(),
    wm_error_last: last_sum / last_count.max(1.0),
    wm_updates: 1,
  }
}
