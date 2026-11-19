///|
/// CPU contracts translated from test_aligned_learning/evaluation/resume.
/// Fixtures below exercise algorithms only; genuine physics lives in physics/*test.
fn contract_learner(
  horizon~ : Int32 = 2,
  hist~ : Int32 = 3,
  frames~ : Int32 = 40,
) -> Learner raise {
  let row = [0.0, 0.0, 0.76, 0.0, 0.0, 0.0, 1.0]
  row.append(default_joint_positions())
  let motion = MotionLibrary::new(
    [
      {
        name: "cpu-contract",
        sha256: "algorithm-fixture",
        rows: Array::makei(frames, _ => row.copy()),
      },
    ],
    fixture_kin(),
    source_fps=50.0,
  )
  let d = LearnerConfig::default()
  Learner::new(
    fixture_kin(),
    motion,
    config={
      ..d,
      wm_hidden: [8, 8, 8],
      policy_hidden: [8, 6],
      critic_hidden: [8, 4],
      hist,
      goal_frames: 1,
      horizon,
      wm_window: 8,
      wm_batches: 1,
      wm_batch: 2,
      policy_batch: 2,
      critic_epochs: 1,
      critic_minibatches: 3,
      observation_noise: false,
    },
    seed=7U,
  )
}

///|
test "source GAE failure timeout and soft-failure contracts" {
  let r = [[1.0], [2.0], [100.0]]
  let v = [[4.0], [5.0], [6.0], [7.0]]
  let failed = lambda_returns(r, v, [[0.0], [1.0], [0.0]], gamma=0.9, lam=1.0)
  assert_true((failed[0][0] - 2.8).abs() < 1.0e-12)
  assert_eq(failed[1], [2.0])
  let timeout = lambda_returns(
    r,
    v,
    [[0.0], [0.0], [0.0]],
    truncated=[[false], [true], [false]],
    gamma=0.9,
    lam=1.0,
  )
  assert_true((timeout[1][0] - 7.4).abs() < 1.0e-12)
  assert_true((timeout[0][0] - 7.66).abs() < 1.0e-12)
  let soft = lambda_returns([[1.0]], [[4.0], [5.0]], [[0.25]], gamma=0.9)
  assert_true((soft[0][0] - 4.375).abs() < 1.0e-12)
}

///|
test "source replay warmup boundaries complete imagination and empty restore" {
  let b = ReplayBuffer::new(8, 1)
  assert_true(!b.can_sample_windows(8))
  assert_true(
    (Ok(b.sample_windows(2, 8, _ => 0)) catch { e => Err(e) }) is Err(_),
  )
  for i in 0..<8 {
    b.add([
      fixture_transition(
        if i < 3 {
          i
        } else {
          i + 40
        },
        if i < 3 {
          i
        } else {
          i - 3
        },
        truncated=i == 2,
      ),
    ])
  }
  let w = b.sample_windows(1, 8, _ => 0)[0]
  assert_eq(w.mask, [1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])
  assert_true(w.transitions[2].truncated && !w.transitions[2].terminated)
  for age in 0..<8 {
    let start = b.sample_starts(1, 10, _ => age)[0]
    assert_eq(start.history[9].frame, start.start.frame)
    assert_true(
      start.history.all(t => {
        if start.start.frame < 3 {
          t.frame < 3
        } else {
          t.frame >= 43
        }
      }),
    )
  }
  assert_true(
    (Ok(b.sample_starts(1, 10, _ => 0, clip_end=_ => 30, horizon=32)) catch {
      e => Err(e)
    })
    is Err(_),
  )
  for i in 8..<12 {
    b.add([fixture_transition(i, i)])
  }
  let restored = ReplayBuffer::new(8, 1)
  restored.restore(b.snapshot())
  assert_eq(
    restored.sample_windows(1, 8, _ => 0)[0].transitions.map(t => t.frame),
    [44, 45, 46, 47, 8, 9, 10, 11],
  )
  restored.restore([])
  assert_true(!restored.can_sample_windows(8))
}

