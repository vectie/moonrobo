///|
/// Port of test_learned_balance.py. The planted law is independent of the implementation, and both residual and actuator censoring are present.
test "uncensored OLS recovers planted law without treating saturated labels as residuals" {
  let names = [
    "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
    "right_ankle_roll_joint",
  ]
  let head = LearnedAnkleHead::new(
    names,
    Array::make(4, -0.4),
    Array::make(4, 0.4),
  )
  let rng = @numeric.Rng::new(17U)
  let x = Array::makei(2000, fn(_) {
    Array::makei(4, fn(_) { Array::makei(3, fn(_) { rng.normal() }) })
  })
  let planted = [
    [0.12, -0.09, 0.04, 0.1],
    [-0.08, 0.2, -0.05, -0.03],
    [0.04, -0.06, 0.13, 0.02],
    [0.19, 0.08, -0.07, -0.12],
  ]
  let goals = Array::makei(2000, fn(_) {
    Array::makei(4, fn(_) { 0.15 * rng.normal() })
  })
  let targets = Array::makei(2000, fn(i) {
    Array::makei(4, fn(j) {
      let y = planted[j][3] +
        x[i][j][0] * planted[j][0] +
        x[i][j][1] * planted[j][1] +
        x[i][j][2] * planted[j][2]
      clip(goals[i][j] + clip(y, -0.3, 0.3), -0.4, 0.4)
    })
  })
  let reports = head.fit(x, goals, targets)
  for j, report in reports {
    assert_true(
      report.uncensored_points > 4 && report.uncensored_points < x.length(),
    )
    for k in 0..<4 {
      assert_true((report.raw_coefficients[k] - planted[j][k]).abs() < 2.0e-7)
    }
  }
  for i in 0..<x.length() {
    let residual = head.residual(x[i])
    for j in 0..<4 {
      assert_true(
        (clip(goals[i][j] + clip(residual[j], -0.3, 0.3), -0.4, 0.4) -
        targets[i][j]).abs() <
        2.0e-7,
      )
    }
  }
}
