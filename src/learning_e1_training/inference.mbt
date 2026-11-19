///|
pub(all) struct ExportedActor {
  format : String
  identity : Identity
  spec : @inference.ActorSpec
  archive_sha256 : String
  source_checkpoint_sha256 : String
  contract : Json
} derive(ToJson, FromJson)

///|
/// Embodiment-aware frozen inference. Public actions contain only physical axes.
pub struct Actor {
  inner : @inference.Actor?
  robot : Profile
  spec : @inference.ActorSpec
  predict : (Array[Array[Double]], Array[Double]) -> Array[Double] raise
  release : () -> Unit raise
}

///|
pub fn Actor::forward_embedded(
  self : Actor,
  history : Array[Array[Double]],
  goal : Array[Double],
) -> Array[Double] raise {
  self.robot.project((self.predict)(history, goal))
}

///|
/// Releases an explicitly selected inference runtime. LibTorch actors retain
/// their existing tensor lifetime behavior; LunaKine sessions close natively.
pub fn Actor::close(self : Actor) -> Unit raise {
  (self.release)()
}

///|
pub fn Actor::forward(
  self : Actor,
  history : Array[Array[Double]],
  goal : Array[Double],
) -> Array[Double] raise {
  self.forward_embedded(history, goal)[:self.robot.joints.length()].to_owned()
}

///|
pub async fn export_actor(
  pointer : String,
  tensor_library : String,
  output : String,
) -> Json {
  guard !@fs.exists(output) else {
    fail("E1 actor export requires a fresh directory")
  }
  let (saved, directory) = open_checkpoint(pointer)
  let backend = @tensor.Backend::open(tensor_library)
  let spec = @inference.ActorSpec::from_checkpoint(saved.learner)
  let actor = @inference.Actor::load_archive(
    backend,
    directory + "/policy.pt",
    spec,
  )
  @fs.mkdir(output, recursive=true)
  actor.save_archive(output + "/actor.pt")
  let manifest : ExportedActor = {
    format: "moonrobo.e1-native-actor.v2",
    identity: saved.identity,
    spec,
    archive_sha256: hash_file(output + "/actor.pt"),
    source_checkpoint_sha256: hash_file(directory + "/checkpoint.json"),
    contract: saved.identity.robot.contract(),
  }
  @fs.write_file(
    output + "/actor.json",
    @utf8.encode(Json(manifest).stringify(indent=2)),
    create_mode=CreateNew,
  )
  Json(manifest)
}

///|
/// CPU native inference; output is explicitly projected to the E1 active prefix.
/// The archive is LibTorch/MoonBit, and is not advertised as ONNX/TorchScript.
pub async fn load_actor(
  output : String,
  tensor_library : String,
) -> (Actor, ExportedActor) {
  let metadata : ExportedActor = @json.from_json(
    @json.parse(@utf8.decode(read_bounded(output + "/actor.json", 1048576L))),
  )
  guard ["moonrobo.e1-native-actor.v1", "moonrobo.e1-native-actor.v2"].contains(
      metadata.format,
    ) &&
    metadata.contract ==
    metadata.identity.robot.sensor_contract(
      legacy=metadata.format == "moonrobo.e1-native-actor.v1",
    ) &&
    Json(metadata.identity.robot) ==
    Json(profile(joints=metadata.identity.robot.joints.length())) &&
    hash_file(output + "/actor.pt") == metadata.archive_sha256 else {
    fail("E1 actor identity or archive digest differs")
  }
  let actor = @inference.Actor::load_archive(
    @tensor.Backend::open(tensor_library),
    output + "/actor.pt",
    metadata.spec,
  )
  (
    {
      inner: Some(actor),
      robot: metadata.identity.robot,
      spec: metadata.spec,
      predict: (history, goals) => actor.forward(history, goals),
      release: () => (),
    },
    metadata,
  )
}

