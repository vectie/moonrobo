///|
test "E1 profiles separate physical joints from embedded channels" {
  let a = @learning_e1_training.profile()
  let b = @learning_e1_training.profile(joints=24)
  assert_eq(a.joints.length(), 23)
  assert_eq(b.joints.length(), 24)
  assert_false(a.joints.contains("waist_roll_joint"))
  assert_true(b.joints.contains("waist_roll_joint"))
  let action = a.project(Array::make(29, 2.0))
  assert_eq(action[:23].to_owned(), Array::make(23, 2.0))
  assert_eq(action[23:].to_owned(), Array::make(6, 0.0))
  assert_true((Some(a.embed(Array::make(24, 0.0))) catch { _ => None }) is None)
  assert_true(
    (Some(@learning_e1_training.profile(joints=25)) catch { _ => None }) is None,
  )
  for p in [a, b] {
    for i in 0..<p.joints.length() {
      assert_true(p.stiffness[i] > 0.0 && p.damping[i] > 0.0)
      assert_true(
        (p.scales[i] * p.stiffness[i] - 0.25 * p.effort[i]).abs() < 1.0e-12,
      )
    }
  }
}

///|
test "E1 configuration rejects unsupported dimensions" {
  @learning_e1_training.Config::smoke().validate()
  @learning_e1_training.Config::training().validate()
  @learning_e1_training.Config::method_gate().validate()
  let c = @learning_e1_training.Config::smoke()
  assert_true(
    (Some({ ..c, learner: { ..c.learner, hist: 5, }, }.validate()) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some({ ..c, environments: 100000, }.validate()) catch { _ => None })
    is None,
  )
}

///|
test "E1 frozen actor inputs preserve default pose feature scaling and dummy zeros" {
  let robot = @learning_e1_training.profile()
  let obs = robot.observation(
    robot.default_q,
    Array::make(23, 2.0),
    Array::make(23, 0.5),
    [4.0, 8.0, 12.0],
    [0.0, 0.0, -1.0],
    [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
  )
  assert_eq(obs.length(), 99)
  assert_eq(obs[:29].to_owned(), Array::make(29, 0.0))
  assert_eq(obs[29], 2.0)
  assert_eq(obs[52:58].to_owned(), Array::make(6, 0.0))
  assert_eq(obs[58:61].to_owned(), [4.0, 8.0, 12.0])
  assert_eq(obs[87:93].to_owned(), Array::make(6, 0.0))
  let identity = @aligned.identity()
  let sensed : @aligned.State = {
    p: [0.0, 0.0, 0.8],
    rotation: identity,
    v: [0.0, 0.0, 0.0],
    w: [4.0, 8.0, 12.0],
    q: robot.embed(robot.default_q),
    qd: robot.embed(Array::make(23, 2.0)),
  }
  assert_eq(
    obs,
    @aligned.observation(
      sensed,
      robot.embed(Array::make(23, 0.5)),
      Array::make(30, 0.0),
      sensed.q,
      sensed,
      Smc,
    ),
  )
}