///|
test "source frozen critic retains input gradient without changing weights" {
  let critic = Critic::new(4, @numeric.Rng::new(7U), hidden=[8])
  let before = critic.net.parameters.copy()
  let tape = @numeric.Tape::new()
  let x = tape.vector([1.0, 1.0, 1.0, 1.0])
  let result = critic.net.forward(
      tape,
      critic.net.bind(tape),
      critic.norm.apply_ad(tape, x),
    )[0]
  tape.backward(result)
  assert_true(
    x.map(v => tape.gradient(v).abs()).fold(init=0.0, (a, b) => a + b) > 0.0,
  )
  assert_eq(critic.net.parameters, before)
}

///|
test "source eight-step model thirty-two-step actor and imagined critic update" {
  let learner = contract_learner(horizon=32, hist=10)
  let replay = ReplayBuffer::new(16, 1)
  for i in 0..<16 {
    let tr = fixture_transition(i, i)
    replay.add([tr])
    learner.observe(tr)
  }
  let fit = learner.fit_world_model(replay)
  assert_eq(fit.updates, 1)
  assert_true(finite(fit.loss))
  let wm = learner.wm.net.parameters.copy()
  let critic = learner.critic.net.parameters.copy()
  let policy = learner.policy.decoder.parameters.copy()
  let actor = learner.update_policy(replay, train_critic=false)
  assert_eq(actor.imagined_steps, 64)
  assert_eq(actor.critic_updates, 0)
  assert_eq(learner.wm.net.parameters, wm)
  assert_eq(learner.critic.net.parameters, critic)
  assert_true(learner.policy.decoder.parameters != policy)
  let full = learner.update_policy(replay)
  assert_eq(full.critic_updates, 3)
  assert_true(
    finite(full.policy_loss) &&
    finite(full.critic_loss) &&
    finite(full.gradient_norm),
  )
  let replica = contract_learner(horizon=32, hist=10)
  replica.restore(learner.snapshot())
  assert_eq(replica.snapshot().to_json(), learner.snapshot().to_json())
}

///|
test "source zero-initialized world identity has finite state and action gradients" {
  let wm = WorldModel::new(@numeric.Rng::new(7U), hidden=[8, 8, 8])
  let t = @numeric.Tape::new()
  let s = lift(t, fixture_state())
  let state_values = s.p.copy()
  for values in [s.rotation, s.v, s.w, s.q, s.qd] {
    state_values.append(values)
  }
  let action = t.vector(Array::make(29, 0.0))
  let next = wm.step_ad(t, wm.net.bind(t), s, action, Array::make(33, 0.0))
  let prediction = next.p.copy()
  for values in [next.rotation, next.v, next.w, next.q, next.qd] {
    prediction.append(values)
  }
  let loss = t.add(
    ad_square(t, prediction),
    ad_square(t, ad_state_error(t, next, fixture_state())),
  )
  t.backward(loss)
  assert_true(state_values.all(v => finite(t.gradient(v))))
  assert_true(action.all(v => finite(t.gradient(v))))
}

///|
test "source export reorders joints and rotates world angular velocity" {
  let flat = flatten_state({
    p: [1.0, 2.0, 3.0],
    rotation: axis_angle_to_mat([0.0, 0.0, 1.0], @math.PI / 2.0),
    v: [4.0, 5.0, 6.0],
    w: [0.0, 1.0, 0.0],
    q: Array::makei(29, i => i.to_double()),
    qd: Array::makei(29, i => i.to_double() + 100),
  })
  let converted = mujoco_state(flat, {
    nq: 36,
    nv: 35,
    na: 0,
    qpos_addresses: Array::makei(29, i => 35 - i),
    qvel_addresses: Array::makei(29, i => 34 - i),
  })
  assert_eq(
    converted[7:36].to_owned(),
    Array::makei(29, i => (28 - i).to_double()),
  )
  assert_eq(converted[36:39].to_owned(), [4.0, 5.0, 6.0])
  assert_true(
    (converted[39] - 1.0).abs() < 1.0e-12 &&
    converted[40].abs() < 1.0e-12 &&
    converted[41].abs() < 1.0e-12,
  )
  assert_eq(
    converted[42:].to_owned(),
    Array::makei(29, i => (128 - i).to_double()),
  )
}

