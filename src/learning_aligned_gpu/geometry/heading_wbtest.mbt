///|
test "SMC projected heading has analytic values and derivatives at vertical axes" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP heading gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  for (x, y) in [(0.6, 0.8), (1.0e-7, -2.0e-7), (0.0, 0.0)] {
    let r = backend.from_values(
      [1, 3, 3],
      [x, -0.8, 0.0, y, 0.6, 0.0, 1.0, 0.0, 0.0],
      cuda_device=-1,
      requires_grad=true,
      dtype=Float64,
    )
    let projected = yaw_mat(backend, r, mode=SmcProjected)
    let n = (x * x + y * y + 1.0e-9).sqrt()
    let expected = [x / n, -y / n, 0.0, y / n, x / n, 0.0, 0.0, 0.0, 1.0]
    for i, actual in projected.values() {
      assert_true((actual - expected[i]).abs() < 1.0e-12)
    }
    // Weighted first-column loss c + 2s; covers the regularized vertical gradient.
    entry(projected, 0).add(entry(projected, 3).affine(2.0)).sum().backward()
    let dx = 1.0 / n - (x + 2.0 * y) * x / (n * n * n)
    let dy = 2.0 / n - (x + 2.0 * y) * y / (n * n * n)
    for i, actual in r.gradient().values() {
      let expected = if i == 0 { dx } else if i == 3 { dy } else { 0.0 }
      assert_true((actual - expected).abs() < 1.0e-8)
    }
    assert_eq(
      yaw_mat(backend, r).values(),
      yaw_mat(backend, r, mode=StableFallback).values(),
    )
  }
}
