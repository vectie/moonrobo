///|
// Fixed-input native execution test, deliberately separate from production.
async test "compiled MLP forward VJP and fresh parameter inputs" {
  guard @env.get_env_var("MOONROBO_COMPILED_MLP") is Some(route) else { return }
  guard ["eager", "aoti"].contains(route) else { fail("explicit MLP route") }
  let root = @env.get_env_var("MOONROBO_SHARED_INPUT").unwrap()
  let out = @env.get_env_var("MOONROBO_SHARED_OUTPUT").unwrap()
  let amp = @env.get_env_var("MOONROBO_SHARED_AMP").unwrap()
  let gate = @env.get_env_var("MOONROBO_COMPILED_GATE") == Some("1")
  let backend = @tensor.Backend::open(
    @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap(),
  )
  ignore(
    backend.configure_cuda_tf32(
      matmul=true,
      cudnn_conv=true,
      cudnn_rnn=true,
      before_first_tensor=true,
    ),
  )
  guard backend.cuda_free_bytes(0) > 25769803776L else {
    fail("24GiB startup reserve")
  }
  let initial = @json.parse(@fs.read_file(root + "/initial.json").text())
  guard initial is { "records": records, .. } else { fail("initial records") }
  let records : Array[SharedTensor] = @json.from_json(records)
  let parameters : Array[@tensor.Tensor] = []
  for i in 0..<14 {
    parameters.push(mlp_read_parameter(root, records, backend, i, true))
  }
  let layers : Array[@gpu.Layer] = []
  for i in 0..<4 {
    let j = i * 4
    layers.push({
      weight: parameters[j],
      bias: parameters[j + 1],
      norm_weight: if i < 3 {
        Some(parameters[j + 2])
      } else {
        None
      },
      norm_bias: if i < 3 {
        Some(parameters[j + 3])
      } else {
        None
      },
    })
  }
  let net : @gpu.Network = {
    layers,
    activation: Silu,
    layer_norm_mode: Native,
    mlp_precision: if amp == "bf16" {
      Bf16
    } else {
      Fp32
    },
    linear_mode: NativeLinear,
  }
  let block = if route == "aoti" {
    Some(
      backend.load_compiled_block(
        @env.get_env_var("MOONROBO_COMPILED_PACKAGE").unwrap(),
        cuda_device=0,
      ),
    )
  } else {
    None
  }
  let x = backend.from_values(
    [2048, 133],
    Array::makei(2048 * 133, i => ((i * 17 % 1009).to_double() - 504.0) / 504.0),
    cuda_device=0,
    requires_grad=true,
    dtype=Float32,
  )
  let dy = backend.from_values(
    [2048, 70],
    Array::makei(2048 * 70, i => ((i * 31 % 101).to_double() - 50.0) / 50.0),
    cuda_device=0,
    requires_grad=false,
    dtype=Float32,
  )
  let gradients = backend.adam([x, ..parameters], learning_rate=0.0002)
  let forward = fn() raise {
    match block {
      Some(b) => b.forward([x, ..parameters])
      None => net.forward(x)
    }
  }
  let saved : Array[SharedTensor] = []
  if gate {
    saved.push(shared_write(out, "x", x))
    saved.push(shared_write(out, "dy", dy))
  }
  let rows : Array[Json] = []
  let repetitions = if gate { 1 } else { 60 }
  for rep in 0..<repetitions {
    gradients.zero_grad()
    let mem = backend.cuda_memory_stats(0, synchronize=true)
    guard mem.cuda_free_bytes > 17179869184L &&
      mem.reserved_current_bytes < 34359738368L else {
      fail("runtime memory guard")
    }
    let start = shared_clock_ms()
    let y = forward()
    y.mul(dy).sum().backward()
    ignore(backend.cuda_memory_stats(0, synchronize=true))
    let elapsed = shared_clock_ms() - start
    rows.push({ "rep": rep, "steady": rep >= 10, "wall_ms": Json(elapsed) })
    if gate {
      saved.push(shared_write(out, "y", y))
      saved.push(shared_write(out, "dx", x.gradient()))
      for i, p in parameters {
        saved.push(shared_write(out, "dp-\{i}", p.gradient()))
      }
    }
  }
  if gate {
    // Changing a live parameter after a completed backward must affect the next
    // call. This is an optimizer update, not an edit to exported constants.
    let opt = backend.adam(parameters, learning_rate=0.0002)
    opt.step(clip_norm=1.0)
    saved.push(shared_write(out, "updated-y", forward()))
    for i, p in parameters {
      saved.push(shared_write(out, "updated-p-\{i}", p))
    }
    if block is Some(b) {
      try b.forward([x.narrow(0, 0, 1), ..parameters]) catch {
        @tensor.TensorError::Native(message) =>
          assert_true(message.contains("shape/stride/dtype/device mismatch"))
      } noraise {
        _ => fail("compiled block accepted an uncompiled batch")
      }
      let stale = forward()
      opt.step(clip_norm=1.0)
      try stale.sum().backward() catch {
        @tensor.TensorError::Native(message) =>
          assert_true(message.contains("modified by an inplace operation"))
      } noraise {
        _ => fail("compiled block missed a parameter version change")
      }
      // The temporary MoonBit owner dies at the end of this expression; its
      // saved autograd node must independently keep the native plan alive.
      let leased = backend
        .load_compiled_block(
          @env.get_env_var("MOONROBO_COMPILED_PACKAGE").unwrap(),
          cuda_device=0,
        )
        .forward([x, ..parameters])
      gradients.zero_grad()
      leased.mul(dy).sum().backward()
      assert_true(x.gradient_values().all(v => v == v && v.abs() < 1.0e300))
    }
  }
  @fs.write_file(
    out + "/result.json",
    (
      {
        "route": Json(route),
        "amp": Json(amp),
        "gate": gate,
        "rows": Json(rows),
        "records": Json(saved.map(r => r.to_json())),
      } : Json).stringify(indent=2),
    create_mode=CreateNew,
  )
}
