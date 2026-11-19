///|
test "reverse tape differentiates shared branches and resets accumulated gradients" {
  let tape = @numeric.Tape::new()
  let x = tape.scalar(0.4)
  let y = tape.add(tape.mul(x, x), tape.sin(x))
  tape.backward(y)
  assert_true(
    (tape.gradient(x) - (0.8 + @math.cos(0.4))).abs() < 0.000000000001,
  )
  tape.backward(y)
  assert_true(
    (tape.gradient(x) - (0.8 + @math.cos(0.4))).abs() < 0.000000000001,
  )
}

///|
test "disconnected singular branches do not pollute gradients" {
  let tape = @numeric.Tape::new()
  let x = tape.scalar(2)
  ignore(tape.sqrt(tape.scalar(0)))
  ignore(tape.acos(tape.scalar(1)))
  let y = tape.mul(x, x)
  tape.backward(y)
  assert_eq(tape.gradient(x), 4)
}

///|
test "atan2 gradient and population normalization" {
  let tape = @numeric.Tape::new()
  let y = tape.scalar(3)
  let x = tape.scalar(4)
  tape.backward(tape.atan2(y, x))
  assert_true((tape.gradient(y) - 0.16).abs() < 0.000000000001)
  assert_true((tape.gradient(x) + 0.12).abs() < 0.000000000001)
  let stats = @numeric.fit_normalization([[1.0, 5.0], [3.0, 5.0]], 0.1)
  assert_eq(stats.mean, [2.0, 5.0])
  assert_eq(stats.scale, [1.0, 0.1])
}

///|
test "Adam first update and independently retained optimizer snapshot" {
  let parameters = [2.0]
  let adam = @numeric.Adam::new(1, 0.01)
  let tape = @numeric.Tape::new()
  let bound = tape.vector(parameters)
  tape.backward(tape.mul(bound[0], bound[0]))
  ignore(adam.step(parameters, tape, bound, max_norm=100))
  assert_true((parameters[0] - 1.990000000025).abs() < 0.000000000001)
  let saved = adam.snapshot()
  adam.set_learning_rate(0.02)
  adam.restore(saved)
  assert_eq(adam.steps, 1)
  assert_eq(adam.learning_rate, 0.01)
}
