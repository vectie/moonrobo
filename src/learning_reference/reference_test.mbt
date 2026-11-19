///|
test "finite returns and GAE never bootstrap across reset" {
  assert_eq(@learning_reference.finite_returns([1.0, 2.0], 0.5), [2.0, 2.0])
  let advantage = @learning_reference.ppo_advantages(
    [1.0, 2.0, 3.0],
    [false, true, true],
    [0.0, 0.0, 0.0],
    0.5,
    1.0,
  )
  let scale = (2.0 / 9.0).sqrt()
  assert_true((advantage[0] - 2.0 / scale).abs() < 1.0e-12)
  assert_true((advantage[1] - 2.0 / scale).abs() < 1.0e-12)
  assert_true((advantage[2] - 3.0 / scale).abs() < 1.0e-12)
}

///|
test "reference preview clamps at final frame and marks padding" {
  let command = @learning_reference.reference_command(
    [[0.0], [1.0], [2.0]],
    1,
    3,
  )
  assert_eq(command.current, [1.0])
  assert_eq(command.future, [[2.0], [2.0], [2.0]])
  assert_eq(command.valid, [true, false, false])
  assert_eq(@learning_reference.window_starts(10, 4), [0, 2, 4, 6])
  assert_eq(@learning_reference.window_starts(11, 4), [0, 2, 4, 6, 7])
}

///|
test "causal history replicates first frame and retains only recent frames" {
  let history = @learning_reference.ReferenceHistory::new(3)
  assert_eq(history.push([1.0]), [[1.0], [1.0], [1.0]])
  assert_eq(history.push([2.0]), [[1.0], [1.0], [2.0]])
  assert_eq(history.push([3.0]), [[1.0], [2.0], [3.0]])
}

///|
test "reference observation excludes prior controls and quaternion" {
  let goal = Array::makei(68, i => i.to_double())
  let obs = @learning_reference.reference_observation(goal)
  assert_eq(obs.length(), 93)
  assert_eq(obs[58:64].to_owned(), [58.0, 59.0, 60.0, 65.0, 66.0, 67.0])
  assert_eq(obs[64:].to_owned(), Array::make(29, 0.0))
}

///|
test "first action perturbation preserves tape and clips bounds" {
  let tape = [[0.0, 0.5], [0.1, 0.2]]
  let result = @learning_reference.first_action_tape(
    tape,
    [1.0, 1.0],
    1.0,
    [-0.5, -0.5],
    [0.5, 0.5],
  )
  assert_eq(result, [[0.5, 0.5], [0.1, 0.2]])
  assert_eq(tape, [[0.0, 0.5], [0.1, 0.2]])
}

///|
test "relative feedback has zero common feature response" {
  let nu = 4
  let current = Array::make(18, 0.0)
  current[10] = -1.0
  let obs = @learning_reference.reference_observation(current, nu~)
  let actor : @learning_reference.ReferenceActor = {
    nu,
    history_length: 1,
    future_length: 0,
    output_bound: 0.6,
    indices: [0, 1, 2, 3],
    obs_mean: Array::make(18, 0.0),
    obs_scale: Array::make(18, 1.0),
    goal_mean: Array::make(18, 0.0),
    goal_scale: Array::make(18, 1.0),
    lower: Array::make(4, -1.0),
    upper: Array::make(4, 1.0),
    feedback_coefficients: [
      [16.0, 32.0, -0.02, 1.0, 0.25],
      [-16.0, -32.0, -0.02, 1.0, 0.25],
      [16.0, 32.0, -0.02, 1.0, 0.25],
      [-16.0, -32.0, -0.02, 1.0, 0.25],
    ],
    goal_encoder: [],
    observation_encoder: [],
    decoder: [],
  }
  let zero = Array::make(6, 0.0)
  assert_eq(
    actor.action_from_latent([0.0, 0.0, 0.0, 0.0], [obs], current, zero, zero),
    [0.0, 0.0, 0.0, 0.0],
  )
  let action = actor.action_from_latent(
    [0.0, 0.0, 0.0, 0.0],
    [obs],
    current,
    [0.001, 0.0, 0.0, 0.0, 0.0, 0.0],
    zero,
  )
  assert_true((action[0] - 0.016).abs() < 1.0e-12)
  assert_eq(action[1], 0.0)
  assert_true((action[2] - 0.016).abs() < 1.0e-12)
  assert_eq(action[3], 0.0)
}

///|
test "observer EMA remains episode-local across model steps" {
  let obs = Array::make(93, 0.0)
  obs[60] = -1.0
  let first = [0.01, 0.0, 0.0, 0.0, 0.0, 0.0]
  let memory = @learning_reference.observer_memory(obs, first)
  let (next, carried) = @learning_reference.observer_advance(
    obs,
    memory,
    0.02,
    [0.02, 0.0, 0.0],
  )
  assert_true((next[3] - 0.1).abs() < 1.0e-12)
  let (third, _) = @learning_reference.observer_advance(obs, carried, 0.02, [
    0.02, 0.0, 0.0,
  ])
  assert_true((third[3] - 0.08).abs() < 1.0e-12)
}

///|
test "calibration reaches prescribed raw mean RMS" {
  let (amount, achieved, iterations) = @learning_reference.calibrate_direction(
    [0.0],
    [1.0],
    0.1,
    -1.0,
    2.0,
    x => [2.0 * x[0]],
  )
  assert_true((amount + 0.05).abs() < 1.0e-12)
  assert_true((achieved - 0.1).abs() < 1.0e-12)
  assert_eq(iterations, 1)
}

///|
test "model replay windows retain reset boundaries and initial anchor" {
  let episode = (offset : Double) => {
    (
      {
        state: Array::makei(6, i => [offset + i.to_double()]),
        action: Array::makei(6, _ => [0.0]),
        next_state: Array::makei(6, i => [offset + i.to_double() + 1.0]),
        context: [1.0, 1.0],
      } : @learning_reference.LearningEpisode)
  }
  let replay = @learning_reference.ReferenceModelReplay::new(
    9,
    4,
    anchor_after=3,
  )
  for offset in [0.0, 100.0, 200.0, 300.0] {
    replay.append([episode(offset)])
  }
  assert_eq(replay.windows().map(window => window.state[0][0]), [
    0.0, 1.0, 2.0, 200.0, 201.0, 202.0, 300.0, 301.0, 302.0,
  ])
  assert_eq(replay.anchor_count(), 3)
  for window in replay.windows() {
    assert_eq(window.state[3][0] - window.state[0][0], 3.0)
  }
}

///|
test "prediction metrics include last window and declared joint units" {
  let state = Array::makei(260, _ => {
    let s = Array::make(71, 0.0)
    s[3] = 1.0
    s
  })
  let actions = Array::makei(260, _ => Array::make(29, 0.0))
  let predict = (s : Array[Double], _a : Array[Double], _c : Array[Double]) => {
    let result = s.copy()
    result[7] += 1.0
    result
  }
  let result = @learning_reference.prediction_metrics(
      state,
      actions,
      state,
      [1.0, 1.0],
      Array::make(71, 1.0),
      [2],
      predict,
    )[0]
  assert_eq(result.windows, 259)
  assert_eq(result.last_window_offset, Some(258))
  assert_true(
    (result.normalized_state_mse.unwrap() - 2.5 / 71.0).abs() < 1.0e-12,
  )
  assert_true(
    (result.joint_rmse_rad.unwrap() - (2.5 / 29.0).sqrt()).abs() < 1.0e-12,
  )
  assert_eq(result.persistence_mse, Some(0.0))
  assert_eq(result.root_orientation_rmse_rad, Some(0.0))
}
