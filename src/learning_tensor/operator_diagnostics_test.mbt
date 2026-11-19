///|
test "observer controls preserve selected phase and boundary with no ranges" {
  guard @env.get_env_var("MOONROBO_OPERATOR_DIAGNOSTIC_LIBRARY") is Some(path) else {
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  for observer in ["off", "ranges", "aten"] {
    @learning_tensor.configure_operator_diagnostics(
      backend,
      cuda_device=-1,
      structural_only=true,
      phase="world",
      observer~,
    )
    defer (@learning_tensor.clear_operator_diagnostics() catch { _ => () })
    assert_false(@learning_tensor.operator_diagnostic_iteration_selected(41))
    assert_eq(@learning_tensor.operator_diagnostic_iteration_begin(41), 0L)
    assert_eq(
      @learning_tensor.operator_diagnostic_iteration_begin(40, phase="world"),
      0L,
    )
    let token = @learning_tensor.operator_diagnostic_iteration_begin(
      41,
      phase="world",
    )
    assert_eq(token, 1L)
    assert_eq(
      @learning_tensor.operator_diagnostics_enabled(),
      observer != "off",
    )
    let result = @learning_tensor.profile_span("fixture", () => {
      let x = backend.from_values(
        [2],
        [2.0, 3.0],
        cuda_device=-1,
        requires_grad=true,
      )
      let loss = x.square().mean()
      loss.backward()
      assert_eq(x.gradient_values(), [2.0, 3.0])
      loss.values()[0]
    })
    assert_eq(result, 6.5)
    @learning_tensor.operator_diagnostic_iteration_end(token)
    let report = @json.parse(@learning_tensor.operator_diagnostics_report())
    assert_true(report is { "completed": True, "open_ranges": Number(0), .. })
    if observer == "off" {
      assert_true(
        report is { "observer": String("off"), "range_count": Number(0), .. },
      )
    } else {
      assert_true(report is { "range_count": Number(1), .. })
    }
    @learning_tensor.clear_operator_diagnostics()
  }
}

///|
test "disabled operator diagnostics never require a plugin" {
  assert_false(@learning_tensor.operator_diagnostics_enabled())
  assert_eq(@learning_tensor.operator_diagnostic_iteration_begin(41), 0L)
  assert_eq(@learning_tensor.operator_range_begin("disabled"), 0L)
  assert_eq(@learning_tensor.operator_span("disabled", () => 42), 42)
  @learning_tensor.operator_range_end(0L)
  @learning_tensor.operator_range_cancel(0L)
  @learning_tensor.operator_diagnostic_iteration_end(0L)
  @learning_tensor.operator_diagnostic_iteration_cancel(0L)
}

///|
test "CPU structural diagnostics select once, preserve math and close errors" {
  guard @env.get_env_var("MOONROBO_OPERATOR_DIAGNOSTIC_LIBRARY") is Some(path) else {
    println(
      "SKIP operator structural integration: set MOONROBO_OPERATOR_DIAGNOSTIC_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  @learning_tensor.configure_operator_diagnostics(
    backend,
    cuda_device=-1,
    iteration=41,
    structural_only=true,
    max_ranges=4,
  )
  defer (@learning_tensor.clear_operator_diagnostics() catch { _ => () })
  assert_eq(@learning_tensor.operator_diagnostic_iteration_begin(40), 0L)
  assert_false(@learning_tensor.operator_diagnostics_enabled())
  let window = @learning_tensor.operator_diagnostic_iteration_begin(41)
  assert_true(@learning_tensor.operator_diagnostics_enabled())
  let outer = @learning_tensor.operator_range_begin("diag.actor.update")
  let value = @learning_tensor.operator_span("diag.actor.backward", () => {
    let x = backend.from_values(
      [2],
      [2.0, 3.0],
      cuda_device=-1,
      requires_grad=true,
    )
    let loss = x.square().mean()
    loss.backward()
    assert_eq(x.gradient_values(), [2.0, 3.0])
    loss.values()
  })
  assert_eq(value, [6.5])
  // A later errdefer must not pop the already closed inner scope or its parent.
  @learning_tensor.operator_range_cancel(2L)
  try
    @learning_tensor.operator_span("diag.expected_error", () => {
      fail("original diagnostic fixture error")
    })
  catch {
    error =>
      assert_true(
        error.to_string().contains("original diagnostic fixture error"),
      )
  } noraise {
    _ => fail("expected original callback error")
  }
  @learning_tensor.operator_range_end(outer)
  @learning_tensor.operator_diagnostic_iteration_end(window)
  @learning_tensor.operator_diagnostic_iteration_cancel(window)
  assert_false(@learning_tensor.operator_diagnostics_enabled())
  let report = @json.parse(@learning_tensor.operator_diagnostics_report())
  assert_true(
    report
    is {
      "structural_only": True,
      "automatic_aten_autograd_nvtx": False,
      "cuda_events_created": Number(0),
      "capture_verified": False,
      "completed": True,
      "open_ranges": Number(0),
      "range_count": Number(3),
      ..
    },
  )
  try @learning_tensor.operator_diagnostic_iteration_begin(41) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("single-use"))
    _ => fail("unexpected tensor error")
  } noraise {
    _ => fail("capture must not repeat")
  }
}

///|
test "CPU structural capacity overflow cancels without inventing complete trace" {
  guard @env.get_env_var("MOONROBO_OPERATOR_DIAGNOSTIC_LIBRARY") is Some(path) else {
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  @learning_tensor.configure_operator_diagnostics(
    backend,
    cuda_device=-1,
    structural_only=true,
    max_ranges=1,
  )
  defer (@learning_tensor.clear_operator_diagnostics() catch { _ => () })
  let capture = @learning_tensor.operator_diagnostic_iteration_begin(41)
  let token = @learning_tensor.operator_range_begin("outer")
  try @learning_tensor.operator_range_begin("over-bound") catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("bound exceeded"))
    _ => fail("unexpected tensor error")
  } noraise {
    _ => fail("range bound must reject")
  }
  @learning_tensor.operator_range_cancel(token)
  @learning_tensor.operator_diagnostic_iteration_cancel(capture)
  assert_true(
    @json.parse(@learning_tensor.operator_diagnostics_report())
    is { "completed": False, "cancelled": True, "open_ranges": Number(0), .. },
  )
}
