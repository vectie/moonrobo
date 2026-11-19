///|
/// The dedicated no-save command is deliberately separate from train/preflight.
/// Merely selecting --iterations 41 never removes checkpoint admission.
fn operator_diagnostic_request(args : Array[String]) -> (Bool, Bool) raise {
  let only = args.length() >= 2 && args[1] == "diagnose-operators"
  let mut requested = only
  let mut seen = false
  for i, arg in args {
    guard !arg.has_prefix("--operator-diagnostics=") else {
      fail("--operator-diagnostics is a standalone opt-in flag")
    }
    if arg == "--operator-diagnostics" {
      guard !seen && (i + 1 == args.length() || args[i + 1].has_prefix("--")) else {
        fail("duplicate --operator-diagnostics or unexpected value")
      }
      seen = true
      requested = true
    }
  }
  if requested {
    guard args.length() >= 2 &&
      ["train", "preflight", "diagnose-operators"].contains(args[1]) else {
      fail("operator diagnostics require train/preflight or diagnose-operators")
    }
    guard !args.contains("--execution-profile") else {
      fail(
        "operator timeline uses NVTX-only ranges; do not mix execution CUDA-event profiling",
      )
    }
    guard !args.contains("--resume") && !args.contains("--distributed") else {
      fail("operator diagnostic protocol requires a fresh single-rank process")
    }
  }
  guard only || !args.contains("--preflight-only") else {
    fail("--preflight-only is reserved for diagnose-operators")
  }
  (requested, only)
}

///|
async fn run_operator_diagnostic_no_checkpoint(
  training : @runner.TrainingRunner,
  learner : @gpu.Learner,
  environment : ExecutionEnvironment,
  settings : Settings,
  output : String,
  identity : Json,
  plan : MemoryPlan,
  post_catalog_plan : MemoryPlan,
  telemetry : CudaTrainingTelemetry?,
) -> Json {
  guard settings.operator_diagnostic_only &&
    settings.options.iterations == 41 &&
    training.iteration == 0 else {
    fail(
      "operator no-save driver requires fresh dedicated 41-iteration command",
    )
  }
  training.run(
    settings.options,
    environment.inspect_fn,
    environment.step_fn,
    metrics => println(metrics.to_json().stringify()),
    synchronize_sampler=() => learner.synchronize_sampler(environment.sampler),
    on_phase=telemetry.map(diagnostic => {
      (phase, iteration) => diagnostic.sample(phase, iteration)
    }),
  )
  guard training.iteration == 41 else {
    fail("operator diagnostic did not execute 41 iterations")
  }
  let structural = @json.parse(@tensor.operator_diagnostics_report())
  guard structural
    is { "completed": True, "cancelled": False, "open_ranges": Number(0), .. } else {
    fail("selected operator capture did not complete structurally")
  }
  if telemetry is Some(diagnostic) {
    diagnostic.sample("operator_diagnostic_window_complete", training.iteration)
    diagnostic.status = "diagnostic-complete-no-checkpoint"
    save_cuda_telemetry(output, diagnostic)
  }
  @fs.write_file(
    output + "/operator-diagnostics.json",
    @utf8.encode(structural.stringify(indent=2) + "\n"),
    create_mode=CreateNew,
  )
  @tensor.clear_operator_diagnostics()
  {
    "format": "moonrobo.operator-diagnostic-run.v1",
    "diagnostic_completed": true,
    "iterations_executed": 41,
    "selected_capture_iteration": 41,
    "checkpoint_created": false,
    "continuation_supported": false,
    "use_for_throughput_comparison": false,
    "nsight_capture_verified": false,
    "identity": identity,
    "counters": Json(training.counters),
    "memory_plan": Json(plan),
    "post_catalog_memory_plan": Json(post_catalog_plan),
    "instrumentation_reserve_bytes": "4294967296",
    "operator_structural_evidence": "operator-diagnostics.json",
    "physics_backend": Json(environment.backend),
    "cuda_memory_telemetry": telemetry
    .map(d => d.report())
    .unwrap_or(Json::null()),
    "protocol": "fresh training prefix through iteration 41; one complete actor/critic capture; no checkpoint publication or restore",
  }
}
