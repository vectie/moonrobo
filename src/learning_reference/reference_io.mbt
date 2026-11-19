///|
pub(all) struct ActorMetadata {
  architecture_and_weights : ReferenceActor
  kinematics : Json
  dt_s : Double
  provenance : Json
  critic_status : String
  physical_execution_allowed : Bool
} derive(ToJson, FromJson)

///|
/// Portable MoonBit JSON checkpoint; never interprets Torch pickle as JSON.
pub async fn save_reference_actor(
  path : String,
  actor : ReferenceActor,
  kinematics : Json,
  dt : Double,
  provenance : Json,
  critic_status~ : String = "not-trained",
) -> String {
  actor.validate()
  guard dt > 0.0 && actor.nu > 0 else {
    fail("invalid reference actor metadata")
  }
  let metadata : ActorMetadata = {
    architecture_and_weights: actor,
    kinematics,
    dt_s: dt,
    provenance,
    critic_status,
    physical_execution_allowed: false,
  }
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-actor.moonbit.v1",
    metadata.to_json(),
  )
  let parameters = actor.parameters()
  checkpoint.put("parameters", [parameters.length()], parameters)
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
pub async fn load_reference_actor(
  path : String,
  expected_sha256? : String,
) -> (ReferenceActor, ActorMetadata) {
  let bytes = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard @artifacts.sha256(bytes) == expected else {
      fail("reference actor checksum differs")
    }
  }
  if bytes.length() >= 2 && bytes[:2] == b"PK" {
    return reference_actor_from_torch(@artifacts.decode_torch_checkpoint(bytes))
  }
  let checkpoint = @artifacts.load_checkpoint(
    path,
    "moonrobo.g1-reference-actor.moonbit.v1",
    expected_sha256?,
  )
  let metadata : ActorMetadata = @json.from_json(checkpoint.metadata)
  metadata.architecture_and_weights.validate()
  guard !metadata.physical_execution_allowed && metadata.dt_s > 0.0 else {
    fail("invalid reference actor checkpoint metadata")
  }
  let parameters = checkpoint.tensor("parameters")
  guard parameters.values == metadata.architecture_and_weights.parameters() else {
    fail("actor weights and parameter tensor disagree")
  }
  (metadata.architecture_and_weights, metadata)
}

///|
pub(all) struct ReferenceArchive {
  metadata : Json
  layout : Json
  arrays : Map[String, @artifacts.NumericArray]
} derive(Debug)

///|
pub fn json_field(object : Json, name : String) -> Json raise {
  match object {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => fail("missing field " + name)
      }
    _ => fail("expected JSON object")
  }
}

///|
pub fn json_text(value : Json) -> String raise {
  match value {
    String(text) => text
    _ => fail("expected JSON string")
  }
}

///|
/// Reads the original manifest and numeric NPZ arrays directly, verifies every
/// SHA256, and rejects non-training clips before exposing initialization data.
pub async fn load_references(
  folder : String,
) -> (Json, Array[ReferenceArchive]) {
  let manifest = @json.parse(
    @utf8.decode(@fs.read_file(folder + "/manifest.json").binary()),
  )
  let clips = match json_field(manifest, "clips") {
    Array(clips) => clips
    _ => fail("manifest clips must be an array")
  }
  let layout = json_field(manifest, "layout")
  let references : Array[ReferenceArchive] = []
  for clip in clips {
    let file = json_text(json_field(clip, "file"))
    guard !file.has_prefix("/") && !file.split("/").any(part => part == "..") else {
      fail("reference path escapes folder")
    }
    let bytes = @fs.read_file(folder + "/" + file).binary()
    guard @artifacts.sha256(bytes) == json_text(json_field(clip, "sha256")) &&
      json_text(json_field(clip, "split")) == "train" else {
      fail("reference initialization accepts unchanged training clips only")
    }
    references.push({
      metadata: clip,
      layout,
      arrays: @artifacts.decode_npz(bytes),
    })
  }
  guard !references.is_empty() else { fail("empty reference manifest") }
  (manifest, references)
}

///|
pub fn ReferenceArchive::matrix(
  self : ReferenceArchive,
  name : String,
) -> Array[Array[Double]] raise {
  guard self.arrays.get(name) is Some(array) && array.shape.length() == 2 else {
    fail("expected reference matrix " + name)
  }
  let width = array.shape[1]
  Array::makei(array.shape[0], i => {
    array.values[i * width:(i + 1) * width].to_owned()
  })
}

///|
pub fn ReferenceArchive::goals(
  self : ReferenceArchive,
) -> Array[Array[Double]] raise {
  let state = self.matrix("state")
  guard self.arrays.get("body_position") is Some(positions) &&
    positions.shape.length() == 3 &&
    positions.shape[0] == state.length() &&
    positions.shape[2] == 3 else {
    fail("invalid body position archive")
  }
  guard self.arrays.get("body_rotation") is Some(rotations) &&
    rotations.shape.length() == 4 &&
    rotations.shape[0] == state.length() &&
    rotations.shape[1] == positions.shape[1] &&
    rotations.shape[2] == 3 &&
    rotations.shape[3] == 3 else {
    fail("invalid body rotation archive")
  }
  let nq = match json_field(self.layout, "nq") {
    Number(value, ..) => value.to_int()
    _ => fail("layout nq")
  }
  let indices = (name : String) => {
    match json_field(self.layout, name) {
      Array(values) =>
        values.map(value => {
          match value {
            Number(x, ..) => x.to_int()
            _ => fail("layout integer index")
          }
        })
      _ => fail("layout index array")
    }
  }
  let qi = indices("q_indices")
  let vi = indices("v_indices")
  let root = match json_field(self.layout, "root_body_index") {
    Number(value, ..) => value.to_int()
    _ => fail("layout root body index")
  }
  let bodies = positions.shape[1]
  Array::makei(state.length(), i => {
    let p = Array::makei(bodies, b => {
      positions.values[(i * bodies + b) * 3:(i * bodies + b + 1) * 3].to_owned()
    })
    let r = Array::makei(bodies, b => {
      rotations.values[(i * bodies + b) * 9:(i * bodies + b + 1) * 9].to_owned()
    })
    @balance.encode_goal(state[i], p, r, qi, vi, nq, root)
  })
}
