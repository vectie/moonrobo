///|
test "fused coordinate rotation exact finite forward and analytic derivative" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP fused rotation")
    return
  }
  let backend = @tensor.Backend::open(path)
  assert_true(backend.has_fused_rotation())
  for dtype in [@tensor.Float32, @tensor.Float64] {
    for axis in 0..<3 {
      for sign in [-1.0, 1.0] {
        let values = [0.0, 1.0e-8, -0.3, 1.7, 3.141592653589793, -8.0]
        let packed = Array::makei(12, i => {
          if i % 2 == 0 {
            values[i / 2]
          } else {
            17.0
          }
        })
        let a = backend.from_values(
          [6, 2],
          packed,
          cuda_device=-1,
          requires_grad=true,
          dtype~,
        )
        let b = backend.from_values(
          [6, 2],
          packed,
          cuda_device=-1,
          requires_grad=true,
          dtype~,
        )
        let axes = [0.0, 0.0, 0.0]
        axes[axis] = sign
        let left = axis_angle(backend, axes, a.narrow(1, 0, 1))
        let right = b.narrow(1, 0, 1).fused_axis_rotation(axis, sign)
        assert_eq(left.values(), right.values())
        let weights = backend.from_values(
          [6, 3, 3],
          Array::makei(54, i => (i - 23).to_double() / 17.0),
          cuda_device=-1,
          requires_grad=false,
          dtype~,
        )
        left.mul(weights).sum().backward()
        right.mul(weights).sum().backward()
        let ag = a.gradient_values()
        let bg = b.gradient_values()
        for i in 0..<ag.length() {
          let tol = if dtype == @tensor.Float64 {
            1.0e-12
          } else {
            2.0e-6 + 2.0e-4 * ag[i].abs()
          }
          assert_true((ag[i] - bg[i]).abs() <= tol)
          if i % 2 == 1 {
            assert_eq(bg[i], 0.0)
          }
        }
      }
    }
  }
  let a = backend.from_values([1, 1], [0.3], cuda_device=-1, requires_grad=true)
  let bad = try {
    ignore(a.fused_axis_rotation(3, 1.0))
    false
  } catch {
    _ => true
  }
  assert_true(bad)
}

///|
test "fused skew SO3 values and gradient across branch boundary" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP fused skew")
    return
  }
  let backend = @tensor.Backend::open(path)
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
    let left = so3_exp(backend, a, detached_constants=true)
    let right = so3_exp(backend, b, detached_constants=true, fused_skew=true)
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