///|
test "source negative final-frame failure and strict tracking stay distinct" {
  let negative = summarize_evaluations([
    {
      clip_id: "negative",
      expected_steps: 1,
      rewards: [-0.2],
      terminated: true,
      strict_rmse: None,
      termination_frame: Some(1),
    },
  ])
  assert_eq(negative.norm_return, -2.0)
  assert_eq(negative.failed, ["negative"])
  assert_eq(negative.completed, 1)
  let strict = summarize_evaluations([
    {
      clip_id: "complete",
      expected_steps: 1,
      rewards: [0.08],
      terminated: false,
      strict_rmse: Some({
        "joint_rmse_rad": 0.04,
        "body_position_rmse_m": 0.01,
        "root_position_rmse_m": 0.01,
        "root_orientation_rmse_rad": 0.01,
      }),
      termination_frame: None,
    },
  ])
  assert_true(strict.failed.is_empty() && !strict.strict_all_passed)
  let timeout = summarize_evaluations(
    [
      {
        clip_id: "timeout",
        expected_steps: 100,
        rewards: Array::make(10, 0.1),
        terminated: false,
        strict_rmse: None,
        termination_frame: None,
      },
    ],
    expected_clip_ids=["timeout", "missing"],
  )
  assert_true(!timeout.benchmark_complete)
  assert_eq(timeout.incomplete_protocol_clips, ["timeout"])
  assert_eq(timeout.missing_clips, ["missing"])
}

///|
test "source duplicate nonfinite and invalid evaluation results rejected" {
  let trial : ClipEvaluation = {
    clip_id: "same",
    expected_steps: 1,
    rewards: [0.1],
    terminated: false,
    strict_rmse: None,
    termination_frame: None,
  }
  assert_true(
    (Ok(summarize_evaluations([trial, trial])) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(summarize_evaluations([{ ..trial, rewards: [0.0 / 0.0], }])) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(summarize_evaluations([{ ..trial, rewards: [0.1, 0.1], }])) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(summarize_evaluations([trial], expected_clip_ids=["same", "same"])) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(
      summarize_evaluations([
        { ..trial, strict_rmse: Some({ "joint_rmse_rad": -1.0 }), },
      ]),
    ) catch {
      e => Err(e)
    })
    is Err(_),
  )
}

