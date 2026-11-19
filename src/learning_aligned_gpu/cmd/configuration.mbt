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
// Parse the saved training request independently of this invocation's mode.
// Inference validates it before making an ephemeral runtime-only projection.
fn memory_admission_request(config : Json) -> Int32? raise {
  guard config is Object(fields) else {
    fail("training config must be a JSON object")
  }
  match fields.get("memory_admission_percent") {
    None => None
    Some(Number(value, ..)) if value >= 65.0 &&
      value <= 80.0 &&
      value.to_int().to_double() == value => {
      guard @capacity.CapacityProfile::parse(
          setting(config, "capacity_profile", "initial"),
        ) ==
        @capacity.Paper4096 else {
        fail("memory_admission_percent requires explicit paper-4096 capacity")
      }
      Some(value.to_int())
    }
    Some(_) =>
      fail("memory_admission_percent must be a JSON integer within 65..80")
  }
}

///|
fn serial_optimizer_save_workspace_request(config : Json) -> Bool raise {
  let enabled : Bool = setting(config, "serial_optimizer_save_workspace", false)
  guard !enabled || memory_admission_request(config) is Some(_) else {
    fail(
      "serial_optimizer_save_workspace requires paper-4096 and explicit memory_admission_percent",
    )
  }
  enabled
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
    wm_batch: setting(config, "wm_batch", 128),
    policy_batch: setting(config, "pi_batch", 128),
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
struct Settings {
  // Assigned only after installing and reading back the live process cap.
  verified_allocator_cap : Int64?
  capacity_profile : @capacity.CapacityProfile
  learner : @aligned.LearnerConfig
  batch_execution : @gpu.BatchExecutionPlan
  optimizations : @gpu.ExecutionOptimizations
  profile_max_spans : Int32
  operator_diagnostics : Bool
  operator_diagnostic_only : Bool
  telemetry_max_samples : Int32
  resident_reference_max_bytes : Int64?
  reference_fk_cache : Bool
  world_staging_max_bytes : Int64?
  world_packed_replay : Bool
  noise_staging_max_bytes : Int64?
  motion_sampler_bin_cap : Int32?
  mode : @aligned.ObservationMode
  backend : String
  device : Int32
  environments : Int32
  replay_steps : Int32
  seed : UInt32
  options : @aligned.TrainingOptions
  checkpoint_every : Int32
  limits : @runner.BatchLimits
  distributed : DistributedSettings?
  memory_admission_percent : Int32?
  serial_optimizer_save_workspace : Bool
}

///|
fn settings(config : Json, args : Array[String]) -> Settings raise {
  let (operator_diagnostics, operator_diagnostic_only) = operator_diagnostic_request(
    args,
  )
  ignore(fp32_request(config)) // Strict optional Boolean; absence stays legacy.
  let optimizations = execution_optimizations(config)
  let resident_reference_max_bytes = resident_reference_request(config)
  let reference_fk_cache : Bool = setting(config, "reference_fk_cache", false)
  let submitted_cross : Bool = setting(
    config, "geometry_submitted_cross", false,
  )
  let reuse_pre_step_state : Bool = setting(
    config, "reuse_pre_step_state", false,
  )
  ignore(submitted_cross)
  let submitted_axis : Bool = setting(config, "geometry_submitted_axis", false)
  ignore(submitted_axis)
  ignore(reuse_pre_step_state)
  guard !reference_fk_cache ||
    (resident_reference_max_bytes is Some(_) && optimizations.reuse_geometry) else {
    fail(
      "reference_fk_cache requires resident_reference_cache and reuse_geometry",
    )
  }
  let world_staging_max_bytes = world_staging_request(config)
  let world_packed_replay : Bool = setting(config, "world_packed_replay", false)
  guard !world_packed_replay || world_staging_max_bytes is Some(_) else {
    fail("world_packed_replay requires world_staging_batch")
  }
  let noise_staging_max_bytes = noise_staging_request(config)
  let telemetry_max_samples : Int32 = setting(
    config, "telemetry_max_samples", 128,
  )
  guard telemetry_max_samples >= 2 && telemetry_max_samples <= 1024 else {
    fail("telemetry_max_samples must be within 2..1024")
  }
  let profile_max_spans : Int32 = if args.contains("--execution-profile") {
    let value : Int32 = setting(config, "profile_max_spans", 8192)
    guard value >= 1 && value <= 65536 else {
      fail("profile_max_spans must be within 1..65536")
    }
    value
  } else {
    0
  }
  let capacity_profile = @capacity.CapacityProfile::parse(
    setting(config, "capacity_profile", "initial"),
  )
  let motion_sampler_bin_cap = motion_sampler_cap(
    config,
    capacity_profile,
    setting(config, "reference_storage", "mmap"),
  )
  let capacity = capacity_profile.limits()
  let memory_admission_percent = memory_admission_request(config)
  let serial_optimizer_save_workspace = serial_optimizer_save_workspace_request(
    config,
  )
  guard !serial_optimizer_save_workspace ||
    (
      capacity_profile == @capacity.Paper4096 &&
      memory_admission_percent is Some(_) &&
      args.contains("--cuda-memory-telemetry")
    ) else {
    fail(
      "serial_optimizer_save_workspace requires paper-4096, explicit memory_admission_percent and --cuda-memory-telemetry",
    )
  }
  if memory_admission_percent is Some(_) {
    guard !(args.length() >= 2 && ["evaluate", "export"].contains(args[1])) else {
      fail("memory_admission_percent is supported by training/preflight only")
    }
    guard args.contains("--cuda-memory-telemetry") else {
      fail(
        "explicit memory_admission_percent requires --cuda-memory-telemetry for stage-boundary reserve checks",
      )
    }
  }
  if capacity_profile == @capacity.Paper4096 &&
    !(args.length() >= 2 && ["evaluate", "export"].contains(args[1])) {
    guard checkpoint_format(args) == StreamV2 else {
      fail("paper-4096 capacity requires --checkpoint-format stream-v2")
    }
  }
  let distributed = distributed_settings(config, args)
  guard setting(config, "precision", "float32") == "float32" else {
    fail(
      "native tensor CLI requires FP32 master parameters; amp may be none or bf16",
    )
  }
  guard setting(config, "reference_storage", "mmap") == "mmap" else {
    fail(
      "native tensor CLI requires bounded mmap-compatible fixed-window motion storage",
    )
  }
  let backend : String = setting(config, "backend", "isaac")
  guard backend == "isaac" || backend == "mujoco" else {
    fail("physics backend must be isaac or mujoco")
  }
  guard backend != "isaac" || setting(config, "randomization", true) else {
    fail(
      "native Newton protocol currently requires domain randomization; select MuJoCo for randomization=false",
    )
  }
  let device : String = setting(config, "device", "cuda:0")
  let device_id = if device == "cpu" {
    -1
  } else if device.has_prefix("cuda:") {
    let index = @string.parse_int(device[5:])
    guard index >= 0 else { fail("CUDA device index must be nonnegative") }
    index
  } else {
    fail("device must be cpu or cuda:N")
  }
  guard device_id >= -1 && (device != "cpu" || backend == "mujoco") else {
    fail("CPU smoke profile requires MuJoCo")
  }
  guard capacity_profile != @capacity.Paper4096 ||
    (backend == "isaac" && device_id >= 0) else {
    fail("paper-4096 phase admission currently requires Isaac/APIC on CUDA")
  }
  guard distributed is None || device_id >= 0 else {
    fail("native distributed training requires CUDA on every rank")
  }
  guard backend != "isaac" ||
    setting(config, "physics_device_id", device_id) == device_id else {
    fail(
      "native preflight requires learner and Newton physics on the same CUDA device",
    )
  }
  let mode = match setting(config, "observation_mode", "paper") {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("unsupported observation mode")
  }
  let c = learner_config(config)
  let n : Int32 = setting(config, "num_envs", 128)
  let replay_steps : Int32 = setting(config, "buffer_steps", 128)
  ignore(
    capacity_profile.validate_dimensions(
      environments=n,
      world_batch=c.wm_batch,
      policy_batch=c.policy_batch,
      replay_steps~,
    ),
  )
  let batch_execution : @gpu.BatchExecutionPlan = {
    world_microbatch: setting(config, "wm_microbatch", 0),
    actor_microbatch: setting(config, "pi_microbatch", 0),
  }
  guard batch_execution.world_microbatch >= 0 &&
    batch_execution.world_microbatch <= c.wm_batch &&
    batch_execution.actor_microbatch >= 0 &&
    batch_execution.actor_microbatch <= c.policy_batch else {
    fail("microbatch sizes must be zero or within the unchanged logical batch")
  }
  guard replay_steps >= c.wm_window &&
    replay_steps <= capacity.max_replay_steps &&
    c.hist > 0 &&
    c.hist <= 10 &&
    c.goal_frames > 0 &&
    c.goal_frames <= 10 &&
    c.horizon > 0 &&
    c.horizon <= 32 &&
    c.wm_window > 0 &&
    c.wm_window <= 8 &&
    c.wm_batches > 0 &&
    c.critic_epochs > 0 &&
    c.critic_minibatches > 0 else {
    fail("native initial-profile history/horizon/replay limits exceeded")
  }
  guard c.wm_hidden.length() <= 3 &&
    c.policy_hidden.length() <= 4 &&
    c.critic_hidden.length() <= 4 &&
    c.wm_hidden.all(x => x > 0 && x <= 2048) &&
    c.policy_hidden.all(x => x > 0 && x <= 2048) &&
    c.critic_hidden.all(x => x > 0 && x <= 1024) else {
    fail("network widths exceed native initial memory envelope")
  }
  guard c.learning_rate > 0.0 &&
    c.learning_rate < 1.0 &&
    c.gamma > 0.0 &&
    c.gamma <= 1.0 &&
    c.lam >= 0.0 &&
    c.lam <= 1.0 else {
    fail("invalid learner rate or discount")
  }
  if device_id == -1 {
    guard n == 1 &&
      c.policy_batch <= 2 &&
      c.wm_batch <= 2 &&
      c.horizon <= 4 &&
      c.wm_window <= 2 &&
      c.wm_hidden.all(x => x <= 32) &&
      c.policy_hidden.all(x => x <= 32) &&
      c.critic_hidden.all(x => x <= 32) else {
      fail(
        "CPU execution is restricted to the tiny native runtime smoke profile",
      )
    }
  }
  let iterations : Int32 = match option(args, "--iterations") {
    Some(text) => @string.parse_int(text)
    None => setting(config, "iterations", 1)
  }
  let checkpoint_every : Int32 = setting(config, "checkpoint_every", 1)
  guard iterations >= 0 && checkpoint_every > 0 else {
    fail("invalid target iteration or checkpoint interval")
  }
  let limits : @runner.BatchLimits = {
    max_reference_frames: setting(
      config,
      "max_reference_gather_frames",
      capacity.max_reference_frames,
    ),
    max_tensor_values: capacity.max_tensor_values,
  }
  guard limits.max_reference_frames >= (c.horizon + 1) * c.policy_batch &&
    limits.max_reference_frames <= capacity.max_reference_frames else {
    fail(
      "reference gather limit must cover the horizon and stay within the explicit capacity profile",
    )
  }
  if world_staging_max_bytes is Some(max_bytes) {
    ignore(
      @runner.world_staging_usage(c.wm_batch, c.wm_window, max_bytes~, limits~),
    )
  }
  if noise_staging_max_bytes is Some(max_bytes) {
    ignore(
      @runner.noise_staging_usage(
        c.policy_batch,
        mode.dim(),
        max_bytes~,
        limits~,
      ),
    )
  }
  let options : @aligned.TrainingOptions = {
    iterations,
    warmup_steps: setting(config, "warmup_steps", 64),
    world_only_iterations: setting(config, "wm_only_iters", 500),
    update_to_data: setting(config, "utd", 0.4),
    learning_rate_decay_iterations: setting(config, "lr_decay_iters", 250000),
    action_noise: setting(config, "action_noise", 0.1),
  }
  if operator_diagnostics {
    guard device_id >= 0 &&
      capacity_profile == @capacity.Paper4096 &&
      memory_admission_percent == Some(80) &&
      args.contains("--cuda-memory-telemetry") &&
      distributed is None &&
      c.policy_batch == 4096 &&
      batch_execution.actor_microbatch == 512 &&
      c.horizon == 32 &&
      c.critic_epochs == 5 &&
      c.critic_minibatches == 4 &&
      options.world_only_iterations < 41 &&
      options.iterations >= 41 &&
      (!operator_diagnostic_only || options.iterations == 41) else {
      fail(
        "operator timeline requires fresh CUDA paper-4096, 80% admission, telemetry, 8x512 actor, H32, 20 critic updates; diagnose-operators requires exactly 41 iterations",
      )
    }
  }
  guard options.warmup_steps >= c.wm_window &&
    options.warmup_steps <= replay_steps &&
    options.update_to_data > 0.0 &&
    options.update_to_data <= 1.0 &&
    options.world_only_iterations >= 0 &&
    options.learning_rate_decay_iterations > 0 &&
    options.action_noise >= 0.0 &&
    options.action_noise <= 1.0 else {
    fail("invalid native runner warm-up or collection settings")
  }
  {
    verified_allocator_cap: None,
    capacity_profile,
    learner: c,
    batch_execution,
    optimizations,
    profile_max_spans,
    operator_diagnostics,
    operator_diagnostic_only,
    telemetry_max_samples,
    resident_reference_max_bytes,
    reference_fk_cache,
    world_staging_max_bytes,
    world_packed_replay,
    noise_staging_max_bytes,
    motion_sampler_bin_cap,
    mode,
    backend,
    device: device_id,
    environments: n,
    replay_steps,
    seed: setting(config, "seed", 1U),
    options,
    checkpoint_every,
    limits,
    distributed,
    memory_admission_percent,
    serial_optimizer_save_workspace,
  }
}

///|
async fn bounded_json(path : String, limit : Int64) -> Json {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size >= 0L && size <= limit && size <= 2147483647L else {
    fail("JSON exceeds bounded input size: " + path)
  }
  let data = file.read_exactly_at(size.to_int(), position=0L)
  guard file.size() == size else {
    fail("JSON input changed size while reading: " + path)
  }
  @json.parse(@utf8.decode(data))
}

///|
async fn file_hash(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let count = (size - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(count, position=offset))
    continue offset + count.to_int64()
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
/// Includes referenced MJCF/mesh assets rather than comparing only the small
/// top-level scene XML. Directory contents must stay immutable for the run.
/// Hash one file at a time with bounded buffers; never load the tree into RAM.
async fn scene_assets_hash(root : String) -> String {
  let pending = [""]
  let hash = @crypto.SHA256::new()
  let mut count = 0
  let mut bytes = 0L
  while !pending.is_empty() {
    let relative = pending.pop().unwrap()
    let path = if relative == "" { root } else { root + "/" + relative }
    match @fs.kind(path, follow_symlink=false) {
      Directory => {
        let names = @fs.readdir(path, sort=true)
        guard names.length() <= 8192 &&
          pending.length() + names.length() <= 8192 else {
          fail("scene asset tree exceeds bounded metadata limit")
        }
        for name in names.rev() {
          pending.push(
            if relative == "" {
              name
            } else {
              relative + "/" + name
            },
          )
        }
      }
      Regular => {
        count += 1
        let file = @fs.open(path, mode=ReadOnly)
        bytes += file.size()
        file.close()
        guard count <= 8192 && bytes <= 17179869184L else {
          fail(
            "scene asset tree exceeds 8192 files / 16 GiB; select only immutable robot assets with --scene-assets-root",
          )
        }
        hash.update(
          @utf8.encode(
            "\{relative.length()}:" + relative + ":" + file_hash(path) + "\n",
          ),
        )
      }
      _ =>
        fail("scene asset tree contains a symlink or unsupported file: " + path)
    }
  }
  guard count > 0 else { fail("scene asset tree is empty") }
  @crypto.bytes_to_hex_string(hash.finalize())
}
