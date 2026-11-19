///|
async fn run_native_training() -> Unit {
  let args = @env.args()
  let telemetry_enabled = cuda_telemetry_requested(args)
  ignore(operator_diagnostic_request(args))
  if args.length() >= 2 && ["evaluate", "export"].contains(args[1]) {
    guard !args.contains("--execution-profile") else {
      fail("--execution-profile is a training diagnostic")
    }
    guard !telemetry_enabled else {
      fail("--cuda-memory-telemetry is a training/preflight diagnostic")
    }
    run_inference(args)
    return
  }
  guard args.length() >= 2 &&
    ["train", "preflight", "diagnose-operators"].contains(args[1]) else {
    fail(
      "usage: aligned-gpu <train|preflight|evaluate|export> --tensor-library PATH --output PATH; evaluate/export requires --checkpoint RUN/current.json or --actor DIRECTORY. train/evaluate also require --library MUJOCO --scene MJCF --manifest PATH [--physics-library PATH --physics-artifact PATH]. train: --config PATH [--resume RUN/current.json] [--checkpoint-format v1|stream-v2] [--iterations N] [--cuda-memory-telemetry] [--distributed --rank 0|1 --world-size 2 --session-id FRESH_ID --nccl-id-file PATH --nccl-timeout-ms 30000 --data-ready-timeout-seconds 60..21600]",
    )
  }
  let config = bounded_json(required(args, "--config"), 1048576L)
  let s = settings(config, args)
  let bundle = bf16_profile(config, s, args)
  guard bundle is None || start_bf16_watch() else {
    fail("BF16 host/cgroup admission refused")
  }
  let bundle_identity = match bundle {
    Some(path) => Some(verify_bf16_bundle(path))
    None => None
  }
  let checkpoint_mode = checkpoint_format(args)
  // A fresh launch never reads/restores a generation, but still saves one.
  // Resolve this once and keep the same scope for every memory recheck.
  let resume = option(args, "--resume")
  let include_restore = resume is Some(_)
  errdefer report_data_ready_failure(s.distributed)
  let root_output = required(args, "--output")
  let output = match s.distributed {
    None => root_output
    Some(settings) => root_output + "/rank-\{settings.rank}"
  }
  let manifest = required(args, "--manifest")
  let tensor_library = required(args, "--tensor-library")
  let tensor = @tensor.Backend::open(tensor_library)
  if bundle is Some(_) {
    guard tensor.has_compiled_block() &&
      file_hash(tensor_library) ==
      "b08818ec2316e96f30fc7cbfcb80d5b16eed5d557d986f1edaf3597d8dda2da7" else {
      fail("fixed BF16 profile requires the validated GB10 tensor plugin")
    }
  }
  let graph_available = tensor.has_critic_cuda_graph()
  guard !s.optimizations.critic_cuda_graph || (s.device >= 0 && graph_available) else {
    fail(
      "critic_cuda_graph requires a CUDA device and graph-capable tensor plugin",
    )
  }
  guard s.optimizations.layer_norm_mode != @gpu.Native ||
    tensor.has_layer_norm() else {
    fail("native LayerNorm requires a layer-norm-capable tensor plugin")
  }
  guard s.optimizations.gradient_bucket_bytes == 0 ||
    (s.distributed is Some(_) && s.device >= 0 && tensor.has_gradient_buckets()) else {
    fail(
      "gradient buckets require distributed CUDA training and a bucket-capable tensor plugin",
    )
  }
  // Explicit precision is configured before preflight, model tensors or the
  // first NCCL control tensor. Legacy absence does not call the extension.
  let fp32 = configure_fp32_policy(tensor, config, s.device)
  let s = match bundle {
    Some(path) =>
      { ..s, verified_allocator_cap: Some(bf16_allocator_cap(path, config)), }
    None => s
  }
  if telemetry_enabled {
    validate_telemetry_capability(s.device, tensor.has_cuda_memory_telemetry())
  }
  // Paper metadata validation is CPU-only and has its own bounded stat/JSON
  // headroom checks. Validate the pinned real artifact before whole-run
  // admission, so an unknown-APIC upper bound cannot prevent that validation.
  // Initial keeps its historical ordering and memory estimate.
  let early_physical = if s.capacity_profile == @capacity.Paper4096 {
    physics_preflight(args, config, s)
  } else {
    None
  }
  let plan = preflight(
    tensor,
    s,
    manifest,
    physical?=early_physical,
    include_restore~,
  )
  let physical_preflight = if s.capacity_profile == @capacity.Paper4096 {
    early_physical
  } else {
    physics_preflight(args, config, s)
  }
  let plan_report : Json = with_fp32_policy(
    {
      "format": "moonrobo.native-tensor-memory-plan.v1",
      "plan": Json(plan),
      "batch_execution": Json(s.batch_execution),
      "execution_optimizations": Json(s.optimizations),
      "resident_reference_max_bytes": Json(s.resident_reference_max_bytes),
      "motion_sampler_bin_cap": Json(s.motion_sampler_bin_cap),
      "critic_cuda_graph_capability": {
        "requested": Json(s.optimizations.critic_cuda_graph),
        "available": Json(graph_available),
      },
      "estimate_only": true,
      "distributed": Json(s.distributed),
      "physics_artifact": Json(physical_preflight),
      "checkpoint_format": checkpoint_mode.name(),
      "checkpoint_memory_envelope_reduced": Json(
        s.serial_optimizer_save_workspace,
      ),
      "serial_optimizer_save_workspace": Json(s.serial_optimizer_save_workspace),
      "checkpoint_archive_workspace_scope": if s.serial_optimizer_save_workspace {
        "sequential save workspace only; per-file limits, complete archive file cache and restore estimates unchanged"
      } else {
        "legacy combined save and restore archive workspace"
      },
      "checkpoint_memory_model": if s.capacity_profile == @capacity.Paper4096 {
        "paper-stream-phase-v1"
      } else {
        "legacy-json-envelope"
      },
      "motion_cache_advice": Json(setting(config, "motion_cache_advice", false)),
      "compiled_mujoco_header_version": Json(
        @sim.compiled_mujoco_header_version(),
      ),
    },
    fp32,
  )
  if s.world_staging_max_bytes is Some(max_bytes) &&
    plan_report is Object(fields) {
    fields["world_staging_max_bytes"] = Json(max_bytes)
    fields["world_packed_replay"] = Json(s.world_packed_replay)
    fields["world_staging_usage"] = Json(
      @runner.world_staging_usage(
        s.learner.wm_batch,
        s.learner.wm_window,
        max_bytes~,
        limits=s.limits,
      ),
    )
  }
  if telemetry_enabled && plan_report is Object(fields) {
    fields["cuda_memory_telemetry_diagnostic"] = telemetry_options(
      max_samples=s.telemetry_max_samples,
    )
  }
  if s.noise_staging_max_bytes is Some(max_bytes) &&
    plan_report is Object(fields) {
    fields["noise_staging_max_bytes"] = Json(max_bytes)
    fields["noise_staging_usage"] = Json(
      @runner.noise_staging_usage(
        s.learner.policy_batch,
        s.mode.dim(),
        max_bytes~,
        limits=s.limits,
      ),
    )
  }
  println(plan_report.stringify())
  if args[1] == "preflight" ||
    (s.operator_diagnostic_only && args.contains("--preflight-only")) {
    return
  }
  guard @sim.compiled_mujoco_header_version() > 0 else {
    fail(
      "native MuJoCo bindings were built without headers (ABI version 0). Rebuild with CPATH pointing to the selected MuJoCo library's include directory containing mujoco/mujoco.h, and force recompilation of src/learning_physics/mujoco_stub.c. This must be fixed at build time, before running train.",
    )
  }
  guard !args.contains("--weights") else {
    fail(
      "native tensor CLI requires native generation checkpoints; use preserved conversion tools for weights-only imports",
    )
  }
  if @fs.exists(output) {
    guard resume is Some(_) else {
      fail("existing output directory: use --resume to preserve the run")
    }
  } else {
    @fs.mkdir(output, recursive=true)
  }
  if plan.phase_plan is Some(phases) {
    phases.require_output_free(output_free_bytes(output))
  }
  let lock = @fs.open(
    output + "/run.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer lock.close()
  guard lock.try_lock(Exclusive) else {
    fail("another native trainer owns the output directory")
  }
  let library = required(args, "--library")
  let scene = required(args, "--scene")
  let scene_hash = file_hash(scene)
  let asset_hash = scene_assets_hash(
    option(args, "--scene-assets-root").unwrap_or(dirname(scene)),
  )
  let prototype = @sim.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let kin = @tracking.kinematics(prototype)
  let model_report : Json = {
    "stage": "physics-model-loaded",
    "mujoco_runtime_version": Json(prototype.version()),
    "compiled_mujoco_header_version": Json(
      @sim.compiled_mujoco_header_version(),
    ),
    "scene_sha256": Json(scene_hash),
    "scene_assets_sha256": Json(asset_hash),
    "tracked_bodies": Json(kin.tracked.length()),
  }
  println(model_report.stringify())
  guard kin.tracked.length() == 14 else {
    fail("native G1 critic contract requires 14 tracked bodies")
  }
  validate_catalog_bound(manifest)
  let loaded = @aligned.load_motion_manifest(
    manifest,
    kin,
    split=option(args, "--split").unwrap_or(setting(config, "split", "train")),
    compute_body_features=true,
    max_sampler_bins=s.motion_sampler_bin_cap,
    storage="mmap",
    cache_dir=setting(config, "motion_cache_dir", output + "/reference-cache"),
    motion_cache_advice=setting(config, "motion_cache_advice", false),
    cache_advice_report=Some(report => println(Json(report).stringify())),
    max_gather_frames=s.limits.max_reference_frames,
  )
  let loaded = {
    ..loaded,
    motion: { ..loaded.motion, orthonormal_heading: bundle is Some(_), },
  }
  guard loaded.motion.names.length() <= 200000 else {
    fail("catalog exceeds initial native 200000-clip metadata envelope")
  }
  ignore(loaded.motion.require_actor_horizon(s.learner.horizon))
  let resident_reference_usage = match s.resident_reference_max_bytes {
    None => None
    Some(max_bytes) =>
      Some(
        @runner.resident_reference_usage(
          loaded.motion.states.length(),
          s.learner.goal_frames,
          max_bytes~,
        ),
      )
  }
  // Streaming a corpus can grow reclaimable file cache on unified-memory GPUs.
  // Requery actual CUDA/host free memory before any learner/scene allocation.
  let post_catalog_plan = preflight(
    tensor,
    s,
    manifest,
    physical?=physical_preflight,
    include_restore~,
    sampler_bins=loaded.motion.bins.length(),
  )
  println(
    (
      {
        "stage": "post-catalog-memory-admitted",
        "motion_count": Json(loaded.motion.names.length()),
        "resident_reference_usage": Json(resident_reference_usage),
        "manifest_sha256": Json(loaded.manifest_sha256),
        "plan": Json(post_catalog_plan),
        "batch_execution": Json(s.batch_execution),
        "estimate_only": true,
      } : Json).stringify(),
  )
  let identity : Json = with_fp32_policy(
    {
      "format": "moonrobo.native-tensor-run-identity.v1",
      "config": config,
      "learner_config": Json(s.learner),
      "batch_execution": Json(s.batch_execution),
      "numeric_backend": "moonbit-libtorch-float32",
      "native_executable_sha256": Json(file_hash("/proc/self/exe")),
      "tensor_library_sha256": Json(file_hash(tensor_library)),
      "torch_version": Json(tensor.version()),
      "mujoco_library_sha256": Json(file_hash(library)),
      "scene_sha256": Json(scene_hash),
      "scene_assets_sha256": Json(asset_hash),
      "manifest_sha256": Json(loaded.manifest_sha256),
      "split": Json(loaded.split),
      "reference_backend": "native-f64le-fixed-window-shards",
      "replay_quaternion_order": "wxyz",
      "physics_artifact_sha256": if s.backend == "isaac" {
        Json(file_hash(required(args, "--physics-artifact")))
      } else {
        Json::null()
      },
      "physics_library_sha256": if s.backend == "isaac" {
        Json(file_hash(required(args, "--physics-library")))
      } else {
        Json::null()
      },
      "seed": Json(s.seed),
      "cuda_device": Json(s.device),
      "distributed_session": match s.distributed {
        None => Json::null()
        Some(settings) =>
          {
            "session_id": Json(settings.session_id),
            "world_size": Json(settings.world_size),
            "exact_resume_supported": false,
          }
      },
    },
    fp32,
  )
  // Validate and decode a generation while the model/optimizer/physics pools
  if bundle_identity is Some(pins) && identity is Object(fields) {
    fields["compiled_bf16_package_sha256"] = pins
  }
  // have not yet been allocated. Failures leave the original run untouched.
  let saved_generation = match resume {
    Some(pointer) => Some(read_checkpoint(pointer, identity))
    None => None
  }
  // Storage selection affects all-rank checkpoint work, but not the durable
  // training identity: the same executable may read either supported format.
  let launch_identity : Json = telemetry_launch_identity(
    {
      "training_launch": distributed_launch_identity(identity, s),
      "batch_execution": Json(s.batch_execution),
      "checkpoint_format": checkpoint_mode.name(),
    },
    telemetry_enabled,
    max_samples=s.telemetry_max_samples,
  )
  @fs.write_file(
    output + "/identity.json",
    @utf8.encode(identity.stringify(indent=2) + "\n"),
    create_mode=CreateOrTruncate,
    sync=Full,
  )
  println(
    (
      {
        "stage": "native-inputs-ready",
        "rank": Json(s.distributed.map(x => x.rank).unwrap_or(0)),
        "identity_sha256": text_hash(identity.stringify()),
        "identity_file": output + "/identity.json",
      } : Json).stringify(),
  )
  let collective = match s.distributed {
    None => None
    Some(settings) => {
      await_data_ready(settings, launch_identity)
      if settings.data_ready_timeout_seconds is Some(_) {
        let ready_plan = preflight(
          tensor,
          s,
          manifest,
          physical?=physical_preflight,
          include_restore~,
          sampler_bins=loaded.motion.bins.length(),
        )
        if s.memory_admission_percent is Some(_) {
          println(
            (
              {
                "stage": "post-ddp-ready-memory-admitted",
                "plan": Json(ready_plan),
                "estimate_only": true,
              } : Json).stringify(),
          )
        }
      }
      Some(connect_distributed(tensor, settings, s.device))
    }
  }
  defer close_collective(collective)
  // Reject cross-host code/config/asset mismatch before constructing models or
  // entering the update loop. Both ranks must deploy the same executable.
  assert_collective_identity(collective, launch_identity)
  let context = @geometry.Context::new(
    tensor,
    kin,
    s.device,
    dtype=Float32,
    body_orientation_batched=s.optimizations.body_orientation_batched,
    submitted_cross=setting(config, "geometry_submitted_cross", false),
    submitted_axis=setting(config, "geometry_submitted_axis", false),
  )
  if s.profile_max_spans > 0 {
    @tensor.configure_profiling(
      tensor,
      cuda_device=s.device,
      max_spans=s.profile_max_spans,
    )
  }
  defer (@tensor.clear_profiling() catch { _ => () })
  if s.operator_diagnostics {
    @tensor.configure_operator_diagnostics(
      tensor,
      cuda_device=s.device,
      iteration=41,
      phase=@env.get_env_var("MOONROBO_OPERATOR_PHASE").unwrap_or(
        "actor_critic",
      ),
      observer=@env.get_env_var("MOONROBO_OPERATOR_OBSERVER").unwrap_or("aten"),
    )
  }
  defer (@tensor.clear_operator_diagnostics() catch { _ => () })
  let learner = @gpu.Learner::new(
    tensor,
    if bundle is Some(_) {
      context
      .with_smc_critic_layout(true)
      .with_smc_fk_layout(true)
      .with_smc_soft_limits()
    } else {
      context
    },
    config=s.learner,
    mode=s.mode,
    cuda_device=s.device,
    seed=s.seed,
    collective~,
    world_microbatch=s.batch_execution.world_microbatch,
    actor_microbatch=s.batch_execution.actor_microbatch,
    optimizations=s.optimizations,
  )
  if bundle is Some(path) {
    learner.compiled_reference_context = Some(
      context.with_smc_fk_layout(true).with_native_cross(true),
    )
    install_bf16_bundle(learner, path)
    println(
      (
        {
          "stage": "compiled-bf16-training-ready",
          "packages": Json(bundle_identity),
        } : Json).stringify(),
    )
  }
  // A requested diagnostic error must stop all ranks too, including failures
  // outside TrainingRunner::run (initial window and checkpoint boundaries).
  errdefer (if telemetry_enabled { learner.abort_distributed() })
  guard learner.batch_execution() == s.batch_execution else {
    fail("constructed learner batch execution differs from run identity")
  }
  let runner_started = @env.now()
  let training = @runner.TrainingRunner::new(
    learner,
    loaded.motion,
    s.replay_steps,
    s.environments,
    seed=s.seed,
    limits=s.limits,
    max_replay_values=s.capacity_profile.limits().max_replay_values,
    resident_reference_max_bytes=s.resident_reference_max_bytes,
    reference_fk_cache=s.reference_fk_cache,
    world_staging_max_bytes=s.world_staging_max_bytes,
    world_packed_replay=s.world_packed_replay,
    noise_staging_max_bytes=s.noise_staging_max_bytes,
  )
  if resident_reference_usage is Some(usage) {
    println(
      (
        {
          "stage": "resident-reference-cache-ready",
          "reference_fk_resident_bytes": Json(training.reference_fk_bytes()),
          "runner_construction_ms": @env.now() - runner_started,
          "includes_learner_state_synchronization": true,
          "usage": Json(usage),
          "reference_dtype": "float32",
          "included_in_iteration_timing": false,
        } : Json).stringify(),
    )
  }
  let environment = execution_environment(
    args,
    config,
    library,
    scene,
    prototype,
    kin,
    loaded.motion,
    s,
    scene_hash,
    @gpu.rank_seed(s.seed, collective),
    physical_preflight.map(x => x.manifest_sha256).unwrap_or(""),
  )
  let environment_closed = Ref::new(false)
  defer (if !environment_closed.val { (environment.close_fn)() })
  let resume_kind = match saved_generation {
    None => "fresh"
    Some((directory, saved)) => {
      let exact = restore_generation(directory, saved, training, environment)
      if exact {
        "exact"
      } else {
        "warm-reset-refill"
      }
    }
  }
  guard s.options.iterations >= training.iteration else {
    fail("target iteration precedes resumed state")
  }
  let telemetry = if telemetry_enabled {
    Some(
      CudaTrainingTelemetry::new(
        s.device,
        s.distributed.map(x => x.rank).unwrap_or(0),
        text_hash(identity.stringify()),
        resume_kind,
        training.iteration,
        () => tensor.cuda_memory_stats(s.device, synchronize=true),
        () => tensor.reset_cuda_memory_peaks(s.device, synchronize=true),
        () => telemetry_host_snapshot(),
        row => println(row.stringify()),
        max_samples=s.telemetry_max_samples,
        minimum_remaining_bytes=if s.memory_admission_percent is Some(_) {
          17179869184L
        } else {
          0L
        },
      ),
    )
  } else {
    None
  }
  errdefer (if telemetry is Some(diagnostic) {
    diagnostic.status = "failed"
    save_cuda_telemetry(output, diagnostic) catch {
      error =>
        println(
          (
            {
              "stage": "cuda-memory-telemetry-save-failed",
              "error": Json(error.to_string()),
            } : Json).stringify(),
        )
    }
  })
  if telemetry is Some(diagnostic) {
    diagnostic.start()
  }
  if s.operator_diagnostic_only {
    let diagnostic_report = run_operator_diagnostic_no_checkpoint(
      training, learner, environment, s, output, identity, plan, post_catalog_plan,
      telemetry,
    )
    (environment.close_fn)()
    environment_closed.val = true
    @fs.write_file(
      output + "/operator-diagnostic-run.json",
      @utf8.encode(diagnostic_report.stringify(indent=2) + "\n"),
      create_mode=CreateNew,
      sync=Full,
    )
    println(diagnostic_report.stringify())
    return
  }
  let started = @async.now()
  let mut last_receipt : GenerationReceipt? = None
  let mut distributed_receipt = Json::null()
  while training.iteration < s.options.iterations {
    let remaining = s.options.iterations - training.iteration
    let until = training.iteration + remaining.min(s.checkpoint_every)
    training.run(
      { ..s.options, iterations: until, },
      environment.inspect_fn,
      environment.step_fn,
      metrics => println(metrics.to_json().stringify()),
      synchronize_sampler=() => learner.synchronize_sampler(environment.sampler),
      on_phase=telemetry.map(diagnostic => {
        (phase, iteration) => diagnostic.sample(phase, iteration)
      }),
    )
    if telemetry is Some(diagnostic) {
      diagnostic.sample("checkpoint_begin", training.iteration)
    }
    let receipt = publish_checkpoint(
      output,
      training,
      environment,
      identity,
      plan,
      format=checkpoint_mode,
    )
    println(Json(receipt).stringify())
    last_receipt = Some(receipt)
    distributed_receipt = publish_distributed_checkpoint(
      training,
      output,
      root_output,
      identity,
      receipt.generation,
    )
    if telemetry is Some(diagnostic) {
      diagnostic.sample("checkpoint_complete", training.iteration)
    }
  }
  if last_receipt is None {
    if telemetry is Some(diagnostic) {
      diagnostic.sample("checkpoint_begin", training.iteration)
    }
    last_receipt = Some(
      publish_checkpoint(
        output,
        training,
        environment,
        identity,
        plan,
        format=checkpoint_mode,
      ),
    )
    distributed_receipt = publish_distributed_checkpoint(
      training,
      output,
      root_output,
      identity,
      last_receipt.unwrap().generation,
    )
    if telemetry is Some(diagnostic) {
      diagnostic.sample("checkpoint_complete", training.iteration)
    }
  }
  if telemetry is Some(diagnostic) {
    diagnostic.sample("training_and_checkpoint_complete", training.iteration)
    diagnostic.status = "complete"
  }
  let report : Json = with_fp32_policy(
    {
      "format": "moonrobo.native-tensor-training-report.v1",
      "identity": identity,
      "resume_kind": Json(resume_kind),
      "iteration": Json(training.iteration),
      "counters": Json(training.counters),
      "global_counters": Json(training.global_counters()),
      "checkpoint": Json(last_receipt),
      "shared_state_digest": Json(last_receipt.unwrap().shared_state_digest),
      "memory_plan": Json(plan),
      "post_catalog_memory_plan": Json(post_catalog_plan),
      "batch_execution": Json(learner.batch_execution()),
      "execution_optimizations": Json(s.optimizations),
      "critic_cuda_graph": learner.critic_graph_diagnostics(),
      "elapsed_milliseconds": Json(@async.now() - started),
      "physics_backend": Json(environment.backend),
      "physics_artifact": environment.native_identity,
      "distributed": Json(s.distributed is Some(_)),
      "rank": Json(s.distributed.map(x => x.rank).unwrap_or(0)),
      "world_size": Json(s.distributed.map(x => x.world_size).unwrap_or(1)),
      "collection_seed": Json(@gpu.rank_seed(s.seed, collective)),
      "distributed_checkpoint": distributed_receipt,
      "distributed_resume_supported": false,
      "learner_execution": {
        "device": Json(if s.device < 0 { "cpu" } else { "cuda:\{s.device}" }),
        "backend": "libtorch",
        "device_resident": Json(s.device >= 0),
      },
      "physics_execution": {
        "backend": Json(environment.backend),
        "device": Json(
          if s.backend == "mujoco" {
            "cpu"
          } else {
            "cuda:\{s.device}"
          },
        ),
      },
      "validation_scope": "requested-iteration-runtime-gate",
      "precision": "float32",
      "amp": if s.optimizations.mlp_precision == @gpu.Bf16 {
        "bf16"
      } else {
        "none"
      },
      "checkpoint_format": checkpoint_mode.name(),
      "checkpoint_memory_envelope_reduced": false,
      "hardware_execution": false,
      "checkpoint_memory_model": if s.capacity_profile == @capacity.Paper4096 {
        "paper-stream-phase-v1"
      } else {
        "legacy-json-envelope"
      },
      "robot_hardware_execution": false,
      "training_complete_for_requested_iterations": true,
      "convergence_verified": false,
    },
    fp32,
  )
  if telemetry is Some(diagnostic) && report is Object(fields) {
    fields["cuda_memory_telemetry"] = diagnostic.report()
    fields["cuda_memory_telemetry_file"] = Json(diagnostic.window_id + ".json")
  }
  if s.profile_max_spans > 0 {
    // The existing final memory-telemetry boundary has synchronized when enabled.
    // The profiling report itself never waits; incomplete events stay explicit.
    let profile = @json.parse(@tensor.profiling_report())
    @fs.write_file(
      output + "/execution-profile.json",
      @utf8.encode(profile.stringify(indent=2) + "\n"),
      create_mode=CreateNew,
    )
    if report is Object(fields) {
      fields["execution_profile"] = "execution-profile.json"
    }
  }
  if s.operator_diagnostics {
    let diagnostic = @json.parse(@tensor.operator_diagnostics_report())
    guard diagnostic
      is { "completed": True, "cancelled": False, "open_ranges": Number(0), .. } else {
      fail("selected operator diagnostic capture was not complete")
    }
    @fs.write_file(
      output + "/operator-diagnostics.json",
      @utf8.encode(diagnostic.stringify(indent=2) + "\n"),
      create_mode=CreateNew,
    )
    if report is Object(fields) {
      fields["operator_diagnostics"] = "operator-diagnostics.json"
    }
  }
  // Publish the bounded diagnostic first, so a successful run report never
  // references an unwritten telemetry file. Neither write changes current.json.
  if telemetry is Some(diagnostic) {
    save_cuda_telemetry(output, diagnostic)
  }
  @fs.write_file(
    output + "/report.json",
    @utf8.encode(report.stringify(indent=2) + "\n"),
    create_mode=CreateOrTruncate,
    sync=Full,
  )
  println(report.stringify())
}

///|
async fn main {
  run_native_training() catch {
    @sim.PhysicsError::Invalid(message) =>
      fail("native trainer physics failure: " + message)
    @tensor.TensorError::Native(message) =>
      fail("native trainer tensor failure: " + message)
    error => raise error
  }
}
