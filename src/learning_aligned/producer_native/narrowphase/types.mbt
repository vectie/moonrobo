///|
pub(all) struct Request {
  nworld : Int32
  ngeom : Int32
  candidate_capacity : Int32
  contact_capacity : Int32
  efc_slots : Int32
  pairs : Array[String]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct Parameter {
  name : String
  c_type : String
  kind : String
  dtype : String
  rank : Int32
  access : String
} derive(Debug, ToJson)

///|
pub(all) struct Entry {
  forward : String
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(Debug, ToJson)

///|
pub(all) struct Lowered {
  source : String
  source_sha256 : String
  specialization_sha256 : String
  request : Request
  entry : Entry
} derive(Debug)

///|
pub(all) struct CompileConfig {
  request : Request
  mujoco_warp_root : String
  warp_native : String
  nvrtc_library : String
  options : Array[String]
  kind : String
  output : String
} derive(Debug, FromJson, ToJson)

///|
pub suberror Unsupported {
  Invalid(String)
} derive(Debug)

///|
fn parameter(
  name : String,
  dtype : String,
  rank : Int32,
  access : String,
) -> Parameter {
  let element = if dtype == "vec5f" { "mr_vec5f" } else { "wp::" + dtype }
  {
    name,
    c_type: "wp::array_t<\{element}>",
    kind: "array",
    dtype,
    rank,
    access,
  }
}

///|
pub fn supported_pairs() -> Array[String] {
  [
    "plane-sphere", "sphere-sphere", "sphere-capsule", "plane-capsule", "sphere-box",
    "plane-box", "capsule-capsule",
  ]
}

///|
fn pair_types(pair : String) -> (Int32, Int32) raise {
  match pair {
    "plane-sphere" => (0, 2)
    "sphere-sphere" => (2, 2)
    "sphere-capsule" => (2, 3)
    "plane-capsule" => (0, 3)
    "sphere-box" => (2, 6)
    "plane-box" => (0, 6)
    "capsule-capsule" => (3, 3)
    _ => raise Unsupported::Invalid("unsupported primitive pair: " + pair)
  }
}

///|
fn source_sha(file : String) -> String raise {
  match file {
    "collision_primitive.py" =>
      "0896a97ff122639ffc8c583d5edcb4f64ca3fd27210989e3b736039000327e28"
    "collision_primitive_core.py" =>
      "4638635965216a19e52a910bccb4a92ad955036eb0525acf7b0ab78dc9f93f5b"
    "collision_core.py" =>
      "55bfdc244254624d61c228d70d4fd4dc0d2d6af60af40c6e8ed16e47315e2ea6"
    "math.py" =>
      "d08e978993c3d3b5d3f16cb96af94beff519a60a5ea827134b388f30c3a6756c"
    "types.py" =>
      "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b"
    "collision_driver.py" =>
      "186f59493726610a4bf477301852fc06c306a12101a12161198a78b785affa6d"
    _ => raise Unsupported::Invalid("unknown pinned narrowphase source")
  }
}
