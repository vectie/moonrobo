///|
fn layer_norm_test_device() -> Int32 raise {
  match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None => -1
    Some("cuda:0") => 0
    Some(_) => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cuda:0 when set")
  }
}

///|
fn layer_norm_test_backend(device : Int32) -> @learning_tensor.Backend? raise {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA LayerNorm test requires MOONROBO_TENSOR_LIBRARY")
    }
    return None
  }
  let backend = @learning_tensor.Backend::open(path)
  guard device < 0 || backend.cuda_device_count() > device else {
    fail("explicit CUDA LayerNorm test requires an available CUDA device")
  }
  Some(backend)
}

///|
// Same absolute/relative gate as the training microbatch audit. This is a
// numerical acceptance gate, not a claim of bitwise equality or GPU coverage.
fn layer_norm_near(
  actual : Array[Double],
  expected : Array[Double],
  label~ : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    let limit = 2.0e-6 + 2.0e-4 * expected[i].abs()
    guard !actual[i].is_nan() &&
      !actual[i].is_inf() &&
      !expected[i].is_nan() &&
      !expected[i].is_inf() &&
      (actual[i] - expected[i]).abs() <= limit else {
      fail(
        "LayerNorm parity [\{label}] at \{i}: \{actual[i]} vs \{expected[i]}, limit \{limit}",
      )
    }
  }
}

///|
fn layer_norm_expanded(
  x : @learning_tensor.Tensor,
  w : @learning_tensor.Tensor,
  b : @learning_tensor.Tensor,
) -> @learning_tensor.Tensor raise {
  let centered = x.sub(x.mean_dim(-1, keepdim=true))
  centered
  .div(
    centered.square().mean_dim(-1, keepdim=true).affine(1.0, bias=1.0e-5).sqrt(),
  )
  .mul(w)
  .add(b)
}

///|
fn layer_norm_adam_kind(kind : Int32) -> String {
  match kind {
    0 => "parameter"
    1 => "first-moment"
    2 => "second-moment"
    _ => "unknown"
  }
}

