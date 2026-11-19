///|
struct AuditedState {
  present : Bool
  step : Int64
} derive(FromJson)

///|
struct AuditedStates {
  parameter_count : Int32
  states : Array[AuditedState]
} derive(FromJson)

///|
test "gradient bucket capability is additive for new and legacy plugins" {
  for
    (variable, expected) in [
      ("MOONROBO_TENSOR_BUCKET_LIBRARY", true),
      ("MOONROBO_TENSOR_BUCKET_LEGACY_LIBRARY", false),
    ] {
    guard @env.get_env_var(variable) is Some(path) else {
      println("SKIP gradient bucket capability: set " + variable)
      continue
    }
    let backend = @learning_tensor.Backend::open(path)
    assert_eq(backend.has_gradient_buckets(), expected)
    // Capability discovery must not load NCCL or require a CUDA device.
    assert_eq(
      backend
      .from_values([2], [2.0, 3.0], cuda_device=-1, requires_grad=false)
      .square()
      .values(),
      [4.0, 9.0],
    )
  }
}

///|
fn near(
  actual : Array[Double],
  expected : Array[Double],
  tolerance~ : Double = 1.0e-6,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_true((actual[i] - expected[i]).abs() <= tolerance)
  }
}

///|
test "acos opcode computes values and gradients or explicitly refuses legacy plugin" {
  for
    (variable, supported) in [
      ("MOONROBO_TENSOR_ACOS_LIBRARY", true),
      ("MOONROBO_TENSOR_ACOS_LEGACY_LIBRARY", false),
    ] {
    guard @env.get_env_var(variable) is Some(path) else {
      println("SKIP acos integration: set " + variable)
      continue
    }
    let backend = @learning_tensor.Backend::open(path)
    let x = backend.from_values(
      [3],
      [-0.5, 0.0, 0.5],
      cuda_device=-1,
      requires_grad=true,
      dtype=Float64,
    )
    if supported {
      let y = x.acos()
      near(y.values(), [
        2.0943951023931953, 1.5707963267948966, 1.0471975511965979,
      ])
      y.sum().backward()
      near(x.gradient_values(), [-1.1547005383792517, -1.0, -1.1547005383792517])
    } else {
      try x.acos() catch {
        @learning_tensor.TensorError::Native(message) =>
          assert_true(message.contains("unknown unary operation"))
      } noraise {
        _ =>
          fail(
            "legacy plugin must refuse acos rather than substitute a formula",
          )
      }
      near(x.square().values(), [0.25, 0.0, 0.25])
    }
  }
}

///|
test "NCCL validates inputs and CPU backend refuses collective creation" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP NCCL negative integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  try
    backend.nccl_connect(b"short", rank=0, world_size=2, cuda_device=0)
  catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("short NCCL ID must be refused before native init")
  }
  let id = Bytes::make(128, 0)
  try backend.nccl_connect(id, rank=2, world_size=2, cuda_device=0) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("out-of-range rank must be refused before native init")
  }
  try
    backend.nccl_connect(id, rank=0, world_size=2, cuda_device=0, timeout_ms=0)
  catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("unbounded timeout must be refused before native init")
  }
  if backend.cuda_device_count() == 0 {
    try backend.nccl_id() catch {
      @learning_tensor.TensorError::Native(_) => ()
    } noraise {
      _ => fail("CPU-only backend must refuse NCCL unique ID generation")
    }
    try backend.nccl_connect(id, rank=0, world_size=2, cuda_device=0) catch {
      @learning_tensor.TensorError::Native(_) => ()
    } noraise {
      _ => fail("CPU-only backend must refuse NCCL communicator creation")
    }
  }
}

///|
test "backend missing library is a checked error" {
  try
    @learning_tensor.Backend::open("/nonexistent/moonrobo-tensor-library")
  catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("missing library must be rejected")
  }
}

