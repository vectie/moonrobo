///|
struct EvaluationEnvironment {
  inspect_fn : () -> @aligned.CollectorFrame raise
  step_fn : (Array[Double]) -> @aligned.Transition raise
  reset_fn : (Int32) -> Unit raise
  close_fn : () -> Unit
  replicas : Int32
  physical_settings : Json
}

///|
async fn evaluation_environment(
  args : Array[String],
  config : Json,
  prototype : @sim.Runtime,
  kin : @aligned.Kinematics,
  motion : @aligned.MotionLibrary,
  s : Settings,
  scene_sha256 : String,
  expected_artifact_sha256 : String,
) -> EvaluationEnvironment {
  let physical : Json = {
    "backend": Json(s.backend),
    "control_dt_s": 0.02,
    "physics_dt_s": 0.005,
    "self_collisions": Json(setting(config, "self_collisions", true)),
    "auto_reset": false,
    "observation_noise": false,
    "action_noise": false,
    "domain_randomization": false,
    "reset_noise": false,
    "episode_time_limit_disabled": true,
    "measured_slot": 0,
    "replicas_receive_same_action": true,
  }
  if s.backend == "mujoco" {
    // Evaluation needs only one CPU simulator, independently of training batch.
    let env = @tracking.Environment::new(
      [prototype],
      motion,
      config={
        gamma: s.learner.gamma,
        eval_mode: true,
        auto_reset: false,
        self_collisions: setting(config, "self_collisions", true),
        randomization: false,
        reset_noise: false,
        max_episode_steps: 500,
        physics_dt: 0.005,
        context_resampling: "episode",
      },
      seed=s.seed,
    )
    return {
      inspect_fn: () => env.inspect()[0],
      step_fn: action => env.step([action])[0],
      reset_fn: frame => env.reset(frames=[frame]),
      close_fn: () => (),
      replicas: 1,
      physical_settings: physical,
    }
  }
  let native = @gpu_native.load(
    required(args, "--physics-library"),
    required(args, "--physics-artifact"),
    scene_sha256,
    self_collisions=setting(config, "self_collisions", true),
    device_id=s.device,
    expected_manifest_sha256=expected_artifact_sha256,
    capacity_profile=s.capacity_profile,
  )
  errdefer native.close()
  let adapter = native.adapter()
  guard adapter.num_envs == s.environments else {
    fail("evaluation artifact world count differs from checkpoint")
  }
  let env = @gpu_protocol.TrackingProtocol::new(
    adapter,
    kin,
    motion,
    {
      asset_path: required(args, "--scene"),
      asset_sha256: scene_sha256,
      gamma: s.learner.gamma,
      self_collisions: setting(config, "self_collisions", true),
      reset_noise: false,
      max_episode_steps: 500,
      context_resampling: "episode",
      physics_dt: 0.005,
    },
    eval_mode=true,
    seed=s.seed,
  )
  {
    inspect_fn: () => env.inspect()[0],
    step_fn: action => env.evaluation_step(action),
    reset_fn: frame => env.evaluation_reset(frame),
    close_fn: () => native.close(),
    replicas: adapter.num_envs,
    physical_settings: physical,
  }
}
