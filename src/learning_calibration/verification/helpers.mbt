///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing PPO verification field: " + name)
  }
  result
}

///|
fn optional(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn integer(value : Json, name : String) -> Int32 raise {
  @json.from_json(field(value, name))
}

///|
fn number(value : Json, name : String) -> Double raise {
  let result : Double = @json.from_json(field(value, name))
  guard @numeric.finite(result) else {
    fail("nonfinite verification field: " + name)
  }
  result
}

///|
fn text(value : Json, name : String) -> String raise {
  @json.from_json(field(value, name))
}

///|
fn array(value : Json, name : String) -> Array[Json] raise {
  @json.from_json(field(value, name))
}

///|
fn vector(value : Json, name : String, legacy : Bool) -> Array[Double] raise {
  let row : Array[Double] = @json.from_json(field(value, name))
  finite_row(row, legacy)
}

///|
fn matrix(
  value : Json,
  name : String,
  legacy : Bool,
) -> Array[Array[Double]] raise {
  let rows : Array[Array[Double]] = @json.from_json(field(value, name))
  rows.map(row => finite_row(row, legacy))
}

///|
async fn load_actor(
  incoming : String,
  seed : Int32,
) -> (@temporal.TemporalPolicy, Json, Bool) {
  let basename = incoming + "/actor-seed-" + seed.to_string()
  let mut path : String? = None
  for candidate in actor_candidates(basename) {
    if @fs.exists(candidate) {
      path = Some(candidate)
      break
    }
  }
  guard path is Some(path) else {
    fail("incoming actor checkpoint not found for seed " + seed.to_string())
  }
  let bytes = @fs.read_file(path).binary()
  if bytes.length() >= 4 && bytes[0:4] == b"PK\x03\x04" {
    let payload = @artifacts.decode_torch_checkpoint(bytes)
    let actor = @temporal.temporal_from_torch_payload(payload)
    let model_ref = payload.field("model_ref").plain_json()
    (actor, model_ref, true)
  } else {
    let checkpoint = @artifacts.load_checkpoint(path, "temporal-actor")
    (
      @temporal.temporal_from_checkpoint(checkpoint),
      required_model_ref(checkpoint.metadata),
      false,
    )
  }
}

///|
fn actor_candidates(basename : String) -> Array[String] {
  [
    basename + ".moon.json",
    basename + ".pt",
    basename + ".json",
    basename + ".actor.json",
  ]
}

///|
/// Original temporal payloads require model_ref. A missing native ancestry
/// field cannot turn the physical model identity audit into an optional check.
fn required_model_ref(metadata : Json) -> Json raise {
  let model_ref = field(metadata, "model_ref")
  guard model_ref is String(identity) && !identity.is_empty() else {
    fail("incoming actor has no explicit physical model identity")
  }
  model_ref
}

///|
fn cast_episode(episode : @sim.Episode, legacy : Bool) -> @sim.Episode raise {
  let steps = episode.steps.map(s => {
    ..s,
    state: finite_row(s.state, legacy),
    observation: finite_row(s.observation, legacy),
    applied_action: finite_row(s.applied_action, legacy),
    next_state: finite_row(s.next_state, legacy),
    goal: finite_row(s.goal, legacy),
  })
  { ..episode, steps, context: finite_row(episode.context, legacy), }
}
