///|
/// End-to-end software service: task HTTP -> local reference -> selected actor
/// -> shadow record. Recording values are replayed under the live host clock;
/// their timestamps are not evidence of live telemetry freshness. No SDK loads.
pub async fn serve(policy : Policy, input : String, bind : String) -> Unit {
  let tape : ActorReplay = @json.from_json(@fs.read_file(input).json())
  guard tape.format == "moonrobo.actor-replay.v1" else {
    fail("shadow service requires an SMC replay tape")
  }
  let supervisor = @skills.Supervisor::new(
    tape.catalog.catalog_id,
    tape.catalog.skills,
  )
  for skill in tape.catalog.skills {
    guard skill.parameters.is_empty() &&
      tape.frames.get(skill.reference_id) is Some(frames) &&
      !frames.is_empty() else {
      fail("shadow skills require recorded frames and no parameter transforms")
    }
    for frame in frames {
      guard frame.observation.length() == 99 &&
        frame.goals.length() == policy.goal_width &&
        frame.observation.all(finite) &&
        frame.goals.all(finite) else {
        fail("invalid recorded actor features")
      }
    }
  }
  let clock = () => @env.now().reinterpret_as_int64()
  let host = @host.Host::new(supervisor, clock~, prepare=(supervisor, clock) => {
    @runner.Runner::new(
      supervisor,
      clock~,
      history_frames=policy.history_frames,
      observation_width=99,
      goal_width=policy.goal_width,
      action_width=29,
      predict=policy.predict,
      reference=(execution, step, previous, now) => {
        guard tape.frames.get(execution.reference_id) is Some(frames) else {
          fail("unknown shadow reference")
        }
        let complete = step == frames.length()
        let frame = frames[if complete { step - 1 } else { step }]
        let observation = frame.observation.copy()
        for j in 0..<29 {
          observation[64 + j] = previous[j]
        }
        { observation, goals: frame.goals, captured_at_ms: now, complete, }
      },
      sink=actions => {
        let row : Json = {
          "format": "moonrobo.actor-shadow-tick.v1",
          "published": false,
          "actions": Json(actions[:policy.physical_actions].to_owned()),
        }
        println(row.stringify())
      },
      stop=() => println("{\"published\":false,\"shadow_stopped\":true}"),
    )
  })
  let server = @http.Server(@socket.Addr::parse(bind))
  defer server.close()
  println(
    "Actor shadow task service at \{server.addr}; recorded features, published=false",
  )
  host.serve(server)
}
