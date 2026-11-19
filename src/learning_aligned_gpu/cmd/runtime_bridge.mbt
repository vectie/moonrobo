///|
struct ExecutionEnvironment {
  inspect_fn : () -> Array[@aligned.CollectorFrame] raise
  step_fn : (Array[Array[Double]]) -> Array[@aligned.Transition] raise
  snapshot_fn : () -> Json
  restore_fn : (Json) -> Bool raise
  close_fn : () -> Unit
  backend : String
  native_identity : Json
  sampler : @aligned.ReturnBinSampler
  checkpoint_source : EnvironmentCheckpointSource
}

///|
enum EnvironmentCheckpointSource {
  Mujoco(@tracking.Environment)
  Apic(@gpu_protocol.TrackingProtocol)
}

///|
struct StreamEnvironment {
  backend : String
  metadata : Json
} derive(ToJson, FromJson)

///|
fn StreamEnvironment::blobs(
  self : StreamEnvironment,
  profile~ : @capacity.CapacityProfile = @capacity.Initial,
) -> Array[@stream.BlobDescriptor] raise {
  let limits = profile.limits()
  match self.backend {
    "mujoco-cpu-native" => {
      let saved : @tracking.EnvironmentSnapshotV2 = @json.from_json(
        self.metadata,
      )
      guard saved.format == "moonrobo.aligned.mujoco-stream.v2" &&
        saved.num_envs > 0 &&
        saved.num_envs <= limits.max_environments &&
        saved.integration_width > 0 &&
        saved.num_envs.to_int64() * saved.integration_width.to_int64() <=
        16777216L else {
        fail("unsupported MuJoCo stream metadata")
      }
      validate_stream_sampler(saved.sampler)
      @aligned.checkpoint_blob(
        saved.physics,
        "environment.physics.f64le",
        "f64le",
        [saved.num_envs, saved.integration_width],
      )
      @aligned.checkpoint_blob(
        saved.values,
        "environment.values.f64le",
        "f64le",
        [saved.num_envs, 64],
      )
      @aligned.checkpoint_blob(
        saved.indices,
        "environment.indices.i32le",
        "i32le",
        [saved.num_envs, 3],
      )
      @aligned.checkpoint_blob(
        saved.initialized,
        "environment.initialized.u8",
        "u8",
        [saved.num_envs],
      )
      saved.blobs()
    }
    "isaac-newton-warp-apic-native" => {
      let saved : @gpu_protocol.ProtocolSnapshotV2 = @json.from_json(
        self.metadata,
      )
      guard saved.format == "moonrobo.aligned.isaac-warm-stream.v2" &&
        saved.num_envs > 0 &&
        saved.num_envs <= limits.max_environments &&
        !saved.exact_resume &&
        saved.replay_refill_required else {
        fail("unsupported APIC stream warm-state metadata")
      }
      validate_stream_sampler(saved.sampler)
      @aligned.checkpoint_blob(saved.xi, "environment.xi.f64le", "f64le", [
        saved.num_envs,
        33,
      ])
      saved.blobs()
    }
    _ => fail("unsupported stream checkpoint physical backend")
  }
}

///|
fn validate_stream_sampler(saved : @aligned.SamplerCheckpointV2) -> Unit raise {
  guard saved.format == "moonrobo.return-sampler-stream.v2" && saved.bins > 0 else {
    fail("unsupported sampler stream metadata")
  }
  @aligned.checkpoint_blob(saved.returns, "sampler.returns.f64le", "f64le", [
    saved.bins,
  ])
  @aligned.checkpoint_blob(saved.average, "sampler.average.f64le", "f64le", [
    saved.bins,
  ])
  @aligned.checkpoint_blob(
    saved.completed,
    "sampler.completed.i32le",
    "i32le",
    [saved.bins],
  )
}

///|
async fn ExecutionEnvironment::write_stream(
  self : ExecutionEnvironment,
  directory : String,
) -> StreamEnvironment {
  let metadata = match self.checkpoint_source {
    Mujoco(physical) => Json(physical.write_snapshot_v2(directory))
    Apic(physical) => Json(physical.write_snapshot_v2(directory))
  }
  { backend: self.backend, metadata, }
}

