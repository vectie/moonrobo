///|
fn identity_field(identity : Json, name : String) -> Json raise {
  guard identity is Object(fields) && fields.get(name) is Some(value) else {
    fail("checkpoint identity missing " + name)
  }
  value
}

///|
fn verify_identity_field(
  identity : Json,
  name : String,
  actual : Json,
) -> Unit raise {
  guard identity_field(identity, name) == actual else {
    fail("evaluation input differs from training identity: " + name)
  }
}

///|
async fn inference_source_config(
  identity : Json,
  args : Array[String],
) -> (Json, Int32?) {
  let config = identity_field(identity, "config")
  let request = memory_admission_request(config)
  ignore(serial_optimizer_save_workspace_request(config))
  // Compare the complete immutable source configuration before discarding any
  // training-only field from the temporary evaluation settings copy.
  if option(args, "--config") is Some(path) {
    guard bounded_json(path, 1048576L) == config else {
      fail("inference config differs from checkpoint")
    }
  }
  (config, request)
}

///|
fn evaluation_runtime_config(config : Json) -> Json raise {
  ignore(memory_admission_request(config))
  ignore(serial_optimizer_save_workspace_request(config))
  guard config is Object(fields) else {
    fail("checkpoint config must be object")
  }
  let result = fields.copy()
  // A saved DDP rank may be evaluated independently. Neither this change nor
  // omission of the training admission setting rewrites source identity.
  result["distributed"] = false
  result.remove("memory_admission_percent")
  result.remove("serial_optimizer_save_workspace")
  // Training-only reset-sampler capacity does not constrain inference clips.
  result.remove("max_motion_sampler_bins")
  result.remove("noise_staging_batch")
  result.remove("noise_staging_max_mib")
  result.remove("actor_norm_snapshot")
  result.remove("world_error_batched")
  result.remove("sparse_joint_axis")
  Json::object(result)
}

///|
fn inference_training_memory_report(
  report : Json,
  source_percent : Int32?,
) -> Json raise {
  guard source_percent is Some(percent) else { return report }
  guard report is Object(fields) else {
    fail("inference report must be object")
  }
  let result = fields.copy()
  result["training_memory_policy_not_applied"] = true
  result["source_training_memory_admission_percent"] = Json(percent)
  result["training_memory_policy_scope"] = "source configuration retained unchanged; training admission and its 16 GiB telemetry reserve are not applied by inference; existing inference_memory and evaluation_reserve checks remain independent"
  Json::object(result)
}

