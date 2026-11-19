///|
/// Recorded, calibrated actor features in training order. The SDK adapter owns
/// raw motor/IMU mapping; this file never loads an SDK or sends a motor command.
pub(all) struct ActorReplayFrame {
  captured_at_ms : Int64
  observation : Array[Double]
  goals : Array[Double]
} derive(ToJson, FromJson)

///|
pub extend ActorReplayFrame with ToJson::{to_json}

///|
pub extend ActorReplayFrame with @json.FromJson::{from_json}

///|
pub(all) struct ActorReplay {
  format : String
  catalog : @skills.Catalog
  request : @skills.Request
  frames : Map[String, Array[ActorReplayFrame]]
} derive(ToJson, FromJson)

///|
pub extend ActorReplay with ToJson::{to_json}

///|
pub extend ActorReplay with @json.FromJson::{from_json}

///|
/// Real actor path with a recording sink. Its report separates reference
/// completion from robot/task success; previous-action features come from this
/// runner's outputs rather than the recording's previous policy.
pub fn replay(policy : Policy, tape : ActorReplay) -> Json raise {
  guard tape.format == "moonrobo.actor-replay.v1" else {
    fail("shadow replay requires v1 tape and the 99-feature SMC actor")
  }
  let supervisor = @skills.Supervisor::new(
    tape.catalog.catalog_id,
    tape.catalog.skills,
  )
  guard tape.catalog.context_version == 0L && tape.catalog.last_sequence == -1L else {
    fail("replay starts with a fresh local catalog")
  }
  guard tape.catalog.skills.search_by(skill => {
      skill.id == tape.request.proposal.skill_id
    })
    is Some(index) else {
    fail("replay request has no catalog skill")
  }
  let skill = tape.catalog.skills[index]
  guard skill.parameters.is_empty() &&
    tape.frames.get(skill.reference_id) is Some(frames) &&
    !frames.is_empty() else {
    fail(
      "recorded references need frames and do not accept parameter transforms",
    )
  }
  for i, frame in frames {
    guard frame.observation.length() == 99 &&
      frame.goals.length() == policy.goal_width &&
      frame.observation.all(finite) &&
      frame.goals.all(finite) &&
      frame.captured_at_ms == frames[0].captured_at_ms + i.to_int64() * 20L else {
      fail("replay expects finite calibrated SMC frames at 50 Hz")
    }
  }
  let outputs : Array[Json] = []
  let stops = Ref(0)
  let replay_clock = Ref(frames[0].captured_at_ms)
  let runner = @runner.Runner::new(
    supervisor,
    clock=() => replay_clock.val,
    history_frames=policy.history_frames,
    observation_width=99,
    goal_width=policy.goal_width,
    action_width=29,
    predict=policy.predict,
    reference=(execution, step, previous, _) => {
      guard execution.reference_id == skill.reference_id else {
        fail("unexpected reference")
      }
      let complete = step == frames.length()
      let frame = frames[if complete { step - 1 } else { step }]
      let observation = frame.observation.copy()
      for j in 0..<29 {
        observation[64 + j] = previous[j]
      }
      {
        observation,
        goals: frame.goals,
        captured_at_ms: frame.captured_at_ms + (if complete { 20L } else { 0L }),
        complete,
      }
    },
    sink=actions => {
      let q = (policy.nominal_setpoints)(actions[:])
      guard q.length() == policy.physical_actions && q.all(finite) else {
        fail("shadow nominal positions differ from the physical profile")
      }
      outputs.push({
        "step": Json(outputs.length()),
        "actions": Json(actions[:policy.physical_actions].to_owned()),
        "nominal_setpoints": Json(q),
      })
    },
    stop=() => stops.val += 1,
  )
  ignore(supervisor.accept(tape.request, frames[0].captured_at_ms))
  for i in 0..<=frames.length() {
    replay_clock.val = frames[0].captured_at_ms + i.to_int64() * 20L
    ignore(runner.tick())
  }
  {
    "format": "moonrobo.actor-shadow-report.v1",
    "published": false,
    "scope": "recorded features and real actor; reference completion is not physical task success",
    "execution": match
      supervisor.snapshot(frames[frames.length() - 1].captured_at_ms + 20L) {
      Some(e) => Json(e)
      None => Json::null()
    },
    "stop_count": Json(stops.val),
    "frames": Json(outputs),
  }
}

///|
pub async fn replay_file(
  policy : Policy,
  input : String,
  output : String,
) -> Json {
  let tape : ActorReplay = @json.from_json(@fs.read_file(input).json())
  let report = replay(policy, tape)
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
  report
}
