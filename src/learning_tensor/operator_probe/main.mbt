///|
/// Diagnostic infrastructure probe only: bounded tensor payload, no model,
/// dataset, replay or checkpoint. The sentinel executes after capture ends.
async fn main {
  let args = @env.args()
  guard args.length() == 2 || (args.length() == 3 && args[2] == "external-stop") else {
    fail("usage: operator-probe TENSOR_LIBRARY [external-stop]")
  }
  let library = args[1]
  let external_stop_probe = args.length() == 3
  let backend = @tensor.Backend::open(library)
  guard backend.cuda_device_count() > 0 else { fail("probe requires CUDA") }
  // Allocator telemetry deliberately refuses an uninitialized allocator.
  // Query actual runtime headroom before allocating the bounded fixture.
  let preallocation_cuda_free_bytes = backend.cuda_free_bytes(0)
  guard preallocation_cuda_free_bytes >= 17179869184L else {
    fail("operator probe requires 16 GiB CUDA headroom before allocation")
  }
  let values = Array::makei(4096, i => (i % 23 - 11).to_double() / 128.0)
  let baseline_x = backend.from_values(
    [64, 64],
    values,
    dtype=Float32,
    cuda_device=0,
    requires_grad=true,
  )
  let baseline_weight = backend.from_values(
    [64, 64],
    values,
    dtype=Float32,
    cuda_device=0,
    requires_grad=true,
  )
  let x = backend.from_values(
    [64, 64],
    values,
    dtype=Float32,
    cuda_device=0,
    requires_grad=true,
  )
  let weight = backend.from_values(
    [64, 64],
    values,
    dtype=Float32,
    cuda_device=0,
    requires_grad=true,
  )
  let baseline_optimizer = backend.adam([baseline_weight])
  let optimizer = backend.adam([weight])
  let before = backend.cuda_memory_stats(0, synchronize=true)
  // Identical small update without observers also warms the arithmetic.
  baseline_optimizer.zero_grad()
  let baseline_loss = baseline_x.matmul(baseline_weight).silu().square().mean()
  baseline_loss.backward()
  baseline_optimizer.step(clip_norm=1.0, clip_value=0.1)
  @tensor.configure_operator_diagnostics(
    backend,
    cuda_device=0,
    iteration=41,
    max_ranges=16,
    observer=@env.get_env_var("MOONROBO_OPERATOR_OBSERVER").unwrap_or("aten"),
  )
  defer (@tensor.clear_operator_diagnostics() catch { _ => () })
  println(
    "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"started\",\"iteration\":41}",
  )
  @tensor.operator_diagnostic_flush()
  let capture = @tensor.operator_diagnostic_iteration_begin(41)
  errdefer @tensor.operator_diagnostic_iteration_cancel(capture)
  optimizer.zero_grad()
  let loss = @tensor.operator_span("diag.probe.forward", () => {
    x.matmul(weight).silu().square().mean()
  })
  if external_stop_probe {
    // No GPU work during the fixed wait. The independent wrapper must stop
    // only collection after 1 s; this same target then performs backward/Adam.
    @async.sleep(5000)
  }
  @tensor.operator_span("diag.probe.backward", () => loss.backward())
  @tensor.operator_span("diag.probe.adam", () => {
    optimizer.step(clip_norm=1.0, clip_value=0.1)
  })
  @tensor.operator_diagnostic_iteration_end(capture)
  println(
    "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"completed\",\"iteration\":41}",
  )
  @tensor.operator_diagnostic_flush()
  // This work and output must finish even after Nsight stops collecting.
  let sentinel = x.stop_gradient().square().mean().values()
  assert_eq(sentinel, baseline_x.stop_gradient().square().mean().values())
  assert_eq(loss.values(), baseline_loss.values())
  assert_eq(x.gradient_values(), baseline_x.gradient_values())
  assert_eq(weight.gradient_values(), baseline_weight.gradient_values())
  assert_eq(optimizer.audit_metadata(), baseline_optimizer.audit_metadata())
  for kind in 0..<3 {
    assert_eq(
      optimizer.audit_tensor(0, kind~).values(),
      baseline_optimizer.audit_tensor(0, kind~).values(),
    )
  }
  let after = backend.cuda_memory_stats(0, synchronize=true)
  println(
    (
      {
        "format": "moonrobo.operator-timeline-probe.v1",
        "status": "passed",
        "external_stop_probe": Json(external_stop_probe),
        "preallocation_cuda_free_bytes": Json(preallocation_cuda_free_bytes),
        "post_capture_sentinel": Json(sentinel),
        "observer_math_parity": "exact same-input forward/input-gradient/weight-gradient/parameter/Adam-moments-and-step",
        "before": Json(before),
        "after": Json(after),
        "structural_evidence": @json.parse(
          @tensor.operator_diagnostics_report(),
        ),
        "nsight_capture_verified": false,
        "training_performance_claim": false,
      } : Json).stringify(),
  )
}