///|
async fn run_inference(args : Array[String]) -> Unit {
  guard ![
    "--distributed", "--rank", "--world-size", "--iterations", "--resume", "--weights",
  ].any(name => args.contains(name)) else {
    fail(
      "evaluate/export is single-process inference; provide --checkpoint or --actor, not training/resume flags",
    )
  }
  let exporting = args[1] == "export"
  let output = required(args, "--output")
  guard !@fs.exists(output) else {
    fail("inference output must be fresh; existing artifacts are preserved")
  }
  let (archive, spec, source, expected_digests, loaded_archive) = inference_input(
    args,
  )
  let (config, source_memory_percent) = inference_source_config(
    source.identity,
    args,
  )
  // Validate saved precision before constructing any Actor tensors. CPU export
  // carries this source evidence unchanged and never claims CUDA execution.
  let source_fp32 = source_fp32_policy(source.identity)
  let tensor_library = required(args, "--tensor-library")
  let backend = @tensor.Backend::open(tensor_library)
  if exporting {
    guard option(args, "--device").unwrap_or("cpu") == "cpu" else {
      fail("actor export uses CPU to avoid allocating device memory")
    }
    let memory = inference_memory(backend, -1, archive, spec, 0L)
    let actor = @inference.Actor::load_archive(backend, archive, spec)
    let digests = actor.parameter_digests()
    if expected_digests is Some(expected) {
      guard Json(digests) == Json(expected) else {
        fail("actor semantic parameter digest differs")
      }
    }
    let staging = output + ".partial-\{@async.now()}"
    @fs.mkdir(staging, recursive=true)
    actor.save_archive(staging + "/actor.pt")
    sync_path(staging + "/actor.pt")
    let document : ActorArtifact = {
      format: "moonrobo.native-tensor-actor.v1",
      spec,
      contract: spec.contract(),
      source,
      archive_sha256: file_hash(staging + "/actor.pt"),
      parameters: digests,
    }
    let encoded = @utf8.encode(Json(document).stringify(indent=2) + "\n")
    guard encoded.length() <= 67108864 else {
      fail("actor metadata exceeds 64 MiB bound")
    }
    @fs.write_file(
      staging + "/actor.json",
      encoded,
      create_mode=CreateNew,
      sync=Full,
    )
    sync_path(staging)
    @fs.rename(staging, output, replace=false)
    sync_path(dirname(output))
    println(
      (
        inference_training_memory_report(
          fp32_inference_report(
            {
              "format": "moonrobo.native-actor-export-report.v1",
              "output": output,
              "archive_sha256": document.archive_sha256,
              "source_iteration": source.iteration,
              "input_archive": loaded_archive.report(),
              "memory_plan": memory,
              "optimizer_moments_exported": false,
              "replay_exported": false,
              "training_executed": false,
              "hardware_execution": false,
              "consumer": "aligned-gpu evaluate --actor DIRECTORY or inference.Actor::load_archive",
            },
            source_fp32,
            false,
          ),
          source_memory_percent,
        ) : Json).stringify(),
    )
    return
  }
  let s = settings(evaluation_runtime_config(config), args)
  if setting(config, "compiled_bf16_profile", "none") == "g1-corrected-v1" {
    guard start_bf16_watch() else {
      fail("BF16 evaluation host/cgroup admission refused")
    }
  }
  let runtime_fp32 = configure_fp32_policy(backend, config, s.device)
  verify_fp32_source(source_fp32, runtime_fp32)
  guard option(args, "--device") is None &&
    setting(config, "physics_dt", 0.005) == 0.005 else {
    fail(
      "evaluation uses saved learner device and four 0.005-second physics substeps",
    )
  }
  guard spec.hist == s.learner.hist &&
    spec.goal_frames == s.learner.goal_frames &&
    spec.hidden == s.learner.policy_hidden &&
    spec.mode() == s.mode else {
    fail("actor and run configuration differ")
  }
  let manifest = required(args, "--manifest")
  let library = required(args, "--library")
  let scene = required(args, "--scene")
  let scene_hash = file_hash(scene)
  for
    (name, actual) in [
      ("tensor_library_sha256", Json(file_hash(tensor_library))),
      ("torch_version", Json(backend.version())),
      ("mujoco_library_sha256", Json(file_hash(library))),
      ("scene_sha256", Json(scene_hash)),
      (
        "scene_assets_sha256",
        Json(
          scene_assets_hash(
            option(args, "--scene-assets-root").unwrap_or(dirname(scene)),
          ),
        ),
      ),
      ("manifest_sha256", Json(file_hash(manifest))),
      ("learner_config", Json(s.learner)),
    ] {
    verify_identity_field(source.identity, name, actual)
  }
  let physical = physics_preflight(args, config, s)
  if physical is Some(p) {
    verify_identity_field(
      source.identity,
      "physics_artifact_sha256",
      Json(p.manifest_sha256),
    )
    verify_identity_field(
      source.identity,
      "physics_library_sha256",
      Json(file_hash(required(args, "--physics-library"))),
    )
  }
  let manifest_bytes = bounded_physics_file(manifest, 268435456L)
  let reserve = evaluation_reserve(s, physical, manifest_bytes)
  ignore(inference_memory(backend, s.device, archive, spec, reserve))
  guard @sim.compiled_mujoco_header_version() > 0 else {
    fail("rebuild native MuJoCo bindings with real headers before evaluation")
  }
  let prototype = @sim.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let kin = @tracking.kinematics(prototype)
  guard kin.tracked.length() == 14 else {
    fail("evaluation requires G1's 14 tracked bodies")
  }
  validate_catalog_bound(manifest)
  let split : String = @json.from_json(identity_field(source.identity, "split"))
  let loaded = @aligned.load_motion_manifest(
    manifest,
    kin,
    split~,
    compute_body_features=true,
    storage="mmap",
    cache_dir=setting(
      config,
      "motion_cache_dir",
      dirname(output) + "/evaluation-reference-cache",
    ),
    motion_cache_advice=setting(config, "motion_cache_advice", false),
    cache_advice_report=Some(report => println(Json(report).stringify())),
    max_gather_frames=s.limits.max_reference_frames,
  )
  let loaded = {
    ..loaded,
    motion: {
      ..loaded.motion,
      orthonormal_heading: setting(config, "compiled_bf16_profile", "none") ==
      "g1-corrected-v1",
    },
  }
  guard loaded.motion.names == source.motion_names &&
    loaded.motion.source_sha256 == source.motion_sha256 &&
    loaded.motion.source_fps == source.source_fps &&
    Json(loaded.manifest_sha256) ==
    identity_field(source.identity, "manifest_sha256") else {
    fail("loaded evaluation references differ from training catalog")
  }
  let clips : Array[Int32] = match option(args, "--clip-indices") {
    Some(value) => @json.from_json(@json.parse(value))
    None => Array::makei(loaded.motion.names.length(), i => i)
  }
  guard !clips.is_empty() &&
    clips.all(i => i >= 0 && i < loaded.motion.names.length()) else {
    fail("invalid selected evaluation clips")
  }
  let seen = Array::make(loaded.motion.names.length(), false)
  for index in clips {
    let length = loaded.motion.clip_end[index] - loaded.motion.clip_start[index]
    guard !seen[index] && length > 0 && length <= 1000000 else {
      fail(
        "select distinct complete clips with at most 1000000 transitions each",
      )
    }
    seen[index] = true
  }
  let replicas = if s.backend == "isaac" { s.environments } else { 1 }
  let steps = clips.fold(init=0L, (sum, i) => {
    sum + (loaded.motion.clip_end[i] - loaded.motion.clip_start[i]).to_int64()
  })
  guard steps * replicas.to_int64() <= 2147483647L else {
    fail(
      "evaluation work exceeds current report counter capacity; select smaller full-clip sets",
    )
  }
  let loaded_reserve = evaluation_reserve(
    s,
    physical,
    manifest_bytes,
    sampler_bins=loaded.motion.bins.length(),
  )
  let memory = inference_memory(
    backend,
    s.device,
    archive,
    spec,
    loaded_reserve,
  )
  let actor = @inference.Actor::load_archive(
    backend,
    archive,
    spec,
    cuda_device=s.device,
  )
  if expected_digests is Some(expected) {
    guard Json(actor.parameter_digests()) == Json(expected) else {
      fail("actor semantic parameter digest differs")
    }
  }
  let environment = evaluation_environment(
    args,
    config,
    prototype,
    kin,
    loaded.motion,
    s,
    scene_hash,
    physical.map(x => x.manifest_sha256).unwrap_or(""),
  )
  defer (environment.close_fn)()
  let started = @async.now()
  let summary = actor.evaluate(
    loaded.motion,
    {
      eval_mode: true,
      auto_reset: false,
      timeout_disabled: true,
      observation_noise: false,
      domain_randomization: false,
      simulated_replica_count: environment.replicas,
    },
    environment.reset_fn,
    environment.inspect_fn,
    environment.step_fn,
    clip_indices=clips,
  )
  let report = inference_training_memory_report(
    fp32_inference_report(
      inference_report(
        summary,
        loaded.motion.names.length(),
        clips,
        environment.physical_settings,
        environment.replicas,
      ),
      runtime_fp32,
      true,
    ),
    source_memory_percent,
  )
  guard report is Object(report_fields) else {
    fail("evaluation report is not object")
  }
  let native_actor = loaded_archive.report()
  guard native_actor is Object(actor_fields) else {
    fail("loaded archive report is not object")
  }
  actor_fields["source"] = Json(source)
  actor_fields["spec"] = Json(spec)
  actor_fields["contract"] = spec.contract()
  actor_fields["runtime_tensor_library_sha256"] = Json(
    file_hash(tensor_library),
  )
  actor_fields["runtime_executable_sha256"] = Json(file_hash("/proc/self/exe"))
  actor_fields["device"] = Json(
    if s.device < 0 {
      "cpu"
    } else {
      "cuda:\{s.device}"
    },
  )
  actor_fields["precision"] = "float32"
  actor_fields["normalizers_frozen"] = true
  actor_fields["autograd"] = false
  report_fields["native_actor"] = native_actor
  report_fields["evaluation_scope"] = "training-catalog motions; no unseen-motion generalization claim"
  report_fields["selected_clip_indices"] = Json(clips)
  report_fields["extra_simulated_physical_steps"] = Json(
    summary.physical_steps.to_int64() * (environment.replicas - 1).to_int64(),
  )
  report_fields["memory_plan"] = memory
  report_fields["elapsed_milliseconds"] = Json(@async.now() - started)
  report_fields["training_executed"] = false
  report_fields["hardware_execution"] = false
  report_fields["strict_tracking"] = {
    "evaluated_clips": 0,
    "not_run": true,
    "interpretation": "this path implements paper full-clip return and termination metrics; separate engineering RMSE gate not run",
  }
  @fs.write_file(
    output,
    @utf8.encode(report.stringify(indent=2) + "\n"),
    create_mode=CreateNew,
    sync=Full,
  )
  println(report.stringify())
}

///|
fn inference_report(
  summary : @aligned.EvaluationSummary,
  catalog_count : Int32,
  clips : Array[Int32],
  physical_settings : Json,
  replicas : Int32,
) -> Json raise {
  let report = summary.report_json(
    [],
    physical_settings,
    simulated_replica_count=replicas,
  )
  guard report is Object(fields) &&
    fields["per_clip"] is Array(rows) &&
    rows.length() == clips.length() else {
    fail("evaluation report clip count differs")
  }
  // Reuse the shared numerical report, but replace its linear catalog searches
  // with already-validated indices. Full BONES catalogs otherwise cost O(C^2).
  for i, row in rows {
    guard row is Object(row_fields) else { fail("invalid per-clip report") }
    row_fields["metadata"] = { "clip_index": Json(clips[i]), "start_frame": 0 }
  }
  fields["catalog_clip_count"] = Json(catalog_count)
  fields["full_catalog_evaluated"] = Json(
    summary.benchmark_complete && clips.length() == catalog_count,
  )
  report
}