///|
test "source evaluation subset replica and training environment contracts" {
  let learner = contract_learner(frames=4)
  let resets = []
  let actions = []
  let frame = Ref::new(0)
  let settings : EvaluationSettings = {
    eval_mode: true,
    auto_reset: false,
    timeout_disabled: true,
    observation_noise: false,
    domain_randomization: false,
    simulated_replica_count: 4,
  }
  let inspect : () -> CollectorFrame raise = fn() {
    {
      state: fixture_state(),
      previous: Array::make(29, 0.0),
      xi: fixture_transition(0, 0).xi,
      frame: frame.val,
      episode_step: frame.val,
    }
  }
  let step : (Array[Double]) -> Transition raise = fn(a) {
    actions.push(a)
    let tr = fixture_transition(frame.val, frame.val, truncated=frame.val == 2)
    frame.val += 1
    tr
  }
  let result = learner.evaluate(
    settings,
    f => {
      resets.push(f)
      frame.val = f
    },
    inspect,
    step,
    strict_tracking=false,
  )
  assert_eq(resets, [0])
  assert_eq(actions.length(), 3)
  let report = result.report_json(
    ["cpu-contract"],
    {},
    simulated_replica_count=4,
  )
  guard report is Object(fields) else {
    fail("evaluation report must be object")
  }
  assert_eq(
    fields.get("evaluation_simulated_physical_steps"),
    Some((12).to_json()),
  )
  assert_eq(fields.get("full_catalog_evaluated"), Some(true.to_json()))
  assert_true(
    (Ok(
      learner.evaluate(
        { ..settings, auto_reset: true, },
        _ => (),
        inspect,
        step,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(learner.evaluate(settings, _ => (), inspect, step, clip_indices=[])) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(learner.evaluate(settings, _ => (), inspect, step, clip_indices=[0, 0])) catch {
      e => Err(e)
    })
    is Err(_),
  )
}

///|
test "source full-clip driver clears history across failure and subset evaluation" {
  let row = [0.0, 0.0, 0.76, 0.0, 0.0, 0.0, 1.0]
  row.append(default_joint_positions())
  let clips = Array::makei(2, c => {
    name: if c == 0 {
      "fails"
    } else {
      "finishes"
    },
    sha256: "fixture",
    rows: Array::makei(if c == 0 { 6 } else { 3 }, i => {
      let r = row.copy()
      r[7] += c.to_double() * 0.2 + i.to_double() * 0.01
      r
    }),
  })
  let motion = MotionLibrary::new(clips, fixture_kin(), source_fps=50.0)
  let config = contract_learner().config
  let learner = Learner::new(fixture_kin(), motion, config~, seed=7U)
  let frame = Ref::new(0)
  let previous = Ref::new(Array::make(29, 0.0))
  let resets = []
  let actions = []
  let reset : (Int32) -> Unit raise = f => {
    resets.push(f)
    frame.val = f
    previous.val = Array::make(29, 0.0)
  }
  let inspect : () -> CollectorFrame raise = () => {
    state: motion.states[frame.val],
    previous: previous.val,
    xi: fixture_transition(0, 0).xi,
    frame: frame.val,
    episode_step: 0,
  }
  let step : (Array[Double]) -> Transition raise = a => {
    let f = frame.val
    actions.push(a)
    previous.val = a
    frame.val = f + 1
    fixture_transition(
      f,
      f,
      terminated=f == 0,
      truncated=f == motion.clip_end[1] - 1,
    )
  }
  let settings : EvaluationSettings = {
    eval_mode: true,
    auto_reset: false,
    timeout_disabled: true,
    observation_noise: false,
    domain_randomization: false,
    simulated_replica_count: 1,
  }
  let result = learner.evaluate(
    settings,
    reset,
    inspect,
    step,
    strict_tracking=false,
  )
  let start = motion.clip_start[1]
  assert_eq(resets, [0, start])
  assert_eq(actions.length(), 3)
  assert_eq(result.failed, ["fails"])
  assert_true(result.benchmark_complete)
  let xi = fixture_transition(0, 0).xi
  let obs = observation(
    motion.states[start],
    Array::make(29, 0.0),
    xi,
    default_joint_positions(),
    motion.states[start],
    Paper,
  )
  assert_eq(
    actions[1],
    learner.policy.forward(
      Array::makei(config.hist, _ => obs.copy()),
      motion.goal(start, config.goal_frames),
    ),
  )
  let next = observation(
    motion.states[start + 1],
    actions[1],
    xi,
    default_joint_positions(),
    motion.states[start + 1],
    Paper,
  )
  let history = Array::makei(config.hist, _ => obs.copy())
  history[config.hist - 1] = next
  assert_eq(
    actions[2],
    learner.policy.forward(history, motion.goal(start + 1, config.goal_frames)),
  )
  resets.clear()
  actions.clear()
  let subset = learner.evaluate(
    settings,
    reset,
    inspect,
    step,
    clip_indices=[1],
    strict_tracking=false,
  )
  let report = subset.report_json(motion.names, {})
  guard report is Object(fields) else { fail("evaluation report") }
  assert_eq(fields["full_catalog_evaluated"], false.to_json())
  assert_eq(fields["catalog_clip_count"], (2).to_json())
  assert_true(subset.benchmark_complete)
}

///|
test "source warm-reset-refill retains learner counters but clears replay and histories" {
  let learner = contract_learner()
  let runner = TrainingRunner::new(learner, 8, 1)
  runner.replay.add([fixture_transition(0, 0)])
  runner.histories[0] = [Array::make(93, 0.5)]
  let saved = runner.checkpoint({}, {})
  let restored = TrainingRunner::new(contract_learner(), 8, 1)
  restored.restore(saved, false)
  assert_eq(restored.replay.size(), 0)
  assert_eq(restored.histories, [[]])
  assert_eq(restored.learner.snapshot().to_json(), saved.learner.to_json())
  assert_eq(restored.counters.to_json(), saved.counters.to_json())
}
