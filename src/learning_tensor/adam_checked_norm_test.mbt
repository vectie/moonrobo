///|
fn checked_norm_backend() -> (@learning_tensor.Backend, Int32)? raise {
  let path = match @env.get_env_var("MOONROBO_TENSOR_CHECKED_NORM_LIBRARY") {
    Some(path) => Some(path)
    None => @env.get_env_var("MOONROBO_TENSOR_LIBRARY")
  }
  guard path is Some(path) else {
    println("SKIP checked-norm Adam: set MOONROBO_TENSOR_CHECKED_NORM_LIBRARY")
    return None
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_checked_norm_adam())
  let device = if @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") ==
    Some("cuda:0") {
    0
  } else {
    -1
  }
  if device == 0 {
    assert_true(backend.cuda_device_count() > 0)
  }
  Some((backend, device))
}

///|
fn checked_norm_parameters(
  backend : @learning_tensor.Backend,
  device : Int32,
  dtype : @learning_tensor.DType,
) -> Array[@learning_tensor.Tensor] raise {
  [[], [0.25, -0.5, 0.75], [1.0, -1.0]].map(values => {
    backend.from_values(
      [values.length()],
      values,
      cuda_device=device,
      requires_grad=true,
      dtype~,
    )
  })
}

///|
fn checked_norm_backward(
  backend : @learning_tensor.Backend,
  device : Int32,
  ps : Array[@learning_tensor.Tensor],
  gradients : Array[Array[Double]],
) -> Unit raise {
  let mut loss = ps[0].sum()
  for i in 1..<gradients.length() {
    let gradient = backend.from_values(
      [gradients[i].length()],
      gradients[i],
      cuda_device=device,
      requires_grad=false,
      dtype=ps[i].dtype(),
    )
    loss = loss.add(ps[i].mul(gradient).sum())
  }
  loss.backward()
}

///|
fn checked_norm_snapshot(
  optimizer : @learning_tensor.Adam,
) -> Array[Array[Double]] raise {
  let values = []
  for p in 0..<3 {
    for kind in 0..<3 {
      values.push(optimizer.audit_tensor(p, kind~).values())
    }
  }
  values
}

///|
fn checked_norm_same_values(a : Array[Double], b : Array[Double]) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    assert_true(a[i] == b[i] || (a[i].is_nan() && b[i].is_nan()))
  }
}

///|
test "checked-norm Adam preserves clipped gradients parameters and moments" {
  guard checked_norm_backend() is Some((backend, device)) else { return }
  for dtype in [@learning_tensor.Float32, Float64] {
    for
      (clip_norm, clip_value) in [
        (1.0, 0.1),
        (100.0, 0.0),
        (0.0, 0.1),
        (0.0, 0.0),
      ] {
      let a = checked_norm_parameters(backend, device, dtype)
      let b = checked_norm_parameters(backend, device, dtype)
      let oa = backend.adam(a, beta2=0.95)
      let ob = backend.adam(b, beta2=0.95)
      for step in 0..<3 {
        oa.zero_grad()
        ob.zero_grad()
        let scale = (step + 1).to_double()
        let gradients = [
          [],
          [0.5 * scale, -2.0 * scale, 3.0 * scale],
          [0.0, -0.125],
        ]
        checked_norm_backward(backend, device, a, gradients)
        checked_norm_backward(backend, device, b, gradients)
        oa.step(clip_norm~, clip_value~)
        ob.step_checked_norm(clip_norm~, clip_value~)
        for i in 0..<a.length() {
          assert_eq(a[i].gradient().values(), b[i].gradient().values())
        }
        assert_eq(oa.audit_metadata(), ob.audit_metadata())
        assert_eq(checked_norm_snapshot(oa), checked_norm_snapshot(ob))
      }
    }
  }
  // Single-tensor L2 follows the original header's no-stack branch; zero norm
  // must preserve the same epsilon and coefficient clamp behavior.
  for values in [[0.0, 0.0], [3.0, 4.0]] {
    let a = backend.from_values(
      [2],
      values,
      cuda_device=device,
      requires_grad=true,
      dtype=Float32,
    )
    let b = backend.from_values(
      [2],
      values,
      cuda_device=device,
      requires_grad=true,
      dtype=Float32,
    )
    let oa = backend.adam([a])
    let ob = backend.adam([b])
    a.square().sum().backward()
    b.square().sum().backward()
    oa.step(clip_norm=1.0)
    ob.step_checked_norm(clip_norm=1.0)
    assert_eq(a.gradient().values(), b.gradient().values())
    assert_eq(oa.audit_metadata(), ob.audit_metadata())
    for kind in 0..<3 {
      assert_eq(
        oa.audit_tensor(0, kind~).values(),
        ob.audit_tensor(0, kind~).values(),
      )
    }
  }
}

