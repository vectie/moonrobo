///|
/// Converts an existing E1 actor export to a framework-independent LunaKine
/// bundle and static ONNX graph. LibTorch is needed only during this conversion.
pub async fn export_lunakine(
  actor_directory : String,
  tensor_library : String,
  output : String,
) -> Json {
  guard !@fs.exists(output) else {
    fail("LunaKine export requires a fresh directory")
  }
  let (actor, metadata) = load_actor(actor_directory, tensor_library)
  guard metadata.spec.mlp_precision.unwrap_or(@gpu.Fp32) == @gpu.Fp32 else {
    fail(
      "LunaKine v1 export requires FP32 actor compute; BF16 casts need a separate graph contract",
    )
  }
  let original = metadata.spec
  guard actor.inner is Some(native) else {
    fail("portable export requires the source LibTorch actor")
  }
  let observation_width = original.mode().dim()
  let encoder = [original.goal_frames * 73]
  encoder.append(original.hidden)
  encoder.push(32)
  let decoder = [32 + original.hist * observation_width]
  decoder.append(original.hidden)
  decoder.push(29)
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: original.hist,
    observation_width,
    encoder,
    decoder,
    observation_norm: {
      mean: original.obs_norm.mean,
      variance: original.obs_norm.variance,
      epsilon: 0.01,
    },
    goal_norm: {
      mean: original.goal_norm.mean,
      variance: original.goal_norm.variance,
      epsilon: 0.01,
    },
    action_mask: Array::makei(29, i => {
      if i < actor.robot.joints.length() {
        1.0
      } else {
        0.0
      }
    }),
  }
  spec.validate()
  let parameters = @buffer.Buffer()
  for i in 0..<native.parameter_count() {
    let values = native.parameter_values(i)
    parameters.write_bytes(@portable.encode_parameters(values[:])[:])
  }
  let blob = parameters.to_bytes()
  // The independent contract check also proves total blob size and FP32 values.
  ignore(@portable.decode_parameters(spec, blob[:]))
  let model = @onnx.encode(spec, blob[:])
  let robot : Json = {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": Json(metadata.identity),
    "contract": metadata.contract,
    "source_spec": Json(original),
    "physical_action_count": Json(actor.robot.joints.length()),
    "source_actor_directory": Json(actor_directory),
  }
  @fs.mkdir(output, recursive=true)
  @fs.write_file(
    output + "/actor.json",
    @utf8.encode(Json(spec).stringify(indent=2)),
    create_mode=CreateNew,
  )
  @fs.write_file(output + "/parameters.f32", blob, create_mode=CreateNew)
  @fs.write_file(output + "/actor.onnx", model, create_mode=CreateNew)
  @fs.write_file(
    output + "/robot.json",
    @utf8.encode(robot.stringify(indent=2)),
    create_mode=CreateNew,
  )
  {
    "backend": "lunakine",
    "bundle": Json(output),
    "parameters": Json(spec.parameter_count()),
    "input_history": Json([1, original.hist, observation_width]),
    "input_goals": Json([1, original.goal_frames * 73]),
    "output_actions": Json([1, 29]),
    "physical_actions": Json(actor.robot.joints.length()),
  }
}
