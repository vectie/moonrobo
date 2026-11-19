///|
test "SO3 constants keep forward and VJP at zero small and general rotations" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP detached rotation constants")
    return
  }
  let backend = @tensor.Backend::open(path)
  let values = [
    0.0, 0.0, 0.0, 1.0e-6, -2.0e-6, 3.0e-6, 0.04, -0.03, 0.02, 3.141592653589793,
    0.0, 0.0,
  ]
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let a = backend.from_values(
      [4, 3],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let b = backend.from_values(
      [4, 3],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let left = @geometry.so3_exp(backend, a)
    let right = @geometry.so3_exp(backend, b, detached_constants=true)
    assert_eq(left.values(), right.values())
    let weights = backend.from_values(
      [4, 3, 3],
      Array::makei(36, i => (i - 17).to_double() / 16.0),
      cuda_device=-1,
      requires_grad=false,
      dtype~,
    )
    left.mul(weights).sum().backward()
    right.mul(weights).sum().backward()
    let ag = a.gradient_values()
    let bg = b.gradient_values()
    for i in 0..<ag.length() {
      let tolerance = if dtype == @tensor.Float64 {
        1.0e-12
      } else {
        2.0e-6 + 2.0e-4 * ag[i].abs()
      }
      assert_true((ag[i] - bg[i]).abs() <= tolerance)
    }
  }
}