///|
test "native LayerNorm forward gradients and Adam match expanded path" {
  let device = layer_norm_test_device()
  guard layer_norm_test_backend(device) is Some(backend) else {
    println(
      "SKIP native LayerNorm numerical integration: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  guard backend.has_layer_norm() else {
    fail(
      "LayerNorm numerical integration requires the optional native extension",
    )
  }
  for dtype in [@learning_tensor.Float32, @learning_tensor.Float64] {
    for fixture in 0..<3 {
      let values = match fixture {
        0 => [0.2, -0.3, 0.4, 1.1, -2.0, 0.7, 1.4, -0.1, 0.3, 0.6, -0.9, 2.3]
        1 =>
          [
            1.0, 1.001, 0.999, 1.0005, -1.0, -1.001, -0.999, -1.0005, 0.0, 0.0002,
            -0.0003, 0.0001,
          ]
        _ => Array::make(12, 0.25)
      }
      let make = (shape, data, grad) => {
        backend.from_values(
          shape,
          data,
          cuda_device=device,
          requires_grad=grad,
          dtype~,
        )
      }
      let xn = make([3, 4], values, true)
      let xe = make([3, 4], values, true)
      let wn = make([4], [0.7, 1.2, -0.5, 0.3], true)
      let we = make([4], [0.7, 1.2, -0.5, 0.3], true)
      let bn = make([4], [0.1, -0.2, 0.3, 0.4], true)
      let be = make([4], [0.1, -0.2, 0.3, 0.4], true)
      let coefficient = make(
        [3, 4],
        [0.2, 0.5, -0.3, 0.7, 0.1, -0.4, 0.8, 0.6, 0.3, -0.7, 0.9, 0.2],
        false,
      )
      let on = backend.adam([wn, bn], learning_rate=0.0002)
      let oe = backend.adam([we, be], learning_rate=0.0002)
      for iteration in 0..<2 {
        let fixture_name = match fixture {
          0 => "ordinary"
          1 => "near-constant"
          _ => "constant"
        }
        let label = "device=\{device} dtype=\{Repr(dtype)} fixture=\{fixture}/\{fixture_name} shape=3x4 iteration=\{iteration}"
        let yn = xn.layer_norm(wn, bn)
        let ye = layer_norm_expanded(xe, we, be)
        assert_eq(yn.shape(), [3, 4])
        assert_eq(yn.dtype(), dtype)
        layer_norm_near(yn.values(), ye.values(), label=label + " forward")
        yn.mul(coefficient).square().mean().backward()
        ye.mul(coefficient).square().mean().backward()
        layer_norm_near(
          xn.gradient_values(),
          xe.gradient_values(),
          label=label + " input-gradient",
        )
        layer_norm_near(
          wn.gradient_values(),
          we.gradient_values(),
          label=label + " weight-gradient",
        )
        layer_norm_near(
          bn.gradient_values(),
          be.gradient_values(),
          label=label + " bias-gradient",
        )
        on.step(clip_norm=1.0)
        oe.step(clip_norm=1.0)
        assert_eq(on.audit_metadata(), oe.audit_metadata())
        for p in 0..<2 {
          for kind in 0..<3 {
            layer_norm_near(
              on.audit_tensor(p, kind~).values(),
              oe.audit_tensor(p, kind~).values(),
              label=label +
                " Adam parameter=\{p} state=\{kind}/\{layer_norm_adam_kind(kind)}",
            )
          }
        }
        on.zero_grad()
        oe.zero_grad()
        xn.zero_gradient()
        xe.zero_gradient()
      }
    }
  }
  if device >= 0 {
    layer_norm_paper_width_gate(backend, device)
  }
}

///|
// Explicit CUDA runs also cover the paper hidden width. Bounded at 256 rows;
// this is correctness validation, not an occupancy or throughput benchmark.
fn layer_norm_paper_width_gate(
  backend : @learning_tensor.Backend,
  device : Int32,
) -> Unit raise {
  let width = 2048
  let rows = 256
  let make = (shape, data, grad) => {
    backend.from_values(
      shape,
      data,
      cuda_device=device,
      requires_grad=grad,
      dtype=Float32,
    )
  }
  let values = Array::makei(rows * width, i => {
    ((i * 17 % 1009).to_double() - 504.0) / 504.0
  })
  let xn = make([rows, width], values, true)
  let xe = make([rows, width], values, true)
  let weights = Array::makei(width, i => 0.5 + (i % 13).to_double() / 13.0)
  let biases = Array::makei(width, i => (i % 7).to_double() / 70.0)
  let wn = make([width], weights, true)
  let we = make([width], weights, true)
  let bn = make([width], biases, true)
  let be = make([width], biases, true)
  let coefficients = make(
    [rows, width],
    Array::makei(rows * width, i => 0.25 + (i % 19).to_double() / 19.0),
    false,
  )
  let yn = xn.layer_norm(wn, bn)
  let ye = layer_norm_expanded(xe, we, be)
  let label = "device=\{device} dtype=Float32 fixture=paper-width shape=\{rows}x\{width}"
  layer_norm_near(yn.values(), ye.values(), label=label + " forward")
  yn.mul(coefficients).square().mean().backward()
  ye.mul(coefficients).square().mean().backward()
  layer_norm_near(
    xn.gradient_values(),
    xe.gradient_values(),
    label=label + " input-gradient",
  )
  layer_norm_near(
    wn.gradient_values(),
    we.gradient_values(),
    label=label + " weight-gradient",
  )
  layer_norm_near(
    bn.gradient_values(),
    be.gradient_values(),
    label=label + " bias-gradient",
  )
  let on = backend.adam([wn, bn], learning_rate=0.0002)
  let oe = backend.adam([we, be], learning_rate=0.0002)
  on.step(clip_norm=1.0)
  oe.step(clip_norm=1.0)
  assert_eq(on.audit_metadata(), oe.audit_metadata())
  for p in 0..<2 {
    for kind in 0..<3 {
      layer_norm_near(
        on.audit_tensor(p, kind~).values(),
        oe.audit_tensor(p, kind~).values(),
        label=label +
          " Adam parameter=\{p} state=\{kind}/\{layer_norm_adam_kind(kind)}",
      )
    }
  }
}

///|
test "native LayerNorm noncontiguous shape and invalid contract checks" {
  let device = layer_norm_test_device()
  guard layer_norm_test_backend(device) is Some(backend) else {
    println(
      "SKIP native LayerNorm contract integration: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  guard backend.has_layer_norm() else {
    fail("native LayerNorm extension required")
  }
  let make = (shape, values) => {
    backend.from_values(
      shape,
      values,
      cuda_device=device,
      requires_grad=false,
      dtype=Float32,
    )
  }
  let x = make([2, 3], [0.1, 0.2, 0.3, -0.4, 0.5, -0.6]).transpose()
  let w = make([2], [0.7, 1.1])
  let b = make([2], [0.2, -0.1])
  assert_eq(x.layer_norm(w, b).shape(), [3, 2])
  layer_norm_near(
    x.layer_norm(w, b).values(),
    layer_norm_expanded(x, w, b).values(),
    label="device=\{device} dtype=Float32 fixture=noncontiguous shape=3x2 forward",
  )
  for eps in [0.0, -1.0, 1.0 / 0.0, 0.0 / 0.0] {
    try x.layer_norm(w, b, eps~) catch {
      @learning_tensor.TensorError::Native(_) => ()
    } noraise {
      _ => fail("invalid epsilon accepted")
    }
  }
  let bad_shape = make([1, 2], [1.0, 1.0])
  try x.layer_norm(bad_shape, b) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("nonvector affine shape accepted")
  }
  let bad_dtype = backend.from_values(
    [2],
    [1.0, 1.0],
    cuda_device=device,
    requires_grad=false,
    dtype=Float64,
  )
  try x.layer_norm(bad_dtype, b) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("mixed affine dtype accepted")
  }
}

///|
test "legacy ABI 2 plugin keeps baseline usable and rejects native LayerNorm" {
  guard @env.get_env_var("MOONROBO_LEGACY_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP legacy LayerNorm compatibility: set MOONROBO_LEGACY_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_false(backend.has_layer_norm())
  let x = backend.from_values(
    [2],
    [0.2, 0.4],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let w = backend.from_values(
    [2],
    [1.0, 1.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let b = backend.from_values(
    [2],
    [0.0, 0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  assert_eq(layer_norm_expanded(x, w, b).shape(), [2])
  try x.layer_norm(w, b) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("optional native LayerNorm extension"))
  } noraise {
    _ => fail("missing native extension must not silently fall back")
  }
}
