///|
/// A MuJoCo compilation artifact, not a constructed Newton/Warp solver model.
pub(all) struct ModelRequest {
  model_adapter : String
  mujoco_library : String
  source_mjcf : String
  output : String
} derive(FromJson, ToJson)

///|
/// Native USD extraction and first-party configuration only; no Newton model.
pub(all) struct SceneRequest {
  usd_adapter : String
  usd : String
  usd_variants : Map[String, String]
  num_envs : Int32
  self_collisions : Bool
  output : String
} derive(FromJson, ToJson)

///|
pub async fn prepare_scene(request : SceneRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("native scene output must be a fresh directory")
  }
  let receipt = @model.validate_usd(
    request.usd_adapter,
    request.usd,
    request.usd_variants,
  )
  let plan = @scene.g1_plan(receipt, request.num_envs, request.self_collisions)
  @fs.mkdir(request.output, recursive=true)
  @fs.write_file(
    request.output + "/usd-receipt.json",
    receipt.stringify(indent=2) + "\n",
    create_mode=CreateNew,
  )
  @fs.write_file(
    request.output + "/scene-plan.json",
    plan.to_json().stringify(indent=2) + "\n",
    create_mode=CreateNew,
  )
  plan.to_json()
}

///|
/// Explicit native preparation. Typechecking never opens these libraries.
pub async fn prepare_model(request : ModelRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("native model output must be a fresh directory")
  }
  let compiled = @model.prepare_model(
    request.model_adapter,
    request.mujoco_library,
    request.source_mjcf,
  )
  @fs.mkdir(request.output, recursive=true)
  @fs.write_file(
    request.output + "/source-model.mjb",
    compiled.mjb,
    create_mode=CreateNew,
  )
  // Receipt descriptor_sha256 binds these exact compact UTF-8 bytes.
  @fs.write_file(
    request.output + "/source-model.json",
    compiled.descriptor.stringify(),
    create_mode=CreateNew,
  )
  @fs.write_file(
    request.output + "/receipt.json",
    compiled.receipt.stringify(indent=2) + "\n",
    create_mode=CreateNew,
  )
  compiled.receipt
}
