// These are input/schema/comparison tests only. They execute no GPU adapter and
// must never be used as the physical replay evidence produced by `run`.

///|
test "APIC fixed input tape covers all four roles and both isolation masks" {
  let tape = default_tape()
  tape.validate()
  let hash = @crypto.SHA256::new()
  hash.update(@utf8.encode(Json(tape).stringify(indent=2) + "\n"))
  assert_eq(
    @crypto.bytes_to_hex_string(hash.finalize()),
    "cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860",
  )
  assert_eq(tape.operations.length(), 20)
  assert_eq(tape.operations.filter(op => op.kind == "step").length(), 8)
  let decoded : Tape = @json.from_json(@json.parse(Json(tape).stringify()))
  decoded.validate()
  for op in tape.operations {
    for raw in op.states71 {
      let roundtrip = @aligned.flatten_state(@aligned.unflatten_state(raw))
      for i in 0..<71 {
        assert_true((raw[i] - roundtrip[i]).abs() < 1.0e-12)
      }
    }
  }
  let bad = default_tape()
  bad.operations[0] = { ..bad.operations[0], ids: [1, 1], }
  assert_true((try? bad.validate()) is Err(_))
  let bad_quaternion = default_tape()
  bad_quaternion.operations[1].states71[0][3] = 0.0
  assert_true((try? bad_quaternion.validate()) is Err(_))
}

///|
test "selected APIC tape bounds and exact first middle last world contract" {
  for count in [4, 8, 128] {
    let tape = selected_tape(count)
    tape.validate()
    assert_true(
      @utf8.encode(Json(tape).stringify(indent=2) + "\n").length() <= 4194304,
    )
    assert_eq(tape.operations.length(), 27)
    assert_eq(tape.operations.filter(op => op.kind == "step").length(), 8)
    assert_eq(tape.worlds(), [0, count / 2, count - 1])
    let decoded : Tape = @json.from_json(@json.parse(Json(tape).stringify()))
    decoded.validate()
    @gpu.validate_audit_worlds(count, tape.worlds())
    let bad_selection = {
      ..tape,
      selected_worlds: Some([0, count - 1, count / 2]),
    }
    assert_true((try? bad_selection.validate()) is Err(_))
  }
  assert_true((try? selected_tape(129)) is Err(_))
  assert_true((try? selected_tape(3)) is Err(_))
  assert_true((try? @gpu.validate_audit_worlds(129, [0, 64, 128])) is Err(_))
  assert_true((try? @gpu.validate_audit_worlds(8, [0, 4, 8])) is Err(_))
  assert_true((try? @gpu.validate_audit_worlds(8, [0, 4, 4])) is Err(_))
  assert_true((try? @gpu.validate_audit_worlds(8, [0, 1, 4, 7])) is Err(_))
  let bad = selected_tape(8)
  bad.operations[0] = { ..bad.operations[0], ids: [0, 0, 2, 3, 4, 5, 6, 7], }
  assert_true((try? bad.validate()) is Err(_))
  let missing = selected_tape(4)
  missing.operations[13] = operation("missing-middle-context", "refresh")
  assert_true((try? missing.validate()) is Err(_))
}

///|
fn selected_fixture() -> @gpu.AuditReadback {
  {
    state71: [
      input_state(0, false),
      input_state(2, false),
      input_state(3, false),
    ],
    root_pose: Array::makei(3, i => Array::make(7, i.to_double())),
    root_com_velocity: Array::makei(3, _ => Array::make(6, 0.0)),
    root_com_local: Array::makei(3, _ => Array::make(3, 0.0)),
    joint_position: Array::makei(3, _ => @aligned.default_joint_positions()),
    joint_velocity: Array::makei(3, _ => Array::make(29, 0.0)),
    shape_friction: [[0.6], [0.6], [0.6]],
    torso_com: Array::makei(3, _ => Array::make(3, 0.0)),
    ground_friction: [0.3],
  }
}

///|
test "selected rows keep real world labels and detect masked world corruption" {
  let before = selected_fixture()
  let after = selected_fixture()
  let worlds = [0, 2, 3]
  let base = Array::makei(3, _ => Array::make(3, 0.0))
  let op = operation("reset-world3", "reset", ids=[3], states71=[
    input_state(3, true),
  ])
  after.state71[2] = input_state(3, true)
  let checks : Array[Check] = []
  check_operation(checks, op, before, after, base, worlds~)
  assert_true(checks.all(check => check.passed))
  assert_true(checks.any(check => check.name == "reset-state/3"))
  after.joint_velocity[1][6] = 0.000001
  let failed : Array[Check] = []
  check_operation(failed, op, before, after, base, worlds~)
  assert_true(
    failed.any(check => {
      check.name == "masked-world/2/joint_velocity" && !check.passed
    }),
  )
  let comparisons : Array[Check] = []
  compare_snapshot(comparisons, "oracle", "sdk/", after, before, 0.0, worlds~)
  assert_true(
    comparisons.any(check => {
      check.name == "sdk/joint_velocity/2" && !check.passed
    }),
  )
  assert_true((try? validate_readback(after, 2)) is Err(_))
  validate_readback(after, 3)
}

///|
test "selected context checks affected and isolated actual world IDs" {
  let before = selected_fixture()
  let after = selected_fixture()
  let row = Array::make(33, 0.0)
  row[0] = 0.9
  row[30] = 0.01
  row[31] = -0.02
  row[32] = 0.015
  after.shape_friction[1] = [0.9]
  after.torso_com[1] = [0.01, -0.02, 0.015]
  let op = operation("context-world2", "context", ids=[2], context=[row])
  let base = Array::makei(3, _ => Array::make(3, 0.0))
  let checks : Array[Check] = []
  check_operation(checks, op, before, after, base, worlds=[0, 2, 3])
  assert_true(checks.all(check => check.passed))
  assert_true(checks.any(check => check.name == "context-write/com/2"))
  after.shape_friction[2][0] = 0.9
  let failed : Array[Check] = []
  check_operation(failed, op, before, after, base, worlds=[0, 2, 3])
  assert_true(
    failed.any(check => {
      check.name == "context-isolation/friction/3" && !check.passed
    }),
  )
}

///|
test "APIC comparator never hides failed components behind a larger tolerance" {
  let checks : Array[Check] = []
  compare_values(
    checks,
    "op",
    "oracle",
    [1000.0, 0.001],
    [1000.0, 0.0],
    1.0e-5,
    rtol=1.0e-5,
  )
  assert_true(!checks[0].passed)
  assert_eq(checks[0].max_abs_error, 0.001)
  compare_values(checks, "op", "exact", [1.0], [1.0], 0.0)
  assert_true(checks[1].passed)
  assert_true(
    (try? compare_values(checks, "op", "shape", [1.0], [], 0.0)) is Err(_),
  )
}
