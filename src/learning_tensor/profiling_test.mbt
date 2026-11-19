///|
test "disabled profiling preserves callback results and errors without a plugin" {
  assert_false(@learning_tensor.profiling_enabled())
  let calls = Ref::new(0)
  assert_eq(
    @learning_tensor.profile_span("disabled", () => {
      calls.val += 1
      42
    }),
    42,
  )
  assert_eq(calls.val, 1)
  assert_eq(@learning_tensor.profile_begin("disabled"), 0L)
  @learning_tensor.profile_end(0L)
  @learning_tensor.profile_cancel(0L)
  try
    @learning_tensor.profile_span("error", () => fail("original callback error"))
  catch {
    error => assert_true(error.to_string().contains("original callback error"))
  } noraise {
    _ => fail("profiling must preserve callback errors")
  }
  assert_true(@learning_tensor.profiling_report().contains("\"enabled\":false"))
}

///|
test "bounded CPU profiling nests, cancels, drops and never invents GPU times" {
  guard @env.get_env_var("MOONROBO_TENSOR_PROFILE_LIBRARY") is Some(path) else {
    println(
      "SKIP profiling CPU integration: set MOONROBO_TENSOR_PROFILE_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  try
    @learning_tensor.configure_profiling(backend, cuda_device=-1, max_spans=0)
  catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("1..65536"))
  } noraise {
    _ => fail("unbounded profiling must be rejected")
  }
  @learning_tensor.configure_profiling(
    backend,
    cuda_device=-1,
    max_spans=3,
    nvtx=false,
  )
  let outer = @learning_tensor.profile_begin("outer")
  let inner = @learning_tensor.profile_begin("inner")
  let x = backend.from_values(
    [2],
    [2.0, 3.0],
    cuda_device=-1,
    requires_grad=true,
  )
  let loss = x.square().mean()
  loss.backward()
  assert_eq(loss.values(), [6.5])
  assert_eq(x.gradient_values(), [2.0, 3.0])
  try @learning_tensor.profile_end(outer) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("reverse nesting"))
  } noraise {
    _ => fail("out-of-order close must fail without changing the stack")
  }
  @learning_tensor.profile_end(inner)
  try
    @learning_tensor.profile_span("cancelled", () => {
      fail("original callback error")
    })
  catch {
    error => assert_true(error.to_string().contains("original callback error"))
  } noraise {
    _ => fail("profiling must preserve callback errors")
  }
  assert_eq(@learning_tensor.profile_begin("dropped"), 0L)
  try @learning_tensor.clear_profiling() catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("open scopes"))
  } noraise {
    _ => fail("clearing an open session must fail")
  }
  @learning_tensor.profile_end(outer)
  let report = @json.parse(@learning_tensor.profiling_report())
  guard report
    is {
      "schema": String("moonrobo.execution-profile.v1"),
      "synchronized": False,
      "recorded_spans": Number(3),
      "dropped_spans": Number(1),
      "open_spans": Number(0),
      "spans": Array(spans),
      ..
    } else {
    fail("unexpected profiling report")
  }
  assert_eq(spans.length(), 3)
  assert_true(
    spans[0]
    is {
      "parent_id": Number(0),
      "gpu_status": String("disabled"),
      "gpu_elapsed_ms": Null,
      ..
    },
  )
  assert_true(
    spans[1]
    is {
      "parent_id": Number(1),
      "gpu_status": String("disabled"),
      "gpu_elapsed_ms": Null,
      ..
    },
  )
  assert_true(
    spans[2]
    is {
      "parent_id": Number(1),
      "cancelled": True,
      "gpu_status": String("cancelled"),
      "gpu_elapsed_ms": Null,
      ..
    },
  )
  // Snapshot is cumulative, does not drain, and requires no event synchronization.
  assert_eq(@json.parse(@learning_tensor.profiling_report()), report)
  @learning_tensor.clear_profiling()
  assert_false(@learning_tensor.profiling_enabled())
}

///|
test "legacy plugin remains loadable but explicit profiling is refused" {
  guard @env.get_env_var("MOONROBO_TENSOR_LEGACY_LIBRARY") is Some(path) else {
    println(
      "SKIP profiling legacy integration: set MOONROBO_TENSOR_LEGACY_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  try @learning_tensor.configure_profiling(backend, cuda_device=-1) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("lacks optional execution profiling extension"),
      )
  } noraise {
    _ => fail("missing profiling extension must be explicit")
  }
  assert_false(@learning_tensor.profiling_enabled())
}
