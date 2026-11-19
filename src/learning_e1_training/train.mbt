///|
pub async fn train(
  dataset_directory : String,
  tensor_library : String,
  mujoco_library : String,
  config : Config,
  output : String,
  iterations~ : Int32,
  device~ : Int32 = -1,
  resume~ : String? = None,
  initialize_from? : String,
  diagnostic~ : Bool = false,
  evaluate_every~ : Int32 = 500,
) -> Json {
  config.validate()
  guard initialize_from is None || resume is None else {
    fail("choose one checkpoint input")
  }
  guard iterations > 0 && (device == -1 || device >= 0) else {
    fail("positive E1 iterations and valid device required")
  }
  let dataset = open_dataset(dataset_directory)
  guard evaluate_every > 0 && evaluate_every % config.checkpoint_every == 0 else {
    fail("evaluation cadence must be a positive checkpoint multiple")
  }
  let qualification = if diagnostic {
    Json(())
  } else {
    let qualification = require_admission(
      dataset_directory, dataset, mujoco_library,
    )
    let fresh = config.environments.to_double() / config.update_to_data
    let windows = config.learner.wm_batches.to_double() *
      config.learner.wm_batch.to_double() /
      fresh
    let imagined = config.learner.policy_batch.to_double() *
      config.learner.horizon.to_double() /
      fresh
    let low_reuse = (windows - 2.0).abs() < 1.0e-8 &&
      (imagined - 12.8).abs() < 1.0e-8
    let g1_reuse = (windows - 32.0).abs() < 1.0e-8 &&
      (imagined - 204.8).abs() < 1.0e-8
    let locomotion = qualification
      is { "format": String("moonrobo.e1-locomotion-admission.v1"), .. }
    guard (low_reuse || (locomotion && g1_reuse)) &&
      config.learner.wm_window == 8 &&
      config.learner.horizon == 32 &&
      config.learning_rate_decay_iterations is Some(budget) &&
      (budget == iterations || (locomotion && budget >= iterations)) else {
      fail(
        "E1 sampling ratios or learning-rate budget do not match the admitted dataset profile",
      )
    }
    qualification
  }
  let identity : Identity = {
    training_revision: Some("e1-replay-pose-exact-grid-atlas-v2"),
    robot: dataset.robot,
    config,
    dataset_sha256: hash_file(dataset_directory + "/dataset.json"),
    scene_receipt_sha256: hash_file(dataset_directory + "/scene.json"),
    tensor_library_sha256: hash_file(tensor_library),
    mujoco_library_sha256: hash_file(mujoco_library),
    admission_sha256: if diagnostic {
      None
    } else {
      Some(hash_file(dataset_directory + "/admission.json"))
    },
  }
  if @fs.exists(output) {
    guard resume is Some(_) else { fail("existing E1 run requires --resume") }
  } else {
    @fs.mkdir(output, recursive=true)
  }
  let lock = @fs.open(
    output + "/run.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer lock.close()
  guard lock.try_lock(Exclusive) else {
    fail("another E1 trainer owns this run")
  }
  let backend = @tensor.Backend::open(tensor_library)
  if device >= 0 {
    guard backend.has_cuda_fp32_control() else {
      fail("E1 CUDA training requires IEEE precision control")
    }
    ignore(
      backend.configure_cuda_tf32(
        matmul=false,
        cudnn_conv=false,
        cudnn_rnn=false,
        before_first_tensor=true,
      ),
    )
  }
  let admission = admit_training(
    backend, config, dataset, dataset_directory, device,
  )
  let runtimes = Array::makei(config.environments, _ => {
    @sim.Runtime::open(mujoco_library, dataset_directory + "/scene.xml")
  })
  let kin = @tracking.kinematics(
    runtimes[0],
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let motion = load_motion(dataset_directory, dataset, kin, "train")
  let context = @geometry.Context::new(
    backend,
    kin,
    device,
    default_q=dataset.robot.embed(dataset.robot.default_q),
    active_joints=dataset.robot.joints.length(),
  )
  let optimizations = {
    ..@gpu.ExecutionOptimizations::default(),
    heading_mode: @geometry.OrthonormalAtlas,
    rotation_error_mode: @geometry.GeodesicSquared,
  }
  let learner = @gpu.Learner::new(
    backend,
    context,
    config=config.learner,
    mode=@aligned.Smc,
    cuda_device=device,
    seed=config.seed.to_uint(),
    world_microbatch=config.world_microbatch,
    actor_microbatch=config.actor_microbatch,
    optimizations~,
  )
  let runner = @runner.TrainingRunner::new(
    learner,
    motion,
    config.replay_steps,
    config.environments,
    seed=config.seed.to_uint(),
  )
  let physics = {
    ..@tracking.EnvironmentConfig::default(),
    randomization: config.randomization,
    reset_noise: config.reset_noise,
    max_episode_steps: config.max_episode_steps,
    gamma: config.learner.gamma,
  }
  let env = Environment::new(
    runtimes,
    dataset.robot,
    motion,
    config=physics,
    seed=config.seed.to_uint(),
    atlas_reward=optimizations.heading_mode == @geometry.OrthonormalAtlas,
  )
  if initialize_from is Some(pointer) {
    let (saved, directory) = open_checkpoint(pointer)
    guard Json(saved.identity.robot) == Json(identity.robot) &&
      saved.identity.scene_receipt_sha256 == identity.scene_receipt_sha256 &&
      saved.identity.tensor_library_sha256 == identity.tensor_library_sha256 &&
      saved.identity.mujoco_library_sha256 == identity.mujoco_library_sha256 &&
      saved.identity.admission_sha256 is Some(_) else {
      fail("warm-start embodiment/runtime differs")
    }
    let source_config = saved.learner.config
    let compatible = {
      ..source_config,
      wm_batch: config.learner.wm_batch,
      policy_batch: config.learner.policy_batch,
      learning_rate: config.learner.learning_rate,
    }
    guard Json(compatible) == Json(config.learner) &&
      compatible.learning_rate <= source_config.learning_rate else {
      fail(
        "warm start requires compatible learner settings and a non-increasing initial learning rate",
      )
    }
    learner.restore_metadata({ ..saved.learner, config: compatible, })
    learner.load_optimizers(directory)
    let receipt : Json = {
      "checkpoint_sha256": hash_file(directory + "/checkpoint.json"),
      "source_iteration": saved.runtime.iteration,
      "source_initial_learning_rate": source_config.learning_rate,
      "initial_learning_rate": compatible.learning_rate,
      "source_dataset_sha256": saved.identity.dataset_sha256,
      "target_dataset_sha256": identity.dataset_sha256,
      "restored": "parameters, Adam moments and normalizers",
      "fresh": "physical environments, replay, RNG and iteration schedule",
    }
    @fs.write_file(
      output + "/initialization.json",
      @utf8.encode(receipt.stringify(indent=2)),
      create_mode=CreateNew,
    )
  }
  if resume is Some(pointer) {
    let (saved, directory) = open_checkpoint(pointer)
    guard Json(saved.identity) == Json(identity) else {
      fail("E1 resume robot/data/physics/config/runtime identities differ")
    }
    learner.restore_metadata(saved.learner)
    learner.load_optimizers(directory)
    runner.restore_v2(directory, saved.runtime, false)
    env.sampler.restore(
      saved.sampler_returns,
      saved.sampler_average,
      saved.sampler_completed,
    )
    env.rng.set_state(saved.physical_rng)
    env.reset()
  }
  guard iterations > runner.iteration else {
    fail("E1 requested iteration must advance the checkpoint")
  }
  let mut checkpoint = ""
  let evaluations : Array[Json] = []
  while runner.iteration < iterations {
    let next = (runner.iteration + config.checkpoint_every).min(iterations)
    runner.run(
      config.options(next),
      () => env.inspect(),
      actions => env.step(actions),
      metrics => println(metrics.to_json().stringify()),
    )
    checkpoint = save_generation(output, identity, learner, runner, env)
    let physical = runner.counters.physical_transitions.to_double().max(1.0)
    let exposure : Json = {
      "iteration": runner.iteration,
      "training_exposure": Json(runner.counters),
      "actual_world_windows_per_physical_transition": runner.counters.model_fit_transition_slots.to_double() /
      config.learner.wm_window.to_double() /
      physical,
      "actual_imagined_steps_per_physical_transition": runner.counters.imagined_transitions.to_double() /
      physical,
      "scope": "cumulative including warm-up and actor-readiness collection; nominal ratios apply to steady state",
    }
    println(exposure.stringify())
    if !diagnostic &&
      (runner.iteration % evaluate_every == 0 || runner.iteration == iterations) {
      let directory = output + "/evaluation-" + runner.iteration.to_string()
      ignore(export_actor(checkpoint, tensor_library, directory + "/actor"))
      let train_result = evaluate(
        directory + "/actor",
        dataset_directory,
        tensor_library,
        mujoco_library,
        directory + "/train.json",
        split="train",
      )
      let validation_result = evaluate(
        directory + "/actor",
        dataset_directory,
        tensor_library,
        mujoco_library,
        directory + "/validation.json",
        split="validation",
      )
      let result : Json = {
        "iteration": runner.iteration,
        "train": train_result,
        "validation": validation_result,
      }
      evaluations.push(result)
      println(result.stringify())
    }
  }
  let report : Json = {
    "format": "moonrobo.e1-training-report.v1",
    "identity": Json(identity),
    "iteration": Json(runner.iteration),
    "counters": Json(runner.counters),
    "checkpoint": Json(checkpoint),
    "contract": dataset.robot.contract(),
    "physics": "native CPU MuJoCo; tensor learning on selected CPU/CUDA device; no G1 compiled BF16 bundle",
    "resume_kind": "warm-physical-reset-replay-refill",
  }
  guard report is Object(fields) else { fail("invalid E1 training report") }
  fields["learner_device"] = Json(device)
  fields["memory_admission"] = admission
  fields["dataset_qualification"] = qualification
  fields["diagnostic"] = Json(diagnostic)
  fields["full_motion_evaluations"] = Json(evaluations)
  if device >= 0 && backend.has_cuda_memory_telemetry() {
    fields["cuda_memory_after_training"] = Json(
      backend.cuda_memory_stats(device, synchronize=true),
    )
  }
  @fs.write_file(
    output + "/report.json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
  report
}
