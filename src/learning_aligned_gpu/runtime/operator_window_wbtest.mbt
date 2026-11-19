///|
test "selected actor window includes preparation and cancels preparation failure" {
  guard @env.get_env_var("MOONROBO_OPERATOR_DIAGNOSTIC_TEST") == Some("1") else {
    println(
      "SKIP runtime operator window fixture: set MOONROBO_OPERATOR_DIAGNOSTIC_TEST=1",
    )
    return
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    fail("explicit runtime diagnostic fixture requires a diagnostic CPU plugin")
  }
  let backend = @tensor.Backend::open(path)
  for fail_preparation in [false, true] {
    let (kin, motion, config) = fixture()
    let learner = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, -1),
      config~,
    )
    let runner = TrainingRunner::new(learner, motion, 8, 1)
    // Establish a small resumed CPU state so the real runtime executes only
    // iteration41. The test does not skip any work inside that iteration.
    runner.iteration = 40
    for frame in 0..<4 {
      runner.replay.add([transition(motion, frame, frame)])
    }
    @tensor.configure_operator_diagnostics(
      backend,
      cuda_device=-1,
      iteration=41,
      structural_only=true,
      max_ranges=8192,
    )
    defer (@tensor.clear_operator_diagnostics() catch { _ => () })
    let failed = try {
      runner.run(
        {
          iterations: 41,
          warmup_steps: 2,
          world_only_iterations: 20,
          update_to_data: 1.0,
          learning_rate_decay_iterations: 60,
          action_noise: 0.0,
        },
        () => {
          [
            {
              state: motion.states[0],
              previous: Array::make(29, 0.0),
              xi: Array::makei(33, i => if i == 0 { 0.8 } else { 0.0 }),
              frame: 0,
              episode_step: 0,
            },
          ]
        },
        actions => [{ ..transition(motion, 0, 0), a: actions[0].copy(), }],
        _ => (),
        on_phase=Some((phase, _) => {
          if fail_preparation && phase == "world_updates_complete" {
            // Mutate only this synthetic eager catalog after world/collection
            // work. All possible preview rows will now fail the existing
            // finite-value guard inside sample_policy_batch, after window start.
            for frame in 0..<motion.states.length() {
              motion.states[frame].q[0] = 0.0 / 0.0
            }
          }
        }),
      )
      false
    } catch {
      error => {
        guard fail_preparation && error.to_string().contains("nonfinite") else {
          raise error
        }
        true
      }
    }
    assert_eq(failed, fail_preparation)
    assert_false(@tensor.operator_diagnostics_enabled())
    let report = @json.parse(@tensor.operator_diagnostics_report())
    guard report
      is {
        "structural_only": True,
        "cuda_events_created": Number(0),
        "open_ranges": Number(0),
        "ranges": Array(ranges),
        ..
      } else {
      fail("invalid runtime structural diagnostic report")
    }
    let mut prepare_count = 0
    let mut prepare_id = 0.0
    let mut parent_id = 0.0
    for entry in ranges {
      if entry
        is {
          "label": String("diag.actor.prepare"),
          "id": Number(id),
          "parent": Number(parent),
          "cancelled": cancelled,
          ..
        } {
        prepare_count += 1
        prepare_id = id
        parent_id = parent
        assert_eq(cancelled, Json(fail_preparation))
      }
    }
    assert_eq(prepare_count, 1)
    assert_eq(prepare_id, 2.0)
    assert_eq(parent_id, 1.0)
    assert_true(
      ranges[0] is { "label": String("diag.iteration.41.actor_critic"), .. },
    )
    if fail_preparation {
      assert_true(report is { "completed": False, "cancelled": True, .. })
      assert_true(ranges.length() >= 2)
      assert_eq(runner.counters.actor_updates, 0L)
      assert_eq(runner.iteration, 40)
    } else {
      assert_true(report is { "completed": True, "cancelled": False, .. })
      assert_true(ranges.length() > 2)
      assert_eq(runner.counters.actor_updates, 1L)
      assert_eq(runner.counters.critic_updates, 1L)
      assert_eq(runner.iteration, 41)
    }
    assert_eq(runner.counters.model_updates, 1L)
    @tensor.clear_operator_diagnostics()
  }
}
