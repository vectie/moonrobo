///|
fn coefficient_full_edges(
  backend : @tensor.Backend,
  cuda : Int32,
) -> Unit raise {
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let edges = [
      0.0, 1.0e-24, 0.9999999e-8, 1.0e-8, 1.0000001e-8, 0.01, 1.0, 9.869604401089358,
      100.0, 1.0e6,
    ]
    let values = Array::makei(1054, i => {
      if i % 2 == 1 {
        123.0
      } else if i / 2 < edges.length() {
        edges[i / 2]
      } else {
        (i / 2).to_double() * 0.017
      }
    })
    let make = () => {
      backend.from_values(
        [527, 2],
        values,
        cuda_device=cuda,
        dtype~,
        requires_grad=true,
      )
    }
    let a = make()
    let b = make()
    let x = a.narrow(1, 0, 1).so3_coefficient_forward()
    let y = b.narrow(1, 0, 1).so3_coefficient_full_forward()
    assert_eq(x.values(), y.values())
    let weights = backend.from_values(
      [527, 2],
      Array::makei(1054, i => (i % 19 - 9).to_double() / 8.0),
      cuda_device=cuda,
      dtype~,
      requires_grad=false,
    )
    x.mul(weights).sum().backward()
    y.mul(weights).sum().backward()
    assert_eq(a.gradient_values(), b.gradient_values())
  }
}

///|
test "full coefficient fusion preserves strided scalar functions and VJP" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP full coefficient fusion")
    return
  }
  coefficient_full_edges(@tensor.Backend::open(path), -1)
}
