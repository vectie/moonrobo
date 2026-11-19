///|
test "native Linear output and both VJPs match an exact affine map" {
  let device = layer_norm_test_device()
  guard layer_norm_test_backend(device) is Some(backend) else {
    println("SKIP native Linear integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  assert_true(backend.has_linear())
  let make = (shape, values, grad) => {
    backend.from_values(
      shape,
      values,
      cuda_device=device,
      requires_grad=grad,
      dtype=Float32,
    )
  }
  let x = make([2, 3], [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], true)
  let w = make([2, 3], [1.0, 0.0, -1.0, 2.0, 1.0, 0.0], true)
  let b = make([2], [0.5, -0.5], true)
  let dy = make([2, 2], [1.0, 2.0, 3.0, 4.0], false)
  let y = x.linear(w, b)
  assert_eq(y.values(), [-1.5, 3.5, -1.5, 12.5])
  y.mul(dy).sum().backward()
  assert_eq(x.gradient_values(), [5.0, 2.0, -1.0, 11.0, 4.0, -3.0])
  assert_eq(w.gradient_values(), [13.0, 17.0, 21.0, 18.0, 24.0, 30.0])
  assert_eq(b.gradient_values(), [4.0, 6.0])
  x.zero_gradient()
  w.zero_gradient()
  b.zero_gradient()
  x.linear(w.stop_gradient(), b.stop_gradient()).mul(dy).sum().backward()
  assert_eq(x.gradient_values(), [5.0, 2.0, -1.0, 11.0, 4.0, -3.0])
  for p in [w, b] {
    assert_true(p.gradient_values().all(v => v == 0.0))
  }
  try x.linear(w, make([1], [0.0], false)) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("invalid Linear bias shape accepted")
  }
}
