///|
test "compact heading preserves strided values and first-order gradients near vertical" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    // Optional native plugin in ordinary development; admission scripts reject
    // every SKIP and require the actual test result with the pinned plugin.
    println("SKIP compact heading: tensor plugin not configured")
    return
  }
  let backend = @tensor.Backend::open(path)
  let device = if @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") ==
    Some("cuda:0") {
    0
  } else {
    -1
  }
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let entries = [
      (0.6, 0.8),
      (1.0e-7, -2.0e-7),
      (0.0, 0.0),
      (-1.0, 1.0e-9),
      (1.0e4, -1.0e4),
    ]
    let values : Array[Double] = []
    for (x, y) in entries {
      values.append([x, 0.2, 0.1, y, 0.3, 0.4, 0.5, 0.6, 0.7])
    }
    for strided in [false, true] {
      let make = () => {
        backend.from_values(
          [entries.length(), 3, 3],
          values,
          cuda_device=device,
          requires_grad=true,
          dtype~,
        )
      }
      let a = make()
      let b = make()
      let ra = if strided { a.transpose_dims(1, 2) } else { a }
      let rb = if strided { b.transpose_dims(1, 2) } else { b }
      let baseline = yaw_mat(backend, ra, mode=SmcProjected)
      let candidate = yaw_mat(backend, rb, mode=SmcProjected, compact=true)
      let weights = backend
        .from_values(
          [entries.length(), 3, 3],
          Array::makei(entries.length() * 9, i => (i % 13 - 6).to_double() * 0.3),
          cuda_device=device,
          requires_grad=false,
          dtype~,
        )
        .transpose_dims(1, 2)
      baseline.mul(weights).sum().backward()
      candidate.mul(weights).sum().backward()
      for
        (expected, actual) in [
          (baseline.values(), candidate.values()),
          (a.gradient_values(), b.gradient_values()),
        ] {
        for i in 0..<expected.length() {
          let limit = if dtype == @tensor.Float64 {
            1.0e-9 + 1.0e-10 * expected[i].abs()
          } else {
            2.0e-6 + 2.0e-4 * expected[i].abs()
          }
          assert_true(
            !actual[i].is_nan() &&
            !actual[i].is_inf() &&
            (actual[i] - expected[i]).abs() <= limit,
          )
        }
      }
      // Opt-in never changes the separately selected legacy heading convention.
      assert_eq(
        yaw_mat(backend, ra, compact=true).values(),
        yaw_mat(backend, ra).values(),
      )
    }
  }
}
