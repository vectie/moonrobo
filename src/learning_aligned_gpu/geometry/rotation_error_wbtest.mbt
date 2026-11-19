///|
test "SMC trace acos matches analytic values and clamp gradients including nonorthogonal inputs" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP rotation error gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  // Identity, generic rotation, pi, and nonorthogonal imagined state.
  let cases = [
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [0.6, -0.8, 0.0, 0.8, 0.6, 0.0, 0.0, 0.0, 1.0],
    [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0],
    [0.2, 0.1, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
  ]
  let identity = backend.from_values(
    [1, 3, 3],
    cases[0],
    dtype=Float64,
    cuda_device=-1,
    requires_grad=false,
  )
  for values in cases {
    let a = backend.from_values(
      [1, 3, 3],
      values,
      requires_grad=true,
      dtype=Float64,
      cuda_device=-1,
    )
    let out = angle_square(backend, a, identity, mode=TraceAcos)
    let raw = (values[0] + values[4] + values[8] - 1.0) / 2.0
    let c = raw.max(-1.0 + 1.0e-6).min(1.0 - 1.0e-6)
    let angle = @math.acos(c)
    assert_true((out.values()[0] - angle * angle).abs() < 1.0e-12)
    out.sum().backward()
    let gradient = a.gradient().values()
    let d = if raw != c { 0.0 } else { -angle / (1.0 - c * c).sqrt() }
    for i, actual in gradient {
      let expected = if i == 0 || i == 4 || i == 8 { d } else { 0.0 }
      assert_true((actual - expected).abs() < 1.0e-10)
    }
  }
}
