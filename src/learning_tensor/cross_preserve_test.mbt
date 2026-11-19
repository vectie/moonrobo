///|
fn cross_preserve_expected3(
  a : Array[Double],
  b : Array[Double],
) -> Array[Double] {
  [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ]
}

///|
test "forward preserving cross strided inputs and both analytical input gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP native cross")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_cross_preserve_forward())
  for dtype in [@learning_tensor.Float32, @learning_tensor.Float64] {
    let av = [1.0, -2.0, 3.5, -4.0, 2.5, 1.0]
    let bv = [2.0, 1.0, -3.0, -2.0, 4.0, 3.5]
    let gv = [0.5, -1.0, 2.0, 3.0, -0.5, 1.0]
    let x = backend.from_values(
      [2, 6],
      [..av[:3], 9.0, 9.0, 9.0, ..av[3:], 9.0, 9.0, 9.0],
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let y = backend.from_values(
      [2, 6],
      [..bv[:3], 8.0, 8.0, 8.0, ..bv[3:], 8.0, 8.0, 8.0],
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let g = backend.from_values(
      [2, 3],
      gv,
      cuda_device=-1,
      requires_grad=false,
      dtype~,
    )
    let z = x.narrow(1, 0, 3).cross_preserve_forward(y.narrow(1, 0, 3))
    let expected = [
      ..cross_preserve_expected3(av[:3].to_owned(), bv[:3].to_owned()),
      ..cross_preserve_expected3(av[3:].to_owned(), bv[3:].to_owned()),
    ]
    assert_eq(z.values(), expected)
    z.mul(g).sum().backward()
    let dx = x.gradient_values()
    let dy = y.gradient_values()
    for r in 0..<2 {
      let ga = cross_preserve_expected3(
        bv[r * 3:r * 3 + 3].to_owned(),
        gv[r * 3:r * 3 + 3].to_owned(),
      )
      let gb = cross_preserve_expected3(
        gv[r * 3:r * 3 + 3].to_owned(),
        av[r * 3:r * 3 + 3].to_owned(),
      )
      for j in 0..<6 {
        assert_eq(dx[r * 6 + j], if j < 3 { ga[j] } else { 0.0 })
        assert_eq(dy[r * 6 + j], if j < 3 { gb[j] } else { 0.0 })
      }
    }
    try x.cross_preserve_forward(y) catch {
      _ => ()
    } noraise {
      _ => fail("invalid cross shape accepted")
    }
  }
}
