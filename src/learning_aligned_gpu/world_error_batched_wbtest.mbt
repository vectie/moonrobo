///|
test "batched world errors preserve masked losses gradients and two Adam updates" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP world error integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let context = micro_context(backend)
  let config = micro_config()
  let batch = micro_world_batch(backend)
  for chunk in [0, 2] {
    let original = Learner::new(
      backend,
      context,
      config~,
      world_microbatch=chunk,
    )
    let batched = Learner::new(
      backend,
      context,
      config~,
      world_microbatch=chunk,
      optimizations={
        ..ExecutionOptimizations::default(),
        world_error_batched: true,
      },
    )
    micro_observe(original, batch)
    micro_observe(batched, batch)
    for _ in 0..<2 {
      let a = original.fit_world_batch(batch)
      let b = batched.fit_world_batch(batch)
      assert_eq(a.wm_updates, b.wm_updates)
      micro_near(
        [b.wm_loss, b.wm_error_last],
        [a.wm_loss, a.wm_error_last],
        "batched error metrics",
      )
      for i, parameter in original.world.net.parameters() {
        micro_near(
          batched.world.net.parameters()[i].gradient_values(),
          parameter.gradient_values(),
          "batched error gradient \{i}",
        )
      }
      micro_compare_adam(
        batched.opt_world,
        original.opt_world,
        original.world.net.parameters().length(),
      )
    }
    assert_eq(
      original.checkpoint_metadata().normalizers.to_json(),
      batched.checkpoint_metadata().normalizers.to_json(),
    )
  }
}
