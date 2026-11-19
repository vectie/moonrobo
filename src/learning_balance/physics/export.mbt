///|
/// Recompute contact/geometry trace from recorded next_state, never stepping physics or re-running policy inference. Friction is restored from the episode context.
pub fn replay_from_recorded_states(
  runtime : @native_physics.Runtime,
  episode : @native_physics.Episode,
  dt : Double,
) -> Array[@native_physics.ReplayFrame] raise {
  guard !episode.context.is_empty() && dt > 0.0 else {
    fail("recorded replay needs friction context and cadence")
  }
  let (nq, _, _, _) = runtime.dimensions()
  runtime.set_friction(episode.context[0])
  episode.steps.map(fn(step) {
    runtime.set_state(step.next_state)
    {
      time_s: step.time_s + dt,
      qpos: Array::makei(nq, fn(i) { step.next_state[i] }),
      target: step.goal,
      root_height_m: runtime.root_height(),
      upright_z: runtime.upright(),
      contacts: runtime.contacts(),
    }
  })
}

///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing recorded export field: " + key)
  }
  result
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("recorded export array required") }
  items
}

///|
pub async fn export_evaluations(
  library : String,
  scene : String,
  source : String,
  expected_sha256 : String,
  dt : Double,
  output : String,
  short : Bool,
) -> Json {
  let raw = @fs.read_file(source).binary()
  guard @artifacts.sha256(raw) == expected_sha256 else {
    fail("recorded source archive SHA256 differs")
  }
  let replays : Map[String, Json] = {}
  if short {
    let runtime = @native_physics.Runtime::open(library, scene)
    let bytes = if source.has_suffix(".gz") {
      @artifacts.decompress(raw)
    } else {
      raw
    }
    for line in @utf8.decode(bytes).split("\n") {
      if line.trim_space().is_empty() {
        continue
      }
      let row = @json.parse(line)
      for raw_episode in array(field(field(row, "dataset"), "episodes")) {
        let episode : @native_physics.Episode = @json.from_json(raw_episode)
        replays[episode.id] = replay_from_recorded_states(runtime, episode, dt).to_json()
      }
    }
  }
  let evaluations = @balance.read_evaluations(
    raw,
    expected_sha256,
    source.has_suffix(".gz"),
    short,
    replays,
  )
  let rows : Array[Json] = []
  for (seed, mode), result in evaluations {
    rows.push({
      "seed": seed.to_json(),
      "mode": mode.to_json(),
      "evaluation": result,
    })
  }
  let report : Json = {
    "format": "moonrobo.moonbit-balance-evaluation-export.v1",
    "evaluations": rows.to_json(),
    "source_sha256": expected_sha256.to_json(),
    "physical_execution_allowed": false,
    "policy_rerun": false,
  }
  @fs.write_file(
    output,
    @utf8.encode(report.stringify()),
    create_mode=CreateOrTruncate,
  )
  report
}