///|
test "checked-norm Adam rejects NaN Inf overflow and missing gradients without mutation" {
  guard checked_norm_backend() is Some((backend, device)) else { return }
  for
    (bad, message) in [
      (0.0 / 0.0, "nonfinite Adam gradient"),
      (1.0 / 0.0, "nonfinite Adam gradient"),
      (2.0e20, "total norm of order"),
    ] {
    for candidate in [false, true] {
      let ps = checked_norm_parameters(backend, device, Float32)
      let optimizer = backend.adam(ps)
      checked_norm_backward(backend, device, ps, [
        [],
        [1.0, 2.0, 3.0],
        [4.0, 5.0],
      ])
      optimizer.step(clip_norm=1.0)
      let metadata = optimizer.audit_metadata()
      let before = checked_norm_snapshot(optimizer)
      optimizer.zero_grad()
      checked_norm_backward(backend, device, ps, [
        [],
        [bad, bad, bad],
        [4.0, 5.0],
      ])
      let gradients = ps.map(p => p.gradient().values())
      if bad == 2.0e20 {
        assert_true(gradients[1].all(x => !x.is_nan() && !x.is_inf()))
      }
      try {
        if candidate {
          optimizer.step_checked_norm(clip_norm=1.0, clip_value=0.1)
        } else {
          optimizer.step(clip_norm=1.0, clip_value=0.1)
        }
      } catch {
        @learning_tensor.TensorError::Native(error) =>
          assert_true(error.contains(message))
      } noraise {
        _ => fail("invalid gradient/norm was accepted")
      }
      assert_eq(optimizer.audit_metadata(), metadata)
      assert_eq(checked_norm_snapshot(optimizer), before)
      for i in 0..<ps.length() {
        checked_norm_same_values(ps[i].gradient().values(), gradients[i])
      }
      optimizer.zero_grad()
      checked_norm_backward(backend, device, ps, [[], [1.0, 2.0, 3.0]])
      let first_gradient = ps[1].gradient().values()
      try {
        if candidate {
          optimizer.step_checked_norm(clip_norm=1.0)
        } else {
          optimizer.step(clip_norm=1.0)
        }
      } catch {
        @learning_tensor.TensorError::Native(error) =>
          assert_true(error.contains("missing Adam gradient"))
      } noraise {
        _ => fail("missing gradient was accepted")
      }
      assert_eq(optimizer.audit_metadata(), metadata)
      assert_eq(checked_norm_snapshot(optimizer), before)
      assert_eq(ps[1].gradient().values(), first_gradient)
    }
  }
}

///|
test "checked-norm Adam optional symbol retains legacy plugin usability" {
  guard @env.get_env_var("MOONROBO_TENSOR_CHECKED_NORM_LEGACY_LIBRARY")
    is Some(path) else {
    println(
      "SKIP checked-norm old ABI test: set MOONROBO_TENSOR_CHECKED_NORM_LEGACY_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(!backend.has_checked_norm_adam())
  let p = backend.from_values([1], [1.0], cuda_device=-1, requires_grad=true)
  let optimizer = backend.adam([p])
  p.square().sum().backward()
  let before = p.values()
  let metadata = optimizer.audit_metadata()
  try optimizer.step_checked_norm(clip_norm=1.0) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("optional checked-norm Adam extension"))
  } noraise {
    _ => fail("old plugin silently accepted optional route")
  }
  assert_eq(p.values(), before)
  assert_eq(optimizer.audit_metadata(), metadata)
  optimizer.step(clip_norm=1.0)
  assert_true(p.values() != before)
}
