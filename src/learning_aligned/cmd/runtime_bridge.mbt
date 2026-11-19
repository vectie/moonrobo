///|
priv struct ExecutionEnvironment {
  inspect_fn : () -> Array[@aligned.CollectorFrame] raise
  step_fn : (Array[Array[Double]]) -> Array[@aligned.Transition] raise
  snapshot_fn : () -> Json
  restore_fn : (Json) -> Bool raise
  evaluation_reset_fn : (Int32) -> Unit raise
  evaluation_step_fn : (Array[Double]) -> @aligned.Transition raise
  close_fn : () -> Unit
  replicas : Int32
  backend : String
  native_identity : Json
}

///|
fn ExecutionEnvironment::inspect(
  self : ExecutionEnvironment,
) -> Array[@aligned.CollectorFrame] raise {
  (self.inspect_fn)()
}

///|
fn ExecutionEnvironment::step(
  self : ExecutionEnvironment,
  actions : Array[Array[Double]],
) -> Array[@aligned.Transition] raise {
  (self.step_fn)(actions)
}

///|
fn ExecutionEnvironment::snapshot(self : ExecutionEnvironment) -> Json {
  (self.snapshot_fn)()
}

///|
fn ExecutionEnvironment::restore(
  self : ExecutionEnvironment,
  saved : Json,
) -> Bool raise {
  (self.restore_fn)(saved)
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
  settings : @tracking.EnvironmentConfig,
  seed : UInt32,
  n : Int32,
) -> ExecutionEnvironment {
  if setting(config, "backend", "mujoco") == "mujoco" {
    let runtimes = [prototype]
    for _ in 1..<n {
      runtimes.push(
        @sim.Runtime::open(library, scene, require_position_servos=false),
      )
    }
    let physical = @tracking.Environment::new(
      runtimes,
      motion,
      config=settings,
      seed~,
    )
    return {
      inspect_fn: () => physical.inspect(),
      step_fn: actions => physical.step(actions),
      snapshot_fn: () => physical.snapshot().to_json(),
      restore_fn: saved => physical.restore(@json.from_json(saved)),
      evaluation_reset_fn: frame => physical.reset(ids=[0], frames=[frame]),
      evaluation_step_fn: action => physical.step([action])[0],
      close_fn: () => (),
      replicas: n,
      backend: "mujoco-cpu-native",
      native_identity: Json::null(),
    }
  }
  let native = @gpu_native.load(
    required(args, "--physics-library"),
    required(args, "--physics-artifact"),
    @artifacts.sha256(@fs.read_file(scene).binary()),
    self_collisions=settings.self_collisions,
    device_id=setting(config, "physics_device_id", 0),
  )
  errdefer native.close()
  let adapter = native.adapter()
  guard adapter.num_envs == n else {
    fail("num_envs differs from the fixed Newton artifact world count")
  }
  let physical = @gpu_protocol.TrackingProtocol::new(
    adapter,
    kin,
    motion,
    {
      asset_path: scene,
      asset_sha256: @artifacts.sha256(@fs.read_file(scene).binary()),
      gamma: settings.gamma,
      self_collisions: settings.self_collisions,
      reset_noise: settings.reset_noise,
      max_episode_steps: settings.max_episode_steps,
      context_resampling: settings.context_resampling,
      physics_dt: settings.physics_dt,
    },
    eval_mode=settings.eval_mode,
    seed~,
  )
  {
    inspect_fn: () => physical.inspect(),
    step_fn: actions => physical.step(actions).transitions,
    snapshot_fn: () => physical.snapshot().to_json(),
    restore_fn: saved => {
      ignore(physical.restore(@json.from_json(saved)))
      false
    },
    evaluation_reset_fn: frame => physical.evaluation_reset(frame),
    evaluation_step_fn: action => physical.evaluation_step(action),
    close_fn: () => native.close(),
    replicas: n,
    backend: "isaac-newton-warp-apic-native",
    native_identity: native.identity(),
  }
}
