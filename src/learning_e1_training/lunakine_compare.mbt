///|
/// Runs the same fixed raw observations through the saved LibTorch actor and
/// independent portable FP32 reference. No simulator or robot is initialized.
pub async fn compare_lunakine(
  actor_directory : String,
  tensor_library : String,
  bundle_directory : String,
  output : String,
) -> Json {
  let (actor, metadata) = load_actor(actor_directory, tensor_library)
  let spec : @portable.Spec = @json.from_json(
    @json.parse(
      @utf8.decode(@fs.read_file(bundle_directory + "/actor.json").binary()),
    ),
  )
  let parameters = @fs.read_file(bundle_directory + "/parameters.f32").binary()
  let reference = @portable.Reference::prepare(spec, parameters[:])
  guard spec.history_frames == metadata.spec.hist &&
    spec.observation_width == metadata.spec.mode().dim() &&
    spec.goal_width() == metadata.spec.goal_frames * 73 else {
    fail("portable and source actor input contracts differ")
  }
  let cases : Array[Json] = []
  let mut max_error = 0.0
  for sample in 0..<3 {
    let history = Array::makei(spec.history_frames, frame => {
      Array::makei(spec.observation_width, feature => {
        match sample {
          0 => 0.0
          1 => 0.1
          _ =>
            @math.sin(
              (frame * spec.observation_width + feature).to_double() * 0.01,
            ) *
            0.2
        }
      })
    })
    let goals = Array::makei(spec.goal_width(), i => {
      match sample {
        0 => 0.0
        1 => 0.2
        _ => @math.cos(i.to_double() * 0.02) * 0.1
      }
    })
    let flat : Array[Double] = []
    for row in history {
      flat.append(row)
    }
    let expected = actor.forward_embedded(history, goals)
    let actual = reference.run(flat[:], goals[:])
    guard actual.length() == expected.length() else {
      fail("portable action width differs")
    }
    let mut error = 0.0
    for i in 0..<actual.length() {
      error = @math.maximum(error, (actual[i] - expected[i]).abs())
    }
    max_error = @math.maximum(max_error, error)
    cases.push({
      "sample": Json(sample),
      "history": Json(history),
      "goals": Json(goals),
      "libtorch_actions": Json(expected),
      "reference_actions": Json(actual),
      "max_absolute_error": Json(error),
    })
  }
  let result : Json = {
    "format": "moonrobo.lunakine-comparison.v1",
    "source_actor": Json(actor_directory),
    "bundle": Json(bundle_directory),
    "max_absolute_error": Json(max_error),
    "tolerance": 0.0001,
    "passed": Json(max_error <= 0.0001),
    "cases": Json(cases),
  }
  @fs.write_file(
    output,
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  guard max_error <= 0.0001 else {
    fail("portable actor differs from LibTorch; inspect " + output)
  }
  result
}
