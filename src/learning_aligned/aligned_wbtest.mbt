///|
fn fixture_state() -> State {
  {
    p: [0.0, 0.0, 0.76],
    rotation: identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: default_joint_positions(),
    qd: Array::make(29, 0.0),
  }
}

///|
fn fixture_kin() -> Kinematics {
  {
    bodies: [
      {
        name: "pelvis",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: Array::make(14, 0),
    q_lo: Array::make(29, -2.0),
    q_hi: Array::make(29, 2.0),
  }
}

///|
fn fixture_transition(
  frame : Int32,
  ep_step : Int32,
  terminated~ : Bool = false,
  truncated~ : Bool = false,
) -> Transition {
  let s = flatten_state(fixture_state())
  {
    s,
    s1: s.copy(),
    a: Array::make(29, 0.0),
    a_prev: Array::make(29, 0.0),
    xi: Array::makei(33, i => if i == 0 { 0.75 } else { 0.0 }),
    r: 0.1,
    frame,
    ep_step,
    terminated,
    truncated,
  }
}

///|
test "world normalizers consume one vectorized simulator step as a batch" {
  let first = fixture_transition(0, 0)
  let second = fixture_transition(1, 1)
  second.a[0] = 1.0
  second.s1[0] = 0.2
  let one = WorldModel::new(@numeric.Rng::new(7U), hidden=[4])
  let reversed = WorldModel::new(@numeric.Rng::new(7U), hidden=[4])
  one.observe_batch([first, second])
  reversed.observe_batch([second, first])
  assert_eq(one.input_norm.count, 2.0)
  assert_eq(one.output_norm.count, 2.0)
  for i in 0..<one.input_norm.mean.length() {
    assert_true(
      (one.input_norm.mean[i] - reversed.input_norm.mean[i]).abs() < 1.0e-14,
    )
  }
  for i in 0..<one.output_norm.mean.length() {
    assert_true(
      (one.output_norm.mean[i] - reversed.output_norm.mean[i]).abs() < 1.0e-14,
    )
  }
}

///|
test "rotation identity, pi and vertical heading are finite and canonical" {
  for axis in [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]] {
    let r = axis_angle_to_mat(axis, @math.PI)
    assert_true((square_norm(so3_log(r)).sqrt() - @math.PI).abs() < 0.000001)
    assert_true(mat_to_quat(r)[0] >= 0.0)
    assert_true(rot_angle_sq(r, r) < 1.0e-20)
  }
  let yaw = yaw_mat(axis_angle_to_mat([0.0, 1.0, 0.0], @math.PI / 2.0))
  assert_true(rot_angle_sq(mat_mul(yaw, transpose(yaw)), identity()) < 1.0e-20)
}

///|
test "MDP observation dimensions and identical reward" {
  let s = fixture_state()
  let kin = fixture_kin()
  let tr = fixture_transition(0, 0)
  for mode in [Paper, Smc, Observable] {
    assert_eq(
      observation(s, tr.a_prev, tr.xi, default_joint_positions(), s, mode).length(),
      mode.dim(),
    )
  }
  let terms = reward(kin, s, s, kin.forward(s), tr.a, tr.a_prev)
  assert_true((terms.reward - 0.1).abs() < 1.0e-12)
  assert_true(!termination(s, s))
}

///|
test "replay boundary keeps terminal target and excludes following episode" {
  let replay = ReplayBuffer::new(3, 1)
  replay.add([fixture_transition(0, 0, terminated=true)])
  replay.add([fixture_transition(20, 0)])
  replay.add([fixture_transition(21, 1)])
  let window = replay.sample_windows(1, 3, _ => 0)[0]
  assert_eq(window.mask, [1.0, 0.0, 0.0])
  let history = replay.sample_starts(1, 3, _ => 0)[0].history
  assert_eq(history.map(t => t.frame), [0, 0, 0])
  let saved = replay.snapshot()
  replay.add([fixture_transition(22, 2)])
  replay.restore(saved)
  assert_eq(replay.snapshot()[0][0].frame, 0)
}

///|
test "return sampler averages simultaneous completions and bootstraps truncation" {
  let sampler = ReturnBinSampler::new([{ start: 0, clip_end: 100, }], gamma=0.5)
  sampler.update([
    { bin: 0, discounted_return: 1.0, bootstrap: None, },
    { bin: 0, discounted_return: 3.0, bootstrap: None, },
  ])
  assert_true((sampler.snapshot().0[0] - 0.4).abs() < 1.0e-12)
  assert_eq(sampler.snapshot().2, [2])
  sampler.update([
    { bin: 0, discounted_return: 1.0, bootstrap: Some((2, 4.0, false)), },
  ])
  assert_true((sampler.snapshot().0[0] - 0.72).abs() < 1.0e-12)
}

///|
test "GAE timeout bootstraps but terminated transition does not" {
  let result = lambda_returns(
    [[1.0], [2.0]],
    [[10.0], [20.0], [30.0]],
    [[0.0], [1.0]],
    truncated=[[true], [false]],
    gamma=0.5,
    lam=0.95,
  )
  assert_eq(result, [[11.0], [2.0]])
}

///|
test "evaluation includes unplayed failed remainder in denominator" {
  let summary = summarize_evaluations([
    {
      clip_id: "failed",
      expected_steps: 10,
      rewards: [0.1, 0.1],
      terminated: true,
      strict_rmse: None,
      termination_frame: Some(2),
    },
    {
      clip_id: "complete",
      expected_steps: 2,
      rewards: [0.1, 0.1],
      terminated: false,
      strict_rmse: None,
      termination_frame: None,
    },
  ])
  assert_true((summary.norm_return - 0.6).abs() < 1.0e-12)
  assert_true((summary.norm_return_framew - 1.0 / 3.0).abs() < 1.0e-12)
  assert_true(summary.benchmark_complete)
}

///|
test "AD world target rotation matches scalar value and finite differences" {
  let t = @numeric.Tape::new()
  let angle = t.scalar(0.2)
  let rot = ad_axis(t, [0.0, 0.0, 1.0], angle)
  let loss = ad_square(t, ad_log(t, rot))
  t.backward(loss)
  assert_true((loss.value - 0.04).abs() < 1.0e-9)
  assert_true((t.gradient(angle) - 0.4).abs() < 1.0e-7)
}

///|
test "running norm checkpoint preserves variance and update count" {
  let norm = RunningNorm::new(2)
  norm.update([[1.0, 2.0], [3.0, 4.0]])
  let saved = norm.save()
  norm.update([[100.0, 100.0]])
  norm.load(saved)
  assert_eq(norm.snapshot().0, [2.0, 3.0])
  assert_eq(norm.snapshot().1, [1.0, 1.0])
  assert_eq(norm.snapshot().2, 2.0)
}

///|
test "native multi-step model and imagined actor critic updates with restartable state" {
  let kin = fixture_kin()
  let row = [0.0, 0.0, 0.76, 0.0, 0.0, 0.0, 1.0]
  row.append(default_joint_positions())
  let motion = MotionLibrary::new(
    [
      {
        name: "algorithm-fixture",
        sha256: "fixture",
        rows: Array::makei(7, _ => row.copy()),
      },
    ],
    kin,
    source_fps=50.0,
  )
  let defaults = LearnerConfig::default()
  let config = {
    ..defaults,
    wm_hidden: [4],
    policy_hidden: [4],
    critic_hidden: [4],
    hist: 2,
    goal_frames: 1,
    horizon: 1,
    wm_window: 2,
    wm_batches: 1,
    wm_batch: 1,
    policy_batch: 1,
    critic_epochs: 1,
    critic_minibatches: 1,
    observation_noise: false,
  }
  let learner = Learner::new(kin, motion, config~)
  let replay = ReplayBuffer::new(4, 1)
  for f in 0..<3 {
    let tr = fixture_transition(f, f)
    replay.add([tr])
    learner.observe(tr)
  }
  let fitted = learner.fit_world_model(replay)
  assert_eq(fitted.updates, 1)
  assert_true(finite(fitted.loss))
  let wm_before = learner.wm.net.parameters.copy()
  let updated = learner.update_policy(replay)
  assert_eq(updated.imagined_steps, 1)
  assert_eq(updated.critic_updates, 1)
  assert_true(finite(updated.policy_loss) && finite(updated.gradient_norm))
  assert_eq(wm_before, learner.wm.net.parameters)
  let saved = learner.snapshot()
  let json = saved.to_json()
  let copy : LearnerSnapshot = @json.from_json(json)
  learner.restore(copy)
  assert_eq(learner.snapshot().to_json(), json)
}