///|
async fn ExecutionEnvironment::restore_stream(
  self : ExecutionEnvironment,
  directory : String,
  saved : StreamEnvironment,
) -> Bool {
  guard saved.backend == self.backend else {
    fail("stream checkpoint physical backend differs")
  }
  match self.checkpoint_source {
    Mujoco(physical) =>
      physical.restore_v2(directory, @json.from_json(saved.metadata))
    Apic(physical) => {
      ignore(physical.restore_v2(directory, @json.from_json(saved.metadata)))
      false
    }
  }
}

///|
async fn execution_environment(
  args : Array[String],
  config : Json,
  library : String,
  scene : String,
  prototype : @sim.Runtime,
  kin : @aligned.Kinematics,
  motion : @aligned.MotionLibrary,
  s : Settings,
  scene_sha256 : String,
  physical_seed : UInt32,
  expected_artifact_sha256 : String,
) -> ExecutionEnvironment {
  let physics : @tracking.EnvironmentConfig = {
    gamma: s.learner.gamma,
    eval_mode: false,
    auto_reset: true,
    self_collisions: setting(config, "self_collisions", true),
    randomization: setting(config, "randomization", true),
    reset_noise: setting(config, "reset_noise", true),
    max_episode_steps: setting(config, "max_episode_steps", 500),
    physics_dt: setting(config, "physics_dt", 0.005),
    context_resampling: setting(config, "context_resampling", "episode"),
  }
  if s.backend == "mujoco" {
    let runtimes = [prototype]
    for _ in 1..<s.environments {
      runtimes.push(
        @sim.Runtime::open(library, scene, require_position_servos=false),
      )
    }
    let physical = @tracking.Environment::new(
      runtimes,
      motion,
      config=physics,
      seed=physical_seed,
    )
    return {
      inspect_fn: () => physical.inspect(),
      step_fn: actions => physical.step(actions),
      snapshot_fn: () => Json(physical.snapshot()),
      restore_fn: saved => physical.restore(@json.from_json(saved)),
      close_fn: () => (),
      backend: "mujoco-cpu-native",
      native_identity: Json::null(),
      sampler: physical.sampler,
      checkpoint_source: Mujoco(physical),
    }
  }
  let native = @gpu_native.load(
    required(args, "--physics-library"),
    required(args, "--physics-artifact"),
    scene_sha256,
    self_collisions=physics.self_collisions,
    device_id=setting(config, "physics_device_id", s.device),
    expected_manifest_sha256=expected_artifact_sha256,
    capacity_profile=s.capacity_profile,
  )
  errdefer native.close()
  let adapter = native.adapter()
  guard adapter.num_envs == s.environments else {
    fail("num_envs differs from fixed Newton artifact world count")
  }
  let physical = @gpu_protocol.TrackingProtocol::new(
    adapter,
    kin,
    motion,
    {
      asset_path: scene,
      asset_sha256: scene_sha256,
      gamma: physics.gamma,
      self_collisions: physics.self_collisions,
      reset_noise: physics.reset_noise,
      max_episode_steps: physics.max_episode_steps,
      context_resampling: physics.context_resampling,
      physics_dt: physics.physics_dt,
    },
    eval_mode=false,
    seed=physical_seed,
    reuse_pre_step_state=setting(config, "reuse_pre_step_state", false),
  )
  {
    inspect_fn: () => physical.inspect(),
    step_fn: actions => physical.step(actions).transitions,
    snapshot_fn: () => Json(physical.snapshot()),
    restore_fn: saved => {
      ignore(physical.restore(@json.from_json(saved)))
      false
    },
    close_fn: () => native.close(),
    backend: "isaac-newton-warp-apic-native",
    native_identity: native.identity(),
    sampler: physical.sampler,
    checkpoint_source: Apic(physical),
  }
}