///|
/// This integration test runs only with an explicitly built ABI 2 plugin.
test "LibTorch batched autograd and resumed Adam numerical integration" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP LibTorch integration: set MOONROBO_TENSOR_LIBRARY to an ABI 2 plugin",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  if backend.cuda_device_count() == 0 {
    try backend.cuda_free_bytes(0) catch {
      @learning_tensor.TensorError::Native(_) => ()
    } noraise {
      _ => fail("CPU-only backend must refuse CUDA memory query")
    }
  }
  let checkpoint = @env.get_env_var("MOONROBO_TENSOR_CHECKPOINT").unwrap_or(
    "target/learning-tensor/test-adam.pt",
  )
  let x = backend.from_values(
    [2, 2],
    [1.0, 2.0, 3.0, 4.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let w = backend.from_values(
    [2, 1],
    [1.0, -2.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let b = backend.from_values(
    [1],
    [0.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  assert_eq(x.dtype(), Float32)
  assert_eq(x.cuda_device(), -1)
  let optimizer = backend.adam([w, b], learning_rate=0.01, beta2=0.95)
  assert_true(
    optimizer.audit_metadata().contains("\"present\":false,\"step\":\"0\""),
  )
  try optimizer.audit_tensor(0, kind=1) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("fresh Adam must not invent audit moments")
  }
  let y = x.matmul(w).add(b)
  near(y.values(), [-3.0, -5.0])
  near(y.square().mean().values(), [17.0])
  y.square().mean().backward()
  near(w.gradient_values(), [-18.0, -26.0])
  near(b.gradient_values(), [-8.0])
  optimizer.step()
  near(w.values(), [1.01, -1.99])
  near(b.values(), [0.01])
  optimizer.save(checkpoint)
  let audit_after_save = optimizer.audit_metadata()
  assert_true(audit_after_save.contains("\"indices\":[0,1]"))
  assert_true(audit_after_save.contains("\"present\":true,\"step\":\"1\""))
  let audited : AuditedStates = @json.from_json(@json.parse(audit_after_save))
  assert_eq(audited.parameter_count, 2)
  assert_eq(audited.states.length(), 2)
  assert_true(audited.states[0].present)
  assert_eq(audited.states[0].step, 1L)
  near(optimizer.audit_tensor(0).values(), w.values(), tolerance=0.0)
  let saved_average = optimizer.audit_tensor(0, kind=1).values()
  let saved_squares = optimizer.audit_tensor(0, kind=2).values()
  near(saved_average, [-1.8, -2.6])
  near(saved_squares, [16.2, 33.8], tolerance=0.00001)
  optimizer.zero_grad()
  x.matmul(w).add(b).square().mean().backward()
  optimizer.step(clip_norm=1.0)
  let continued = w.values()
  let continued_bias = b.values()
  optimizer.set_learning_rate(0.003)
  optimizer.load(checkpoint)
  assert_eq(optimizer.audit_metadata(), audit_after_save)
  near(optimizer.audit_tensor(0, kind=1).values(), saved_average, tolerance=0.0)
  near(optimizer.audit_tensor(0, kind=2).values(), saved_squares, tolerance=0.0)
  try optimizer.audit_tensor(0, kind=3) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("non-AMSGrad optimizer must not invent max moments")
  }
  near(w.values(), [1.01, -1.99])
  x.matmul(w).add(b).square().mean().backward()
  optimizer.step(clip_norm=1.0)
  // Same weights, moments, step count and clipping -> identical next update.
  near(w.values(), continued, tolerance=0.0)
  near(b.values(), continued_bias, tolerance=0.0)
  near(x.mean_dim(0).values(), [2.0, 3.0])
  near(x.sum_dim(1, keepdim=true).values(), [3.0, 7.0])
  near(x.transpose_dims(0, 1).values(), [1.0, 3.0, 2.0, 4.0])
  near(x.reshape([4]).narrow(0, 1, 2).values(), [2.0, 3.0])
  let indices = backend.from_values(
    [2],
    [1.0, 0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Int64,
  )
  near(x.index_select(indices).values(), [3.0, 4.0, 1.0, 2.0])
  assert_eq(backend.stack([x, x]).shape(), [2, 2, 2])
  near(backend.concat([x, x], axis=1).values(), [
    1.0, 2.0, 1.0, 2.0, 3.0, 4.0, 3.0, 4.0,
  ])
  let cotangent = backend.from_values(
    [2, 2],
    [1.0, 1.0, 1.0, 1.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  near(x.square().pullback(x, cotangent).values(), [2.0, 4.0, 6.0, 8.0])
  near(x.affine(2.0, bias=-3.0).clamp(0.0, 2.0).values(), [0.0, 1.0, 2.0, 2.0])
  let bf16 = backend.from_values(
    [2],
    [1.0, -2.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=BFloat16,
  )
  assert_eq(bf16.dtype(), BFloat16)
  near(bf16.values(), [1.0, -2.0])
  // An Adam step cannot silently reuse a missing gradient after zero_grad.
  optimizer.zero_grad()
  try optimizer.step() catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("missing gradients must be rejected")
  }
  near(w.values(), continued, tolerance=0.0)
  try backend.adam([w, w]) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("duplicate parameters must be rejected")
  }
  let wrong = backend.from_values(
    [1],
    [123.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let wrong_optimizer = backend.adam([wrong])
  try wrong_optimizer.load(checkpoint) catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("mismatched parameter checkpoint must be rejected")
  }
  near(wrong.values(), [123.0], tolerance=0.0)
  let zero = backend.from_values(
    [1],
    [0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  w.div(zero).sum().add(b.sum()).backward()
  try optimizer.step() catch {
    @learning_tensor.TensorError::Native(_) => ()
  } noraise {
    _ => fail("nonfinite gradients must be rejected")
  }
  near(w.values(), continued, tolerance=0.0)
  println(
    "LibTorch " +
    backend.version() +
    ": CPU dtype/batch/autograd/Adam resume integration passed",
  )
}

///|
test "population variance uses correction zero and preserves dimensions" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP population variance: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  let x = backend.from_values(
    [3, 2],
    [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let variance = x.population_variance_dim(0, keepdim=true)
  assert_eq(variance.shape(), [1, 2])
  near(variance.values(), [8.0 / 3.0, 8.0 / 3.0])
  variance.sum().backward()
  near(x.gradient_values(), [
    -4.0 / 3.0,
    -4.0 / 3.0,
    0.0,
    0.0,
    4.0 / 3.0,
    4.0 / 3.0,
  ])
}
