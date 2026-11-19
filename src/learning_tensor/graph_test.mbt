///|
fn graph_near(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    let tolerance = 2.0e-6 + 2.0e-4 * expected[i].abs()
    guard !actual[i].is_nan() &&
      !actual[i].is_inf() &&
      !expected[i].is_nan() &&
      !expected[i].is_inf() &&
      (actual[i] - expected[i]).abs() <= tolerance else {
      fail(
        "critic graph \{label}[\{i}] \{actual[i]} vs \{expected[i]} tolerance \{tolerance}",
      )
    }
  }
}

///|
test "critic CUDA graph CPU and legacy capability refuse explicit capture" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP critic graph capability test: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  if backend.cuda_device_count() == 0 {
    assert_false(backend.has_critic_cuda_graph())
  }
  let input = backend.from_values(
    [1, 1],
    [0.1],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let target = backend.from_values(
    [1],
    [0.2],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let weight = backend.from_values(
    [1, 1],
    [0.3],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  try
    backend.capture_critic_graph([weight], input, target, x => {
      x.matmul(weight).reshape([-1])
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("CPU graph capture must fail explicitly")
  }
  if @env.get_env_var("MOONROBO_LEGACY_TENSOR_LIBRARY") is Some(legacy_path) {
    assert_false(
      @learning_tensor.Backend::open(legacy_path).has_critic_cuda_graph(),
    )
  }
}

///|
test "critic CUDA graph replays alternating inputs and Adam with stable gradients" {
  guard @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") is Some(device) else {
    println(
      "SKIP CUDA graph numerical integration: explicitly set MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0",
    )
    return
  }
  guard device == "cuda:0" else { fail("unsupported graph test device") }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    fail("explicit CUDA graph test requires MOONROBO_TENSOR_LIBRARY")
  }
  let backend = @learning_tensor.Backend::open(path)
  guard backend.has_critic_cuda_graph() else {
    fail("explicit CUDA graph test requires supported graph extension and CUDA")
  }
  let make = (shape, values, grad) => {
    backend.from_values(
      shape,
      values,
      cuda_device=0,
      requires_grad=grad,
      dtype=Float32,
    )
  }
  let wg = make([4, 1], [0.1, -0.2, 0.3, -0.4], true)
  let we = make([4, 1], [0.1, -0.2, 0.3, -0.4], true)
  let bg = make([1], [0.2], true)
  let be = make([1], [0.2], true)
  let inputs = [
    make(
      [8, 4],
      Array::makei(32, i => (i % 11).to_double() / 11.0 - 0.4),
      false,
    ),
    make([8, 4], Array::makei(32, i => (i % 7).to_double() / 7.0 - 0.2), false),
  ]
  let targets = [
    make([8], [0.3, -0.2, 0.4, -0.5, 0.6, -0.7, 0.8, -0.9], false),
    make([8], [-0.4, 0.5, -0.6, 0.7, -0.8, 0.9, -0.1, 0.2], false),
  ]
  let og = backend.adam([wg, bg], learning_rate=0.0002)
  let oe = backend.adam([we, be], learning_rate=0.0002)
  let initial_optimizer = og.audit_metadata()
  let initial_weight = wg.values()
  let initial_bias = bg.values()
  let graph_prediction : Ref[@learning_tensor.Tensor?] = Ref::new(None)
  let capture_calls = Ref::new(0)
  let overlap_rejected = Ref::new(false)
  let graph = backend.capture_critic_graph([wg, bg], inputs[0], targets[0], x => {
    capture_calls.val += 1
    if capture_calls.val == 4 {
      // Refusing an overlapping constructor must not allocate a temporary graph
      // whose destructor synchronizes/invalidates this active capture.
      try
        backend.capture_critic_graph([wg, bg], x, targets[0], nested => {
          nested.matmul(wg).add(bg).elu().reshape([-1])
        })
      catch {
        @learning_tensor.TensorError::Native(message) => {
          assert_true(
            message.contains("overlapping critic CUDA graph construction"),
          )
          overlap_rejected.val = true
        }
        error => raise error
      } noraise {
        _ => fail("overlapping capture was accepted")
      }
    }
    let prediction = x.matmul(wg).add(bg).elu().reshape([-1])
    graph_prediction.val = Some(prediction.stop_gradient())
    prediction
  })
  errdefer graph.cancel()
  assert_eq(og.audit_metadata(), initial_optimizer)
  assert_eq(wg.values(), initial_weight)
  assert_eq(bg.values(), initial_bias)
  assert_true(overlap_rejected.val)
  let losses : Array[@learning_tensor.Tensor] = []
  let expected_losses : Array[Double] = []
  for step in 0..<4 {
    let which = step % 2
    let loss = graph.replay(inputs[which], targets[which])
    oe.zero_grad()
    let expected_prediction = inputs[which]
      .matmul(we)
      .add(be)
      .elu()
      .reshape([-1])
    graph_near(
      graph_prediction.val.unwrap().values(),
      expected_prediction.values(),
      "prediction step \{step}",
    )
    let expected = expected_prediction.sub(targets[which]).square().mean()
    expected.backward()
    graph_near(loss.values(), expected.values(), "loss step \{step}")
    graph_near(
      wg.gradient_values(),
      we.gradient_values(),
      "weight gradient step \{step}",
    )
    graph_near(
      bg.gradient_values(),
      be.gradient_values(),
      "bias gradient step \{step}",
    )
    losses.push(loss)
    expected_losses.push(expected.values()[0])
    og.step(clip_norm=1.0)
    oe.step(clip_norm=1.0)
    assert_eq(og.audit_metadata(), oe.audit_metadata())
    for parameter in 0..<2 {
      for kind in 0..<3 {
        graph_near(
          og.audit_tensor(parameter, kind~).values(),
          oe.audit_tensor(parameter, kind~).values(),
          "Adam step \{step} parameter \{parameter} kind \{kind}",
        )
      }
    }
  }
  graph_near(
    backend.stack(losses).values(),
    expected_losses,
    "loss snapshots survive later replays",
  )
  let memory = graph.memory()
  assert_eq(memory.replay_count, 4L)
  assert_eq(memory.static_bytes, 160L)
  assert_true(memory.private_pool_reserved_bytes <= 1073741824L)
  let before_nonfinite = [wg.values(), bg.values()]
  let state_before_nonfinite = og.audit_metadata()
  let moments_before_nonfinite = [
    og.audit_tensor(0, kind=1).values(),
    og.audit_tensor(0, kind=2).values(),
    og.audit_tensor(1, kind=1).values(),
    og.audit_tensor(1, kind=2).values(),
  ]
  ignore(graph.replay(inputs[0], make([8], Array::make(8, 0.0 / 0.0), false)))
  try og.step(clip_norm=1.0) catch {
    _ => ()
  } noraise {
    _ => fail("graph nonfinite gradients bypassed Adam finite check")
  }
  assert_eq(wg.values(), before_nonfinite[0])
  assert_eq(bg.values(), before_nonfinite[1])
  assert_eq(og.audit_metadata(), state_before_nonfinite)
  for p in 0..<2 {
    for kind in 1..<3 {
      assert_eq(
        og.audit_tensor(p, kind~).values(),
        moments_before_nonfinite[p * 2 + kind - 1],
      )
    }
  }
  // Same-size-but-different-layout/shape must not silently recapture.
  try graph.replay(inputs[0].reshape([4, 8]), targets[0]) catch {
    _ => ()
  } noraise {
    _ => fail("graph accepted changed shape")
  }
  // Existing Adam zero_grad intentionally invalidates the fixed-grad contract.
  og.zero_grad()
  try graph.replay(inputs[0], targets[0]) catch {
    _ => ()
  } noraise {
    _ => fail("graph accepted replaced/undefined gradient storage")
  }
  graph.close()
  graph.close()
  try graph.replay(inputs[0], targets[0]) catch {
    _ => ()
  } noraise {
    _ => fail("closed graph replay accepted")
  }
  // A pure host callback error can be cleaned up only when native capture_end
  // succeeds. Native begin/end failure poisons the process (separate test).
  let calls = Ref::new(0)
  try
    backend.capture_critic_graph([wg, bg], inputs[0], targets[0], x => {
      calls.val += 1
      if calls.val == 4 {
        fail("intentional capture callback error")
      }
      x.matmul(wg).add(bg).elu().reshape([-1])
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("capture callback error was swallowed")
  }
  let rebuilt = backend.capture_critic_graph([wg, bg], inputs[0], targets[0], x => {
    x.matmul(wg).add(bg).elu().reshape([-1])
  })
  errdefer rebuilt.cancel()
  ignore(rebuilt.replay(inputs[1], targets[1]).values())
  rebuilt.close()
}

///|
// Deliberately invalidates capture. Run alone in a disposable process with the
// explicit flag; successful refusal is not permission to keep training there.
test "critic CUDA graph failed capture end poisons process and refuses reuse" {
  guard @env.get_env_var("MOONROBO_CUDA_GRAPH_POISON_TEST") == Some("1") else {
    println(
      "SKIP destructive graph lifecycle diagnostic: set MOONROBO_CUDA_GRAPH_POISON_TEST=1 and run this test alone",
    )
    return
  }
  guard @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") == Some("cuda:0") else {
    fail("graph poison diagnostic requires explicit cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    fail("graph poison diagnostic requires CUDA plugin")
  }
  let backend = @learning_tensor.Backend::open(path)
  guard backend.has_critic_cuda_graph() else {
    fail("graph poison diagnostic requires supported CUDA graph plugin")
  }
  let make = (shape, values, grad) => {
    backend.from_values(
      shape,
      values,
      cuda_device=0,
      requires_grad=grad,
      dtype=Float32,
    )
  }
  let input = make([1, 1], [0.3], false)
  let target = make([1], [0.5], false)
  let weight = make([1, 1], [0.7], true)
  guard backend.has_cuda_memory_telemetry() else {
    fail(
      "graph poison diagnostic requires the direct CUDA synchronization telemetry extension",
    )
  }
  // Validate the extension outside capture before deliberately asking CUDA to
  // synchronize a capturing stream. A CPU tensor copy is not equivalent: ATen
  // rejects unpinned host memory before CUDA sees an invalidating operation.
  ignore(backend.cuda_memory_stats(0, synchronize=true))
  let calls = Ref::new(0)
  let first_error = Ref::new("")
  try
    backend.capture_critic_graph([weight], input, target, x => {
      calls.val += 1
      if calls.val == 4 {
        ignore(backend.cuda_memory_stats(0, synchronize=true))
      }
      x.matmul(weight).reshape([-1])
    })
  catch {
    @learning_tensor.TensorError::Native(message) => {
      first_error.val = message
      println(
        "graph poison diagnostic first error (callback \{calls.val}): \{message}",
      )
    }
    error => raise error
  } noraise {
    _ =>
      fail("direct CUDA synchronization during capture unexpectedly succeeded")
  }
  assert_eq(calls.val, 4)
  try
    backend.capture_critic_graph([weight], input, target, x => {
      x.matmul(weight).reshape([-1])
    })
  catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("process poisoned"))
    error => raise error
  } noraise {
    graph => {
      graph.close()
      fail(
        "failed capture end must prohibit process reuse; callback=\{calls.val}; first error=\{first_error.val}",
      )
    }
  }
}
