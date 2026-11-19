///|
struct Inputs {
  history : Array[Array[Double]]
  goals : Array[Double]
} derive(FromJson)

///|
async fn main {
  let args = @env.args()[1:]
  guard args is [command, directory, ..] else {
    fail(
      "usage: e1_actor inspect BUNDLE | inspect-reference BUNDLE REFERENCE_JSON | reference/shadow-reference/serve-shadow-reference BUNDLE INPUT DESTINATION | ascend/shadow-ascend/serve-shadow-ascend BUNDLE CANN_LIBRARY MODEL INPUT DESTINATION",
    )
  }
  let bundle = @actor.Bundle::read(directory)
  if args is ["inspect-reference", _, path] {
    let clip = @reference.Clip::read(bundle, path)
    let report : Json = {
      "profile_id": bundle.profile_id(),
      "reference_id": clip.reference_id(),
      "frames": clip.frame_count(),
      "duration_ms": Json(clip.duration_ms()),
      "control_dt_ms": 20,
      "published": false,
      "hardware_qualified": false,
    }
    println(report.stringify(indent=2))
    return
  }
  if args is ["inspect", _] {
    let report : Json = {
      "profile_id": bundle.profile_id(),
      "joints": Json(bundle.joints()),
      "history_frames": bundle.history_frames(),
      "observation_width": bundle.observation_width(),
      "goal_width": bundle.goal_width(),
      "published": false,
      "hardware_qualified": false,
    }
    println(report.stringify(indent=2))
    return
  }
  let (backend, input, output) = match args {
    [
      "reference"
      | "shadow-reference"
      | "serve-shadow-reference",
      _,
      input,
      output,
    ] => {
      let parameters = @fs.read_file(directory + "/parameters.f32").binary()
      (@actor.Actor::reference(bundle, parameters[:]), input, output)
    }
    [
      "ascend"
      | "shadow-ascend"
      | "serve-shadow-ascend",
      _,
      library,
      model,
      input,
      output,
    ] => (@actor.Actor::open_ascend(bundle, library, model), input, output)
    _ => fail("invalid deployment-only actor command")
  }
  defer (backend.close() catch { _ => () })
  if command == "serve-shadow-reference" || command == "serve-shadow-ascend" {
    @shadow.serve(@shadow.Policy::from_actor(backend), input, output)
    return
  }
  if command == "shadow-reference" || command == "shadow-ascend" {
    ignore(
      @shadow.replay_file(@shadow.Policy::from_actor(backend), input, output),
    )
    backend.close()
    return
  }
  let inputs : Inputs = @json.from_json(@fs.read_file(input).json())
  let actions = backend.forward_embedded(inputs.history, inputs.goals)
  let result : Json = {
    "backend": command,
    "profile_id": bundle.profile_id(),
    "joints": Json(bundle.joints()),
    "actions": Json(actions),
    "nominal_setpoints": Json(bundle.nominal_setpoints(actions[:])),
    "published": false,
    "hardware_qualified": false,
  }
  @fs.write_file(output, result.stringify(indent=2), create_mode=CreateNew)
  backend.close()
}
