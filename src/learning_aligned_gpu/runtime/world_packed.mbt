///|
fn sample_world_batch_packed(
  backend : @tensor.Backend,
  replay : @aligned.ReplayBuffer,
  config : @aligned.LearnerConfig,
  rng : @numeric.Rng,
  device : Int32,
  dtype : @tensor.DType,
  limits : BatchLimits,
  max_bytes : Int64,
) -> @gpu.WorldBatch raise {
  // Retain the full conservative staging reserve. Do not credit the eliminated
  // decoded objects or fixed-array copy against any admission threshold.
  let usage = world_staging_usage(
    config.wm_batch,
    config.wm_window,
    max_bytes~,
    limits~,
  )
  guard dtype == Float32 || dtype == Float64 else {
    fail("packed world staging requires Float32 or Float64")
  }
  let fields = @tensor.profile_span("batch.world.replay_pack", () => {
    replay.sample_world_fields(
      config.wm_batch,
      config.wm_window,
      n => rng.index(n),
      max_values=usage.logical_values,
    )
  })
  let upload = (data, shape) => {
    @tensor.profile_span("batch.upload", () => {
      backend.from_fixed_values(
        shape,
        data,
        cuda_device=device,
        requires_grad=false,
        dtype~,
      )
    })
  }
  {
    s: upload(fields.s, [config.wm_batch, config.wm_window, 71]),
    s1: upload(fields.s1, [config.wm_batch, config.wm_window, 71]),
    actions: upload(fields.actions, [config.wm_batch, config.wm_window, 29]),
    xi: upload(fields.xi, [config.wm_batch, config.wm_window, 33]),
    mask: upload(fields.mask, [config.wm_batch, config.wm_window]),
  }
}
