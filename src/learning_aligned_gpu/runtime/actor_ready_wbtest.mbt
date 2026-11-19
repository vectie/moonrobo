///|
fn actor_row(frame : Int32) -> @aligned.Transition {
  {
    s: Array::make(71, 0.0),
    s1: Array::make(71, 0.0),
    a: Array::make(29, 0.0),
    a_prev: Array::make(29, 0.0),
    xi: Array::make(33, 0.0),
    r: 0.0,
    frame,
    ep_step: 0,
    terminated: false,
    truncated: true,
  }
}

///|
test "actor readiness uses exact same-clip horizon and observes ring overwrites" {
  let replay = @aligned.ReplayBuffer::new(4, 1)
  replay.add([actor_row(31)])
  replay.add([actor_row(32)])
  assert_eq(replay.actor_start_count(_ => 63, 32), (1, 32))
  let report = replay.ensure_actor_ready(_ => 63, 32, 2, _ => {
    fail("must not collect")
  })
  assert_eq(report.extra_collection_steps, 0)
  let starts = replay.sample_starts(4, 3, _ => 0, clip_end=_ => 63, horizon=32)
  assert_true(starts.all(start => start.start.frame == 31))
  assert_true(starts[0].history.all(tr => tr.frame == 31))
  for _ in 0..<4 {
    replay.add([actor_row(62)])
  }
  assert_eq(replay.actor_start_count(_ => 63, 32), (0, 1))
  let steps = [0]
  let report = replay.ensure_actor_ready(_ => 63, 32, 2, count => {
    for _ in 0..<count {
      steps[0] += 1
      replay.add([actor_row(if steps[0] >= 3 { 0 } else { 62 })])
    }
  })
  assert_eq(report.extra_collection_steps, 4)
  assert_eq(report.extra_physical_transitions, 4L)
  assert_eq(report.collection_step_budget, 32)
  assert_eq(report.candidates, 2)
}

///|
test "actor refill collective branch keeps ready and unready ranks in lockstep" {
  let collected : Array[Int32] = []
  let first_need : Array[Bool] = []
  for ready in [true, false] {
    let replay = @aligned.ReplayBuffer::new(8, 1)
    replay.add([actor_row(if ready { 0 } else { 62 })])
    let steps = [0]
    let syncs = [0]
    let needs : Array[Bool] = []
    let report = replay.ensure_actor_ready(
      _ => 63,
      32,
      2,
      count => {
        for _ in 0..<count {
          steps[0] += 1
          replay.add([actor_row(if ready || steps[0] >= 4 { 0 } else { 62 })])
        }
      },
      // Deterministic two-rank control trace, not a real NCCL execution.
      any_need=local => {
        needs.push(local)
        local || steps[0] < 4
      },
      after_collect=() => syncs[0] += 1,
    )
    collected.push(report.extra_collection_steps)
    first_need.push(needs[0])
    assert_eq(syncs[0], 2)
  }
  assert_eq(collected, [4, 4])
  assert_eq(first_need, [false, true])
}

///|
test "actor refill finite peer failure reaches locally ready rank too" {
  for ready in [true, false] {
    let replay = @aligned.ReplayBuffer::new(8, 1)
    replay.add([actor_row(if ready { 0 } else { 62 })])
    let steps = [0]
    let decisions = [0]
    try
      replay.ensure_actor_ready(
        _ => 63,
        32,
        3,
        count => {
          steps[0] += count
          for _ in 0..<count {
            replay.add([actor_row(if ready { 0 } else { 62 })])
          }
        },
        any_need=_ => {
          decisions[0] += 1
          true
        },
        context="rank-local-or-peer",
      )
    catch {
      error => {
        assert_true(error.to_string().contains("finite collection budget"))
        assert_true(error.to_string().contains("rank-local-or-peer"))
      }
    } noraise {
      _ => fail("peer failure must stop every rank")
    }
    assert_eq(steps[0], 32)
    assert_eq(decisions[0], 12) // 11 chunks, including final two steps, then fail.
    assert_eq(
      replay.actor_start_count(_ => 63, 32).0,
      if ready {
        8
      } else {
        0
      },
    )
  }
}

///|
test "actor horizon catalog check rejects impossible task without filtering short clips" {
  let (_, motion, _) = fixture()
  let before = motion.names.copy()
  ignore(motion.require_actor_horizon(15))
  try motion.require_actor_horizon(16) catch {
    error => assert_true(error.to_string().contains("H+1 states required"))
  } noraise {
    _ => fail("entire short catalog must reject")
  }
  assert_eq(motion.names, before)
}

///|
test "GPU runner CPU regression refills tail-only actor replay before updates" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP actor refill learner integration: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let b = @tensor.Backend::open(path)
  let (kin, motion, c) = fixture()
  let learner = @gpu.Learner::new(
    b,
    @geometry.Context::new(b, kin, -1),
    config=c,
  )
  let runner = TrainingRunner::new(learner, motion, 8, 1)
  let frame = [14]
  let steps = [0]
  runner.run(
    {
      iterations: 1,
      warmup_steps: 2,
      world_only_iterations: 0,
      update_to_data: 1.0,
      learning_rate_decay_iterations: 10,
      action_noise: 0.0,
    },
    () => {
      [
        {
          state: motion.states[frame[0]],
          previous: Array::make(29, 0.0),
          xi: Array::makei(33, i => if i == 0 { 0.8 } else { 0.0 }),
          frame: frame[0],
          episode_step: 0,
        },
      ]
    },
    actions => {
      let f = frame[0]
      steps[0] += 1
      frame[0] = if steps[0] >= 4 { 0 } else { 14 }
      [{ ..transition(motion, f, 0, done=true), a: actions[0].copy(), }]
    },
    metrics => {
      guard metrics.actor_readiness is Some(ready) else {
        fail("missing readiness")
      }
      assert_eq(ready.initial_candidates, 0)
      assert_eq(ready.extra_collection_steps, 2)
      assert_eq(ready.extra_physical_transitions, 2L)
    },
  )
  assert_eq(runner.counters.physical_transitions, 5L)
  assert_eq(runner.counters.actor_updates, 1L)
  assert_eq(runner.counters.model_updates, 1L)
  assert_eq(learner.policy.obs_norm.count, 5.0)
}
