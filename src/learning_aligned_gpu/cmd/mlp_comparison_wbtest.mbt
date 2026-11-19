///|
// Fixed-input MLP comparison, separate from FK, rollout, optimizer and IO.
// Uses the actual iteration-60 world weights exported by shared_fixture.
async fn mlp_read_parameter(
  root : String,
  records : Array[SharedTensor],
  backend : @tensor.Backend,
  index : Int32,
  grad : Bool,
) -> @tensor.Tensor {
  let found = records.filter(r => r.name == "world-\{index}-parameter")
  guard found is [r] && r.blob.count <= 16777216L else {
    fail("missing/bounded world parameter")
  }
  let values = FixedArray::make(r.blob.count.to_int(), 0.0)
  @stream.read_f64le(root, r.blob, (offset, block) => {
    for j, v in block {
      values[offset.to_int() + j] = v
    }
  })
  backend.from_fixed_values(
    r.blob.shape,
    values,
    cuda_device=0,
    requires_grad=grad,
    dtype=Float32,
  )
}

///|
fn mlp_mode() -> @gpu.LayerNormMode raise {
  match @env.get_env_var("MOONROBO_MLP_LN").unwrap_or("native") {
    "native" => @gpu.Native
    "expanded" => @gpu.Expanded
    _ => fail("explicit native|expanded LayerNorm required")
  }
}

