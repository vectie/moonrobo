///|
/// Port of test_balance_intervention.py's pure action and finite-memory contracts. The actual native WindowTeacher is exercised separately in intervention/native_contract_test.mbt.
test "channel substitutions change only declared groups and preserve sources" {
  let names = [
    "left_hip_pitch_joint", "left_ankle_pitch_joint", "right_ankle_pitch_joint",
    "left_ankle_roll_joint", "right_ankle_roll_joint", "waist_pitch_joint", "left_shoulder_pitch_joint",
  ]
  let groups = joint_groups(names)
  assert_eq(groups["ankle"], [1, 2, 3, 4])
  assert_eq(groups["ankle_waist"], [1, 2, 3, 4, 5])
  assert_eq(groups["lower"], [0, 1, 2, 3, 4])
  let student = Array::makei(7, fn(i) { i.to_double() })
  let teacher = Array::makei(7, fn(i) { i.to_double() + 10.0 })
  let action = blend_actions(student, teacher, groups["ankle_waist"])
  for i in groups["ankle_waist"] {
    assert_eq(action[i], teacher[i])
  }
  assert_eq(action[0], student[0])
  assert_eq(action[6], student[6])
  assert_eq(student, Array::makei(7, fn(i) { i.to_double() }))
  assert_eq(teacher, Array::makei(7, fn(i) { i.to_double() + 10.0 }))
}

///|
test "N frames include precisely N minus one finite differences" {
  let errors = Array::makei(35, fn(i) {
    [0.0001 * i.to_double() * i.to_double(), 0.0, 0.0]
  })
  let transforms = Array::makei(errors.length(), fn(_) { identity() })
  let full = causal_velocity(errors, transforms, 0.02, None)
  let long = causal_velocity(errors, transforms, 0.02, Some(50))
  let short = causal_velocity(errors, transforms, 0.02, Some(10))
  let zero = causal_velocity(errors, transforms, 0.02, Some(1))
  for i in 0..<errors.length() {
    assert_true((long[i][0] - full[i][0]).abs() < 1.0e-14)
    let mut expected = 0.0
    let first = (i - 9).max(0)
    for j in (first + 1)..<=i {
      expected = 0.8 * expected + 0.2 * (errors[j][0] - errors[j - 1][0]) / 0.02
    }
    assert_true((short[i][0] - expected).abs() < 1.0e-14)
    assert_eq(zero[i], [0.0, 0.0, 0.0])
  }
  assert_true((short[34][0] - full[34][0]).abs() > 1.0e-4)
}
