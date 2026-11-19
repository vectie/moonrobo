///|
fn coefficient_edges(backend : @tensor.Backend, cuda : Int32) -> Unit raise {
  for dtype in [@tensor.Float32, @tensor.Float64] {
    for (forward, split) in [(true, false), (false, true), (true, true)] {
      let values = [
        0.0, 0.0, 0.0, 1.0e-6, -2.0e-6, 3.0e-6, 0.00009999, 0.0, 0.0, 0.00010001,
        0.0, 0.0, 0.04, -0.03, 0.02, 3.141592653589793, 0.0, 0.0,
      ]
      let make = () => {
        backend.from_values(
          [6, 3],
          values,
          cuda_device=cuda,
          requires_grad=true,
          dtype~,
        )
      }
      let a = make()
      let b = make()
      let left = so3_exp(
        backend,
        a,
        detached_constants=true,
        fused_skew=true,
        fused_so3_tail=true,
        fused_so3_coefficients=true,
      )
      let right = so3_exp(
        backend,
        b,
        detached_constants=true,
        fused_skew=true,
        fused_so3_tail=true,
        fused_so3_coefficients=true,
        fused_so3_coefficients_forward=forward,
        split_so3_coefficients=split,
      )
      assert_eq(left.values(), right.values())
      let w = backend.from_values(
        [6, 3, 3],
        Array::makei(54, i => (i - 26).to_double() / 16.0),
        cuda_device=cuda,
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
}

///|
test "coefficient assembly and shared split preserve branches and full VJP" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP coefficient assembly")
    return
  }
  coefficient_edges(@tensor.Backend::open(path), -1)
}
