///|
/// Bodies are addressed by stable model-local IDs; poses are absolute world
/// transforms, independent of the body hierarchy and the rendering library.
pub(all) struct Body {
  id : String
  name : String
  parent_id : String?
} derive(ToJson, Debug)

///|
pub impl @json.FromJson for Body with from_json(value, path) {
  guard value is Object(fields) &&
    value is { "id": String(id), "name": String(name), .. } else {
    raise @json.JsonDecodeError((path, "replay body requires string id and name"))
  }
  let parent_id = match fields.get("parent_id") {
    None | Some(Null) => None
    Some(String(parent)) => Some(parent)
    _ => raise @json.JsonDecodeError((path.add_key("parent_id"), "expected string or null"))
  }
  { id, name, parent_id }
}

///|
pub(all) struct Visual {
  id : String
  body_id : String
  geometry : Json
  local_position : Array[Double]
  local_quaternion_wxyz : Array[Double]
  rgba : Array[Double]
} derive(ToJson, @json.FromJson, Debug)

///|
pub(all) struct Model {
  id : String
  sha256 : String
  coordinate_system : String
  bodies : Array[Body]
  visuals : Array[Visual]
} derive(ToJson, @json.FromJson, Debug)

///|
pub(all) struct BodyPose {
  body_id : String
  position : Array[Double]
  quaternion_wxyz : Array[Double]
} derive(ToJson, @json.FromJson, Debug)

///|
/// This same frame payload can be sent by a future live MuJoCo session. Time is
/// elapsed seconds on the track clock, never wall-clock or reference phase.
pub(all) struct PoseFrame {
  time_s : Double
  bodies : Array[BodyPose]
} derive(ToJson, @json.FromJson, Debug)

///|
pub(all) struct Track {
  id : String
  kind : String
  label : String
  frames : Array[PoseFrame]
} derive(ToJson, @json.FromJson, Debug)

///|
pub(all) struct Clip {
  id : String
  label : String
  source_start_time_s : Double
  source : Json
  tracks : Array[Track]
} derive(ToJson, @json.FromJson, Debug)

///|
pub(all) struct PoseReplay {
  format : String
  model : Model
  clips : Array[Clip]
  source : Json
} derive(ToJson, @json.FromJson, Debug)
