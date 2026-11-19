///|
pub fn ReferenceActor::parameter_names(_self : ReferenceActor) -> Array[String] {
  let names : Array[String] = []
  for
    (prefix, layers) in [
      ("goal_encoder", [0, 2, 4]),
      ("observation_encoder", [0, 2]),
      ("decoder", [0, 2]),
    ] {
    for layer in layers {
      names.push("\{prefix}.\{layer}.weight")
      names.push("\{prefix}.\{layer}.bias")
    }
  }
  names
}

///|
pub async fn load_parameter_direction(
  path : String,
  expected_sha256 : String,
  actor : ReferenceActor,
  base_actor_sha256 : String,
) -> Array[Double] {
  let raw = @fs.read_file(path).binary()
  guard @artifacts.sha256(raw) == expected_sha256 else {
    fail("saved parameter direction changed")
  }
  let (direction, metadata) = if raw.length() >= 2 && raw[:2] == b"PK" {
    let data = @artifacts.decode_torch_checkpoint(raw)
    (torch_vector(data.field("direction")), data.plain_json())
  } else {
    let data = @artifacts.load_checkpoint(
      path, "moonrobo.g1-reference-parameter-direction.moonbit.v1",
    )
    (data.tensor("direction").values, data.metadata)
  }
  guard json_text(json_field(metadata, "base_actor_sha256")) ==
    base_actor_sha256 else {
    fail("parameter direction refers to another base actor")
  }
  let names : Array[String] = @json.from_json(
    json_field(metadata, "parameter_names"),
  )
  guard names == actor.parameter_names() &&
    direction.length() == actor.parameters().length() else {
    fail("parameter direction names or shape differ")
  }
  direction
}

///|
pub async fn load_behavior_actor(
  folder : String,
  behavior : Json,
) -> ReferenceActor {
  let hash = json_text(json_field(behavior, "sha256"))
  let (actor, _) = load_reference_actor(
    path_child(folder, json_text(json_field(behavior, "checkpoint"))),
    expected_sha256=hash,
  )
  let fields = json_fields(behavior)
  if fields.get("direction_file") is Some(file) {
    let direction = load_parameter_direction(
      path_child(folder, json_text(file)),
      json_text(json_field(behavior, "direction_sha256")),
      actor,
      hash,
    )
    let amount = json_number(json_field(behavior, "coefficient"))
    actor.set_parameters(
      actor.parameters().mapi((i, x) => x + amount * direction[i]),
    )
  }
  actor
}
