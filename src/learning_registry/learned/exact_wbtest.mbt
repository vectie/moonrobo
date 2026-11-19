///|
fn fixture_head() -> @balance.LearnedAnkleHead {
  @balance.LearnedAnkleHead::new(
    [
      "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
      "right_ankle_roll_joint",
    ],
    [-1.0, -1.0, -1.0, -1.0],
    [1.0, 1.0, 1.0, 1.0],
  )
}

///|
test "registry exact-refit gate rejects even tiny parameter changes" {
  let expected = fixture_head()
  let actual = fixture_head()
  assert_exact_head(expected, actual)
  actual.weight[0][0] = 1.0e-15
  assert_true((try? assert_exact_head(expected, actual)) is Err(_))
}

///|
test "registry exact-refit gate checks normalization and bounds as well as coefficients" {
  let expected = fixture_head()
  let changed = fixture_head()
  changed.scale[0][0] = 1.000000000000001
  assert_true((try? assert_exact_head(expected, changed)) is Err(_))
  let changed = fixture_head()
  changed.lower[0] = -0.9
  assert_true((try? assert_exact_head(expected, changed)) is Err(_))
}

///|
test "native teacher provenance takes its actual source without rewriting legacy SHA identity" {
  let teacher : Json = {
    "provider_source": "src/learning_balance/physics/teacher.mbt",
    "source_language": "moonbit",
  }
  assert_eq(
    teacher_source(teacher, { "teacher_provider_source": "old.py" }, ""),
    "src/learning_balance/physics/teacher.mbt",
  )
  assert_eq(
    teacher_source(
      {},
      { "teacher_provider_source": "retained/balance_teacher.py" },
      "",
    ),
    "retained/balance_teacher.py",
  )
  assert_eq(
    teacher_source(teacher, {}, "snapshots/teacher.mbt"),
    "snapshots/teacher.mbt",
  )
  assert_true(
    (try? teacher_source(
      { "source_language": "moonbit" },
      { "teacher_provider_source": "old.py" },
      "",
    ))
    is Err(_),
  )
}
