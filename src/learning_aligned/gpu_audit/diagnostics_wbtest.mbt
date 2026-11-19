///|
test "diagnostic exact controls catch stale values and mask only unused reset rows" {
  let tape = default_tape()
  let step = tape.operations.filter(op => op.kind == "step")[0]
  let target = Array::makei(2, _ => Array::make(29, 1.0))
  let stale = Array::makei(2, _ => Array::make(29, 1.0))
  stale[1][6] = 1.000001
  let checks : Array[Check] = []
  compare_diagnostic_inputs(
    checks,
    step,
    { "inputs": { "targets": Json(stale) } },
    { "inputs": { "targets": Json(target) } },
  )
  assert_true(checks.any(c => !c.passed))
  let reset = tape.operations.filter(op => op.kind == "reset" && op.ids == [0])[0]
  let left : Map[String, Json] = Map([])
  let right : Map[String, Json] = Map([])
  for
    (name, width) in [
      ("reset_pose", 7),
      ("reset_velocity", 6),
      ("reset_joint_position", 29),
      ("reset_joint_velocity", 29),
    ] {
    left[name] = Json([Array::make(width, 1.0), Array::make(width, 99.0)])
    right[name] = Json([Array::make(width, 1.0), Array::make(width, 0.0)])
  }
  left["reset_mask"] = [[1.0], [0.0]]
  right["reset_mask"] = [[1.0], [0.0]]
  let reset_checks : Array[Check] = []
  compare_diagnostic_inputs(reset_checks, reset, { "inputs": Json(left) }, {
    "inputs": Json(right),
  })
  assert_true(reset_checks.all(c => c.passed))
  left["reset_mask"] = [[0.0], [1.0]]
  compare_diagnostic_inputs(reset_checks, reset, { "inputs": Json(left) }, {
    "inputs": Json(right),
  })
  assert_true(reset_checks.any(c => !c.passed))
}
