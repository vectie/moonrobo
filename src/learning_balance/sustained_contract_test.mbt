///|
/// Port of test_sustained_balance.py: planted independent pose/rate law and pre-damping waist coupling, with censored labels and an intentionally under-specified baseline.
test "pose rate fit recovers ankle law and waist coupling and beats reduced representation" {
  let names = [
    "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
    "right_ankle_roll_joint", "waist_pitch_joint",
  ]
  let rng = @numeric.Rng::new(23U)
  let n = 4000
  let nu = names.length()
  let observations : Array[Array[Double]] = []
  let features : Array[Array[Double]] = []
  let goals : Array[Array[Double]] = []
  let targets : Array[Array[Double]] = []
  for _ in 0..<n {
    let obs = Array::make(3 * nu + 6, 0.0)
    for j in 0..<nu {
      obs[nu + j] = 0.4 * rng.normal()
    }
    let pitch = 0.08 * rng.normal()
    let roll = 0.08 * rng.normal()
    obs[2 * nu] = @math.sin(pitch)
    obs[2 * nu + 1] = -@math.sin(roll) * @math.cos(pitch)
    obs[2 * nu + 2] = -@math.cos(roll) * @math.cos(pitch)
    for j in 0..<3 {
      obs[2 * nu + 3 + j] = 0.2 * rng.normal()
    }
    let feature = Array::makei(6, fn(_) { 0.015 * rng.normal() })
    let goal = Array::makei(nu, fn(_) { 0.05 * rng.normal() })
    let p = 16.0 * feature[0] +
      32.0 * feature[3] +
      pitch +
      0.25 * obs[2 * nu + 4] +
      0.2
    let r = -16.0 * feature[1] -
      32.0 * feature[4] +
      roll +
      0.25 * obs[2 * nu + 3]
    let y = Array::makei(4, fn(j) {
      let residual = (if j % 2 == 0 { p } else { r }) - 0.02 * obs[nu + j]
      clip(goal[j] + clip(residual, -0.45, 0.45), -0.8, 0.8)
    })
    let waist = -0.25 * clip(p, -0.45, 0.45) - 0.02 * obs[nu + 4]
    y.push(clip(goal[4] + clip(waist, -0.45, 0.45), -0.8, 0.8))
    observations.push(obs)
    features.push(feature)
    goals.push(goal)
    targets.push(y)
  }
  let head = SustainedBalanceHead::new(
    names,
    Array::make(nu, -0.8),
    Array::make(nu, 0.8),
  )
  let (reports, waist) = head.fit(observations, goals, targets, features)
  let planted = [
    [16.0, 32.0, -0.02, 1.0, 0.25, 0.2],
    [-16.0, -32.0, -0.02, 1.0, 0.25, 0.0],
    [16.0, 32.0, -0.02, 1.0, 0.25, 0.2],
    [-16.0, -32.0, -0.02, 1.0, 0.25, 0.0],
  ]
  for j, report in reports {
    for k in 0..<6 {
      assert_true((report.raw_coefficients[k] - planted[j][k]).abs() < 2.0e-4)
    }
  }
  for j, expected in [-0.25, -0.02, 0.0] {
    assert_true((waist.raw_coefficients[j] - expected).abs() < 2.0e-6)
  }
  let reduced = SustainedBalanceHead::new(
    names,
    Array::make(nu, -0.8),
    Array::make(nu, 0.8),
    pose_rate=false,
  )
  ignore(reduced.fit(observations, goals, targets, features))
  let mut reduced_error = 0.0
  for i in 0..<n {
    let actual = head.predict(observations[i], goals[i], features[i])
    let simpler = reduced.predict(observations[i], goals[i], features[i])
    for j in 0..<nu {
      assert_true((actual[j] - targets[i][j]).abs() < 3.0e-6)
      let d = simpler[j] - targets[i][j]
      reduced_error += d * d / (n * nu).to_double()
    }
  }
  assert_true(reduced_error > 1.0e-4)
}
