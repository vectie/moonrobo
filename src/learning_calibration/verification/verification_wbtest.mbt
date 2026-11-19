///|
test "verification preserves zero-tolerance applied-action and previous-action checks" {
  assert_true(
    (try? checked_row([0.1], [0.1000000001], 0.0, 0.0, "action")) is Err(_),
  )
  assert_eq(checked_row([0.1], [0.1], 0.0, 0.0, "action"), 0.0)
  close(1.000005, 1.0, 0.00001, 0.000001, "reward")
  assert_true((try? close(1.00002, 1.0, 0.00001, 0.000001, "reward")) is Err(_))
}

///|
test "verification terminal finite-return targets have no bootstrap across a fall" {
  assert_eq(returns([1.0, 2.0], [1.0, 1.0], [false, true], 0.5, false), [
    2.0, 2.0,
  ])
  assert_eq(returns([1.0, 2.0], [1.0, 1.0], [false, true], 0.5, true), [
    2.0, 2.0,
  ])
  assert_eq(returns([1.0, 2.0], [1.0, 1.0], [true, false], 0.5, false), [
    1.0, 2.0,
  ])
}

///|
test "verification rejects nonfinite records before comparing or casting" {
  assert_true((try? finite_row([1.0 / 0.0], false)) is Err(_))
  assert_true((try? finite_row([1.0e300], true)) is Err(_))
  assert_true(
    (try? checked_row([1.0, 2.0], [1.0], 0.00001, 0.000001, "count")) is Err(_),
  )
}

///|
/// Source only: no verifier, model load or simulator is executed this session.
test "verification requires explicit model ancestry instead of skipping its identity gate" {
  assert_true((try? required_model_ref({ "config": {} })) is Err(_))
  assert_true((try? required_model_ref({ "model_ref": null })) is Err(_))
  let model : Json = "known-fixture-source"
  assert_eq(required_model_ref({ "model_ref": model }), model)
}

///|
test "verification discovers current native actors before preserved Torch companions" {
  let candidates = actor_candidates("/study/actor-seed-7")
  assert_eq(candidates[0], "/study/actor-seed-7.moon.json")
  assert_eq(candidates[1], "/study/actor-seed-7.pt")
}
