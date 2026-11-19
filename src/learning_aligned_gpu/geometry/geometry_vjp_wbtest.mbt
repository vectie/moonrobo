///|
test "SO3 coefficient forward and full derivative near branch boundaries" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP geometry tail")
    return
  }
  let backend = @tensor.Backend::open(path)
  assert_true(backend.has_geometry_vjp())
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let values = [
      0.0, 0.0, 0.0, 1.0e-6, -2.0e-6, 3.0e-6, 0.00009999, 0.0, 0.0, 0.00010001, 0.0,
      0.0, 0.04, -0.03, 0.02, 3.141592653589793, 0.0, 0.0,
    ]
    let a = backend.from_values(
      [6, 3],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let b = backend.from_values(
      [6, 3],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let left = so3_exp(backend, a, detached_constants=true, fused_skew=true)
    let right = so3_exp(
      backend,
      b,
      detached_constants=true,
      fused_skew=true,
      fused_so3_coefficients=true,
    )
    assert_eq(left.values(), right.values())
    let w = backend.from_values(
      [6, 3, 3],
      Array::makei(54, i => (i - 26).to_double() / 16.0),
      cuda_device=-1,
      requires_grad=false,
      dtype~,
    )
    left.mul(w).sum().backward()
    right.mul(w).sum().backward()
    let ag = a.gradient_values()
    let bg = b.gradient_values()
    for i in 0..<ag.length() {
      let tol = if dtype == @tensor.Float64 {
        1.0e-12
      } else {
        2.0e-6 + 2.0e-4 * ag[i].abs()
      }
      assert_true((ag[i] - bg[i]).abs() <= tol)
    }
  }
}

///|
test "fused cross preserves forward and existing VJP for strided inputs" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP geometry tail")
    return
  }
  let backend = @tensor.Backend::open(path)
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let inputs = Array::makei(48, i => (i - 23).to_double() / 13.0)
    let a = backend.from_values(
      [8, 6],
      inputs,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let b = backend.from_values(
      [8, 6],
      inputs,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let left = a.narrow(1, 0, 3).cross_preserve_forward(a.narrow(1, 3, 3))
    let right = b.narrow(1, 0, 3).fused_cross_vjp(b.narrow(1, 3, 3))
    assert_eq(left.values(), right.values())
    let w = backend.from_values(
      [8, 3],
      Array::makei(24, i => (i - 11).to_double() / 7.0),
      cuda_device=-1,
      requires_grad=false,
      dtype~,
    )
    left.mul(w).sum().backward()
    right.mul(w).sum().backward()
    assert_eq(a.gradient_values(), b.gradient_values())
  }
}