///|
async test "SMC LayerNorm and world MLP shared VJP comparison" {
  guard @env.get_env_var("MOONROBO_MLP_MODE") is Some(mode) else { return }
  guard ["gate", "world", "actor"].contains(mode) else { fail("MLP mode") }
  let root = @env.get_env_var("MOONROBO_SHARED_INPUT").unwrap()
  let out = @env.get_env_var("MOONROBO_SHARED_OUTPUT").unwrap()
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
  guard backend.cuda_free_bytes(0) > 68719476736L else {
    fail("MLP requires original 64GiB startup guard")
  }
  let initial = @json.parse(@fs.read_file(root + "/initial.json").text())
  guard initial is { "records": records, .. } else { fail("initial records") }
  let records : Array[SharedTensor] = @json.from_json(records)
  let norm = mlp_mode()
  let cases = if mode == "gate" { ["world", "actor"] } else { [mode] }
  let saved : Array[SharedTensor] = []
  let results : Array[Json] = []
  if mode == "gate" {
    for width in [4, 2048] {
      for fixture in 0..<3 {
        let values = Array::makei(4 * width, i => {
          let v = ((i * 17 % 1009).to_double() - 504.0) / 504.0
          match fixture {
            0 => v
            1 => 1.0 + v * 0.001
            _ => 0.25
          }
        })
        let make = (shape, v, grad) => {
          backend.from_values(
            shape,
            v,
            cuda_device=0,
            requires_grad=grad,
            dtype=Float32,
          )
        }
        let x = make([4, width], values, true)
        let w = make(
          [width],
          Array::makei(width, i => 0.5 + (i % 13).to_double() / 13.0),
          true,
        )
        let b = make(
          [width],
          Array::makei(width, i => (i % 7).to_double() / 70.0),
          true,
        )
        let dy = make(
          [4, width],
          Array::makei(4 * width, i => {
            ((i * 31 % 101).to_double() - 50.0) / 50.0
          }),
          false,
        )
        let y = x.layer_norm(w, b)
        y.mul(dy).sum().backward()
        let prefix = "ln-\{width}-\{fixture}-"
        for
          (name, t) in [
            ("x", x),
            ("w", w),
            ("b", b),
            ("dy", dy),
            ("y", y),
            ("dx", x.gradient()),
            ("dw", w.gradient()),
            ("db", b.gradient()),
          ] {
          saved.push(shared_write(out, prefix + name, t))
        }
      }
    }
  }
  for task in cases {
    let parameters : Array[@tensor.Tensor] = []
    for i in 0..<14 {
      parameters.push(
        mlp_read_parameter(root, records, backend, i, task == "world"),
      )
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
    let linear_mode : @gpu.LinearMode = if @env.get_env_var(
        "MOONROBO_MLP_LINEAR",
      ) ==
      Some("native") {
      NativeLinear
    } else {
      MatmulBias
    }
    let net : @gpu.Network = {
      layers,
      activation: Silu,
      layer_norm_mode: norm,
      mlp_precision: Fp32,
      linear_mode,
    }
    let batch = if task == "world" { 2048 } else { 4096 }
    let chunk = if task == "world" { 2048 } else { 512 }
    let inputs = backend.from_values(
      [batch, 133],
      Array::makei(batch * 133, i => {
        ((i * 17 % 1009).to_double() - 504.0) / 504.0
      }),
      cuda_device=0,
      requires_grad=true,
      dtype=Float32,
    )
    let upstream = backend.from_values(
      [batch, 70],
      Array::makei(batch * 70, i => ((i * 31 % 101).to_double() - 50.0) / 50.0),
      cuda_device=0,
      requires_grad=false,
      dtype=Float32,
    )
    // Match SMC zero_grad(set_to_none=True). Tensor::zero_gradient deliberately
    // zeros existing storage, which adds AccumulateGrad work in later repeats.
    // This optimizer is only a holder/zeroer: it never takes a step or has state.
    let gradient_owner = backend.adam(
      [inputs, ..if task == "world" { parameters } else { [] }],
      learning_rate=0.0002,
    )
    if mode == "gate" {
      saved.push(shared_write(out, task + "-x", inputs))
      saved.push(shared_write(out, task + "-dy", upstream))
    }
    let rows : Array[Json] = []
    let reps = if mode == "gate" { 1 } else { 60 }
    let events = @env.get_env_var("MOONROBO_MLP_EVENTS") == Some("1")
    for rep in 0..<reps {
      gradient_owner.zero_grad()
      let mem = backend.cuda_memory_stats(0, synchronize=true)
      guard mem.cuda_free_bytes > 17179869184L else {
        fail("MLP 16GiB reserve")
      }
      if events {
        @tensor.configure_profiling(
          backend,
          cuda_device=0,
          max_spans=64,
          nvtx=false,
        )
      }
      let start = shared_clock_ms()
      for block in 0..<(batch / chunk) {
        let begin = @tensor.profile_begin("mlp.forward")
        let y = net.forward(inputs.narrow(0, block * chunk, chunk))
        let loss = y.mul(upstream.narrow(0, block * chunk, chunk)).sum()
        @tensor.profile_end(begin)
        let begin = @tensor.profile_begin("mlp.backward")
        loss.backward()
        @tensor.profile_end(begin)
        if mode == "gate" {
          saved.push(shared_write(out, task + "-y-\{block}", y))
        }
      }
      let submit = shared_clock_ms()
      ignore(backend.cuda_memory_stats(0, synchronize=true))
      let end = shared_clock_ms()
      let profile = if events {
        @json.parse(@tensor.profiling_report())
      } else {
        Json::null()
      }
      @tensor.clear_profiling()
      rows.push({
        "rep": Json(rep),
        "steady": Json(rep >= 10),
        "wall_ms": Json(end - start),
        "submit_ms": Json(submit - start),
        "profile": profile,
      })
    }
    if mode == "gate" {
      saved.push(shared_write(out, task + "-dx", inputs.gradient()))
      if task == "world" {
        for i, p in parameters {
          saved.push(shared_write(out, "world-dp-\{i}", p.gradient()))
        }
      }
    }
    results.push({
      "task": Json(task),
      "batch": Json(batch),
      "microbatch": Json(chunk),
      "rows": Json(rows),
    })
  }
  shared_json(out + "/result.json", {
    "mode": Json(mode),
    "layer_norm": Json(norm),
    "records": Json(saved),
    "cases": Json(results),
    "memory": Json(backend.cuda_memory_stats(0, synchronize=true)),
    "scope": "one world MLP, no temporal rollout, FK, Adam, sampling or upload; actor is eight input-gradient-only chunks",
  })
}