///|
pub async fn evaluate(
  actor_directory : String,
  dataset_directory : String,
  tensor_library : String,
  mujoco_library : String,
  output : String,
  split~ : String = "validation",
  clip_indices~ : Array[Int32]? = None,
  training_dataset? : String,
) -> Json {
  guard !@fs.exists(output) else {
    fail("E1 evaluation requires a fresh report path")
  }
  let dataset = open_dataset(dataset_directory)
  let (actor, metadata) = load_actor(actor_directory, tensor_library)
  let original = training_dataset.unwrap_or(dataset_directory)
  if metadata.identity.admission_sha256 is Some(expected) {
    guard hash_file(original + "/admission.json") == expected else {
      fail("E1 evaluation admission identity differs from training")
    }
    ignore(require_admission(dataset_directory, dataset, mujoco_library))
  }
  if training_dataset is Some(dir) {
    guard metadata.identity.admission_sha256 is Some(_) else {
      fail("benchmark requires admitted training data")
    }
    ignore(require_admission(dir, open_dataset(dir), mujoco_library))
  }
  guard metadata.identity.dataset_sha256 ==
    hash_file(original + "/dataset.json") &&
    Json(metadata.identity.robot) == Json(dataset.robot) &&
    metadata.identity.scene_receipt_sha256 ==
    hash_file(dataset_directory + "/scene.json") &&
    metadata.identity.tensor_library_sha256 == hash_file(tensor_library) &&
    metadata.identity.mujoco_library_sha256 == hash_file(mujoco_library) else {
    fail(
      "E1 evaluation robot/reference/physics/runtime identities differ from training",
    )
  }
  let rt = @sim.Runtime::open(mujoco_library, dataset_directory + "/scene.xml")
  let kin = @tracking.kinematics(
    rt,
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let motion = load_motion(dataset_directory, dataset, kin, split)
  let report = evaluate_motion(
    actor,
    rt,
    kin,
    dataset.robot,
    motion,
    split,
    clip_indices?,
  )
  guard report is Object(fields) else { fail("invalid evaluation report") }
  fields["actor_archive_sha256"] = Json(metadata.archive_sha256)
  fields["actor_metadata_sha256"] = Json(
    hash_file(actor_directory + "/actor.json"),
  )
  fields["tensor_library_sha256"] = Json(hash_file(tensor_library))
  fields["mujoco_library_sha256"] = Json(hash_file(mujoco_library))
  fields["split"] = Json(split)
  fields["evaluation_dataset_sha256"] = Json(
    hash_file(dataset_directory + "/dataset.json"),
  )
  fields["training_dataset_sha256"] = Json(metadata.identity.dataset_sha256)
  fields["generalization_scope"] = Json(
    if training_dataset is Some(_) {
      "external benchmark split; compare source recording identities with the actor training catalog"
    } else if split == "train" {
      "training motions"
    } else {
      "separate source files; subject/action independence not established"
    },
  )
  @fs.write_file(
    output,
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateNew,
  )
  report
}

///|
fn evaluate_motion(
  actor : Actor,
  rt : @sim.Runtime,
  kin : @aligned.Kinematics,
  robot : Profile,
  motion : @aligned.MotionLibrary,
  split : String,
  clip_indices? : Array[Int32],
  replay? : PanelReplay,
) -> Json raise {
  let physics = {
    ..@tracking.EnvironmentConfig::default(),
    eval_mode: true,
    auto_reset: false,
    randomization: false,
    reset_noise: false,
  }
  let env = Environment::new([rt], robot, motion, config=physics)
  let settings : @aligned.EvaluationSettings = {
    eval_mode: true,
    auto_reset: false,
    timeout_disabled: true,
    observation_noise: false,
    domain_randomization: false,
    simulated_replica_count: 1,
  }
  let result = @inference.evaluate_policy(
    actor.spec,
    (history, goals) => actor.forward_embedded(history, goals),
    motion,
    settings,
    frame => env.reset(frame~),
    () => env.inspect()[0],
    action => {
      let tr = env.step([robot.project(action)])[0]
      if replay is Some(writer) {
        writer.capture(tr, motion)
        writer.capture_workflow(tr, motion, kin, () => env.inspect()[0].state)
      }
      tr
    },
    clip_indices?,
    default_q=robot.embed(robot.default_q),
    strict_kin=kin,
    active_axes=robot.joints.length(),
  )
  result.report_json(motion.names, {
    "robot": Json(robot.id),
    "split": Json(split),
    "backend": "native-mujoco",
  })
}
