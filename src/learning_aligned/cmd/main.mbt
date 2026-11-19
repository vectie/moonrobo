///|
fn option(args : Array[String], name : String) -> String? raise {
  for i, arg in args {
    if arg == name {
      guard i + 1 < args.length() else { fail("missing option value: " + name) }
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn required(args : Array[String], name : String) -> String raise {
  guard option(args, name) is Some(value) else {
    fail("required option: " + name)
  }
  value
}

///|
fn[T : FromJson] setting(config : Json, name : String, fallback : T) -> T raise {
  guard config is Object(fields) else {
    fail("training config must be a JSON object")
  }
  match fields.get(name) {
    Some(value) => @json.from_json(value)
    None => fallback
  }
}

///|
fn learner_config(config : Json) -> @aligned.LearnerConfig raise {
  let d = @aligned.LearnerConfig::default()
  {
    wm_hidden: setting(config, "wm_hidden", d.wm_hidden),
    policy_hidden: setting(config, "pi_hidden", d.policy_hidden),
    critic_hidden: setting(config, "critic_hidden", d.critic_hidden),
    hist: setting(config, "hist", d.hist),
    goal_frames: setting(config, "goal_frames", d.goal_frames),
    horizon: setting(config, "horizon", d.horizon),
    wm_window: setting(config, "wm_window", d.wm_window),
    wm_batches: setting(config, "wm_batches", d.wm_batches),
    wm_batch: setting(config, "wm_batch", d.wm_batch),
    policy_batch: setting(config, "pi_batch", d.policy_batch),
    learning_rate: setting(config, "lr", d.learning_rate),
    gamma: setting(config, "gamma", d.gamma),
    lam: setting(config, "lam", d.lam),
    critic_epochs: setting(config, "critic_epochs", d.critic_epochs),
    critic_minibatches: setting(
      config,
      "critic_minibatches",
      d.critic_minibatches,
    ),
    observation_noise: setting(config, "observation_noise", d.observation_noise),
  }
}

///|
fn physics_settings(
  config : @tracking.EnvironmentConfig,
  scene : String,
  env : ExecutionEnvironment,
) -> Json {
  {
    "backend": env.backend.to_json(),
    "native_artifact": env.native_identity,
    "friction": 1.0,
    "randomization": config.randomization && !config.eval_mode,
    "observation_noise": false,
    "self_collisions": config.self_collisions,
    "reset_noise": config.reset_noise && !config.eval_mode,
    "scene": scene.to_json(),
    "physics_substep_seconds": config.physics_dt.to_json(),
    "physics_substeps": @math.round(0.02 / config.physics_dt).to_int().to_json(),
    "control_seconds": 0.02,
    "context_resampling": config.context_resampling.to_json(),
    "simulated_replica_count": env.replicas.to_json(),
    "measured_replica_count": 1,
    "episode_time_limit_disabled": config.eval_mode.to_json(),
  }
}

///|
fn evaluate_native(
  learner : @aligned.Learner,
  env : ExecutionEnvironment,
  config : @tracking.EnvironmentConfig,
  scene : String,
  identity : Json,
  checkpoint_sha256 : String,
  initialization : Json,
) -> Json raise {
  let summary = learner.evaluate(
    {
      eval_mode: true,
      auto_reset: false,
      timeout_disabled: true,
      observation_noise: false,
      domain_randomization: false,
      simulated_replica_count: env.replicas,
    },
    frame => (env.evaluation_reset_fn)(frame),
    () => env.inspect()[0],
    action => (env.evaluation_step_fn)(action),
  )
  let report = summary.report_json(
    learner.motion.names,
    physics_settings(config, scene, env),
  )
  if report is Object(fields) {
    fields["identity"] = identity
    fields["checkpoint_sha256"] = checkpoint_sha256.to_json()
    fields["initialization"] = initialization
  }
  report
}

///|
async fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    fail(
      "usage: aligned <train|evaluate|export|verify|inspect-bundle> --library PATH --scene PATH --manifest PATH --config PATH --output PATH [--resume PATH]",
    )
  }
  let command = args[1]
  guard [
    "train", "evaluate", "export", "verify", "compile", "convert-usd", "inspect-bundle",
  ].contains(command) else {
    fail("unsupported aligned command")
  }
  if command == "inspect-bundle" {
    let scene = required(args, "--scene")
    let digest = @artifacts.sha256(@fs.read_file(scene).binary())
    let inspected = @gpu_native.inspect_bundle(
      required(args, "--physics-artifact"),
      digest,
      self_collisions=!args.contains("--disable-self-collisions"),
      expected_manifest_sha256?=option(args, "--manifest-sha256"),
      adapter_library?=option(args, "--physics-library"),
    )
    println(inspected.stringify(indent=2))
    return
  }
  let library = required(args, "--library")
  if command == "convert-usd" {
    let receipt = @usd.convert_usd(
      library,
      required(args, "--mjcf"),
      required(args, "--usd-output"),
      self_collisions=!args.contains("--disable-self-collisions"),
    )
    println(receipt.stringify(indent=2))
    return
  }
  if command == "compile" {
    let directory = required(args, "--description")
    let receipt = @assets.compile_description(
      library,
      directory,
      self_collisions=!args.contains("--disable-self-collisions"),
    )
    println(receipt.stringify(indent=2))
    return
  }
  let scene = required(args, "--scene")
  let manifest = option(args, "--manifest")
  let config_path = required(args, "--config")
  let output = required(args, "--output")
  let config = @json.parse(@utf8.decode(@fs.read_file(config_path).binary()))
  guard !args.contains("--distributed") &&
    !setting(config, "distributed", false) else {
    fail(
      "native aligned learner has no distributed gradient synchronization; use the preserved providers.motion_learning.aligned.train baseline with torchrun --distributed",
    )
  }
  let reference_storage : String = setting(config, "reference_storage", "eager")
  guard ["eager", "mmap"].contains(reference_storage) else {
    fail("unsupported native reference storage")
  }
  let motion_cache_dir : String = setting(
    config,
    "motion_cache_dir",
    output + ".reference-cache",
  )
  let max_reference_gather_frames : Int32 = setting(
    config, "max_reference_gather_frames", 131072,
  )
  let backend : String = setting(config, "backend", "mujoco")
  guard ["mujoco", "isaac"].contains(backend) else {
    fail(
      "native aligned backend must be mujoco or isaac (explicit Newton APIC artifact)",
    )
  }
  let device : String = setting(config, "device", "cpu")
  guard device == "cpu" && setting(config, "amp", "none") == "none" else {
    fail(
      "native training numerics require device=cpu and no AMP; select the CUDA simulator with physics_device_id",
    )
  }
  let config_learner = learner_config(config)
  let mode = match setting(config, "observation_mode", "paper") {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("unsupported observation mode")
  }
  let prototype = @sim.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let kin = @tracking.kinematics(prototype)
  let loaded = match manifest {
    Some(path) =>
      @aligned.load_motion_manifest(
        path,
        kin,
        split=option(args, "--split").unwrap_or(
          setting(config, "split", "train"),
        ),
        storage=reference_storage,
        cache_dir=motion_cache_dir,
        max_gather_frames=max_reference_gather_frames,
      )
    None =>
      @aligned.load_motion_directory(
        required(args, "--motion-dir"),
        kin,
        source_fps=setting(config, "source_fps", 30.0),
        storage=reference_storage,
        cache_dir=motion_cache_dir,
        max_gather_frames=max_reference_gather_frames,
      )
  }
  let scene_sha256 = @artifacts.sha256(@fs.read_file(scene).binary())
  if command == "verify" {
    let report : Json = {
      "format": "moonrobo.aligned-motion-verification.v1",
      "manifest_sha256": loaded.manifest_sha256.to_json(),
      "model_sha256": scene_sha256.to_json(),
      "clip_count": loaded.motion.names.length().to_json(),
      "resampled_frames": loaded.motion.states.length().to_json(),
      "reset_bins": loaded.motion.bins.length().to_json(),
      "control_dt": 0.02,
      "all_clip_hashes_verified": true,
      "reference_storage": reference_storage.to_json(),
      "reference_backend": (if reference_storage == "mmap" {
        "native-f64le-fixed-window-shards"
      } else {
        "native-f64-eager"
      }).to_json(),
      "hardware_execution": false,
    }
    @fs.write_file(
      output,
      @utf8.encode(report.stringify(indent=2) + "\n"),
      create_mode=CreateOrTruncate,
    )
    return
  }
  let seed : UInt32 = setting(config, "seed", 1U)
  let learner = @aligned.Learner::new(
    kin,
    loaded.motion,
    config=config_learner,
    mode~,
    seed~,
  )
  let identity : Json = {
    "backend": (if backend == "mujoco" {
      "mujoco-cpu-native"
    } else {
      "isaac-newton-warp-apic-native"
    }).to_json(),
    "physics_artifact_manifest_sha256": if backend == "isaac" {
      @artifacts.sha256(
        @fs.read_file(required(args, "--physics-artifact")).binary(),
      ).to_json()
    } else {
      Json::null()
    },
    "physics_adapter_library_sha256": if backend == "isaac" {
      @artifacts.sha256(
        @fs.read_file(required(args, "--physics-library")).binary(),
      ).to_json()
    } else {
      Json::null()
    },
    "device": "cpu",
    "numeric_backend": "moonbit-scalar-f64",
    "reference_storage": reference_storage.to_json(),
    "reference_backend": (if reference_storage == "mmap" {
      "native-f64le-fixed-window-shards"
    } else {
      "native-f64-eager"
    }).to_json(),
    "scene": scene.to_json(),
    "scene_sha256": scene_sha256.to_json(),
    "manifest_sha256": loaded.manifest_sha256.to_json(),
    "motions": Array::makei(loaded.motion.names.length(), i => {
      "name": loaded.motion.names[i].to_json(),
      "sha256": loaded.motion.source_sha256[i].to_json(),
    }).to_json(),
    "split": loaded.split.to_json(),
    "observation_mode": setting(config, "observation_mode", "paper").to_json(),
    "physics_substep_seconds": setting(config, "physics_dt", 0.005).to_json(),
    "context_resampling": setting(config, "context_resampling", "episode").to_json(),
    "self_collisions": setting(config, "self_collisions", true).to_json(),
    "config": config,
  }
  let resume = option(args, "--resume")
  if resume is Some(path) {
    guard !path.has_suffix(".pt") && !path.has_suffix(".pth") else {
      fail(
        "Torch checkpoints support --weights only; Torch RNG/optimizer/physics state is not a MoonBit resume",
      )
    }
  }
  let weights = option(args, "--weights")
  guard resume is None || weights is None else {
    fail(
      "--weights is a fresh weights-only import and cannot be combined with --resume",
    )
  }
  let mut initialization = match weights {
    Some(path) =>
      learner.load_weights(
        path,
        scene_sha256,
        expected_sha256?=option(args, "--weights-sha256"),
      )
    None => Json::null()
  }
  if command == "train" && resume is None && @fs.exists(output) {
    fail("existing run: pass --resume to preserve and continue replay")
  }
  if command == "export" {
    guard resume is Some(path) else {
      fail("export requires --resume MoonBit JSON checkpoint")
    }
    let saved = @aligned.load_training_checkpoint(path, identity)
    let dataset = @aligned.decode_replay(
      saved.replay,
      loaded.motion,
      @tracking.joint_layout(prototype),
      scene,
      scene_sha256,
      mode~,
      goal_frames=config_learner.goal_frames,
    )
    @fs.write_file(
      output,
      @utf8.encode(dataset.stringify() + "\n"),
      create_mode=CreateOrTruncate,
    )
    return
  }
  let evaluating = command == "evaluate"
  let started = @async.now()
  let n : Int32 = if evaluating && backend == "mujoco" {
    1
  } else {
    setting(config, "num_envs", 1)
  }
  guard n > 0 else { fail("num_envs must be positive") }
  let environment_config : @tracking.EnvironmentConfig = {
    gamma: config_learner.gamma,
    eval_mode: evaluating,
    auto_reset: !evaluating,
    self_collisions: setting(config, "self_collisions", true),
    randomization: !evaluating,
    reset_noise: setting(config, "reset_noise", true),
    max_episode_steps: setting(config, "max_episode_steps", 500),
    physics_dt: setting(config, "physics_dt", 0.005),
    context_resampling: setting(config, "context_resampling", "episode"),
  }
  let env = execution_environment(
    args,
    config,
    library,
    scene,
    prototype,
    kin,
    loaded.motion,
    environment_config,
    seed,
    n,
  )
  errdefer (env.close_fn)()
  if evaluating {
    let checkpoint_path = match resume {
      Some(path) => {
        let saved = @aligned.load_training_checkpoint(path, identity)
        learner.restore(saved.learner)
        path
      }
      None =>
        match weights {
          Some(path) => path
          None => fail("evaluation requires --weights or --resume")
        }
    }
    let digest = @artifacts.sha256(@fs.read_file(checkpoint_path).binary())
    let report = evaluate_native(
      learner, env, environment_config, scene, identity, digest, initialization,
    )
    @fs.write_file(
      output,
      @utf8.encode(report.stringify(indent=2) + "\n"),
      create_mode=CreateOrTruncate,
    )
    (env.close_fn)()
    return
  }
  let runner = @aligned.TrainingRunner::new(
    learner,
    setting(config, "buffer_steps", 1000),
    n,
  )
  let mut current_iteration = 0
  let mut resume_kind = if weights is Some(_) {
    "weights-only-fresh"
  } else {
    "fresh"
  }
  if resume is Some(path) {
    let saved = @aligned.load_training_checkpoint(path, identity)
    let exact = env.restore(saved.environment)
    runner.restore(saved, exact)
    resume_kind = if exact { "exact" } else { "warm-reset-refill" }
    initialization = {
      "mode": resume_kind.to_json(),
      "source_path": path.to_json(),
      "source_sha256": @artifacts.sha256(@fs.read_file(path).binary()).to_json(),
      "optimizer_restored": true,
      "rng_restored": true,
      "replay_restored": exact.to_json(),
      "physical_state_restored": exact.to_json(),
    }
    current_iteration = saved.iteration
  }
  let iterations : Int32 = match option(args, "--iterations") {
    Some(text) => @json.from_json(@json.parse(text))
    None => setting(config, "iterations", 1)
  }
  guard iterations >= current_iteration else {
    fail("target iteration precedes resumed checkpoint")
  }
  let options : @aligned.TrainingOptions = {
    iterations,
    warmup_steps: setting(config, "warmup_steps", 64),
    world_only_iterations: setting(config, "wm_only_iters", 500),
    update_to_data: setting(config, "utd", 0.4),
    learning_rate_decay_iterations: setting(config, "lr_decay_iters", 250000),
    action_noise: setting(config, "action_noise", 0.1),
  }
  // This is intentionally only compilation-checked during migration; do not auto-run training.
  let checkpoint_every : Int32 = setting(config, "checkpoint_every", 2000)
  guard checkpoint_every > 0 else { fail("checkpoint_every must be positive") }
  let rows : Array[Json] = []
  let mut digest = ""
  while current_iteration < options.iterations {
    let until = ((current_iteration / checkpoint_every + 1) * checkpoint_every).min(
      options.iterations,
    )
    runner.run(
      { ..options, iterations: until, },
      () => env.inspect(),
      actions => env.step(actions),
      metrics => {
        let row = metrics.report_json()
        rows.push(row)
        println(row.stringify())
      },
    )
    let saved = runner.checkpoint(identity, env.snapshot().to_json())
    digest = @aligned.save_training_checkpoint(output + ".tmp", saved)
    @fs.rename(output + ".tmp", output, replace=true)
    let result : Json = {
      "checkpoint_sha256": digest.to_json(),
      "iteration": saved.iteration.to_json(),
      "counters": saved.counters.to_json(),
      "hardware_execution": false,
    }
    println(result.stringify())
    current_iteration = until
  }
  if digest == "" {
    digest = @aligned.save_training_checkpoint(
      output + ".tmp",
      runner.checkpoint(identity, env.snapshot().to_json()),
    )
    @fs.rename(output + ".tmp", output, replace=true)
  }
  let (python_sources, native_sources) = @aligned.source_provenance(
    option(args, "--python-source-root").unwrap_or(
      "providers/motion_learning/aligned",
    ),
    option(args, "--native-source-root").unwrap_or("src/learning_aligned"),
  )
  let dependencies : Json = {
    "torch": Json::null(),
    "mujoco": prototype.version().to_json(),
    "numeric_backend": "MoonBit scalar Float64 reverse-mode AD",
    "physics_artifact": env.native_identity,
    "module_metadata_sha256": @artifacts.sha256(
      @fs.read_file("moon.mod").binary(),
    ).to_json(),
    "mujoco_library_sha256": @artifacts.sha256(@fs.read_file(library).binary()).to_json(),
  }
  let report = learner.training_report(
    identity,
    config,
    resume_kind,
    current_iteration,
    runner.counters,
    (@async.now() - started).to_double() / 1000.0,
    rows,
    digest,
    physics_settings(environment_config, scene, env),
    python_sources,
    native_sources,
    dependencies,
    initialization~,
  )
  let report_path = option(args, "--report").unwrap_or(output + ".report.json")
  @fs.write_file(
    report_path,
    @utf8.encode(report.stringify(indent=2) + "\n"),
    create_mode=CreateOrTruncate,
  )
  (env.close_fn)()
  if args.contains("--evaluate") {
    let eval_loaded = match option(args, "--evaluation-manifest") {
      Some(path) =>
        @aligned.load_motion_manifest(
          path,
          kin,
          split=option(args, "--evaluation-split").unwrap_or("test"),
          storage=reference_storage,
          cache_dir=motion_cache_dir,
          max_gather_frames=max_reference_gather_frames,
        )
      None => loaded
    }
    let eval_learner = @aligned.Learner::new(
      kin,
      eval_loaded.motion,
      config=config_learner,
      mode~,
      seed~,
    )
    let imported = eval_learner.load_weights(
      output,
      scene_sha256,
      expected_sha256=digest,
    )
    let eval_config = {
      ..environment_config,
      eval_mode: true,
      auto_reset: false,
      randomization: false,
      reset_noise: false,
    }
    let eval_n = if backend == "mujoco" { 1 } else { n }
    let eval_env = execution_environment(
      args,
      config,
      library,
      scene,
      @sim.Runtime::open(library, scene, require_position_servos=false),
      kin,
      eval_loaded.motion,
      eval_config,
      seed,
      eval_n,
    )
    errdefer (eval_env.close_fn)()
    let eval_identity : Json = {
      "training_identity": identity,
      "evaluation_manifest_sha256": eval_loaded.manifest_sha256.to_json(),
      "evaluation_split": eval_loaded.split.to_json(),
      "evaluation_catalog": eval_loaded.manifest,
    }
    let evaluation = evaluate_native(
      eval_learner, eval_env, eval_config, scene, eval_identity, digest, imported,
    )
    let evaluation_path = option(args, "--evaluation-output").unwrap_or(
      output + ".evaluation.json",
    )
    @fs.write_file(
      evaluation_path,
      @utf8.encode(evaluation.stringify(indent=2) + "\n"),
      create_mode=CreateOrTruncate,
    )
    let receipt : Json = { "evaluation_file": evaluation_path.to_json() }
    println(receipt.stringify())
    (eval_env.close_fn)()
  }
}
