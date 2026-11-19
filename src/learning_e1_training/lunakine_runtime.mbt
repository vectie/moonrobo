///|
struct LunaKineRobot {
  format : String
  identity : Identity
  source_spec : @inference.ActorSpec
  physical_action_count : Int32
} derive(FromJson)

///|
async fn portable_metadata(
  directory : String,
) -> (@deployed.Bundle, LunaKineRobot) {
  let actor_json = @fs.read_file(directory + "/actor.json").json()
  let robot_json = @fs.read_file(directory + "/robot.json").json()
  let bundle = @deployed.Bundle::parse(actor_json, robot_json)
  let robot : LunaKineRobot = @json.from_json(robot_json)
  robot.source_spec.validate()
  (bundle, robot)
}

///|
/// Loads Ascend inference only; no LibTorch plugin or training graph is loaded.
pub async fn load_lunakine_actor(
  directory : String,
  library : String,
  model : String,
) -> Actor {
  let (bundle, robot) = portable_metadata(directory)
  let deployed = @deployed.Actor::open_ascend(bundle, library, model)
  {
    inner: None,
    robot: robot.identity.robot,
    spec: robot.source_spec,
    predict: (history, goals) => deployed.forward_embedded(history, goals),
    release: () => deployed.close(),
  }
}

///|
/// Explicit offline reference selection; never used as an Ascend fallback.
pub async fn load_portable_reference(directory : String) -> Actor {
  let (bundle, robot) = portable_metadata(directory)
  let parameters = @fs.read_file(directory + "/parameters.f32").binary()
  let deployed = @deployed.Actor::reference(bundle, parameters[:])
  {
    inner: None,
    robot: robot.identity.robot,
    spec: robot.source_spec,
    predict: (history, goals) => deployed.forward_embedded(history, goals),
    release: () => deployed.close(),
  }
}

///|
/// Same E1 full-clip evaluation protocol with an explicitly supplied actor.
/// Runtime selection is independent of LibTorch/CUDA training configuration.
pub async fn evaluate_deployed_actor(
  actor : Actor,
  dataset_directory : String,
  mujoco_library : String,
  output : String,
  backend~ : String,
  split~ : String = "validation",
  clip_indices~ : Array[Int32]? = None,
) -> Json {
  defer (actor.close() catch { _ => () })
  let dataset = open_dataset(dataset_directory)
  guard Json(dataset.robot) == Json(actor.robot) else {
    fail("actor and evaluation robot profiles differ")
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
  guard report is Object(fields) else { fail("invalid deployed actor report") }
  fields["inference_backend"] = Json(backend)
  fields["split"] = Json(split)
  @fs.write_file(
    output,
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateNew,
  )
  actor.close()
  report
}
