///|
test "world norm snapshot preserves window gradients Adam and refreshed statistics" {
  guard actor_snapshot_test_backend() is Some((backend, device)) else { return }
  guard device == -1 else { fail("small world snapshot fixture is CPU only") }
  for microbatch in [0, 2] {
    let make = (enabled : Bool) => {
      Learner::new(
        backend,
        micro_context(backend),
        config=micro_config(),
        world_microbatch=microbatch,
        optimizations={
          ..ExecutionOptimizations::default(),
          world_norm_snapshot: enabled,
        },
      )
    }
    let a = make(false)
    let b = make(true)
    let batch = micro_world_batch(backend)
    for iteration in 0..<3 {
      for learner in [a, b] {
        learner.observe(
          batch.s.reshape([-1, 71]),
          batch.actions.reshape([-1, 29]),
          batch.xi.reshape([-1, 33]),
          batch.s1.reshape([-1, 71]),
        )
        if iteration > 0 {
          for norm in [learner.world.input_norm, learner.world.output_norm] {
            norm.update(
              norm.mean.reshape([1, norm.dim]).affine(1.0, bias=0.001),
            )
          }
        }
      }
      let x = a.fit_world_batch(batch)
      let y = b.fit_world_batch(batch)
      assert_eq(x.wm_updates, y.wm_updates)
      micro_near(
        [y.wm_loss, y.wm_error_last],
        [x.wm_loss, x.wm_error_last],
        "world snapshot metrics",
      )
      let ap = a.world.net.parameters()
      let bp = b.world.net.parameters()
      for i, p in ap {
        micro_near(bp[i].values(), p.values(), "snapshot world parameters")
        micro_near(
          bp[i].gradient_values(),
          p.gradient_values(),
          "snapshot world gradients",
        )
      }
      micro_compare_adam(b.opt_world, a.opt_world, ap.length())
      assert_eq(
        a.checkpoint_metadata().to_json(),
        b.checkpoint_metadata().to_json(),
      )
    }
  }
}
