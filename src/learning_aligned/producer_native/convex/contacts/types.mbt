///|
pub(all) struct Request {
  nworld : Int32
  ngeom : Int32
  candidate_capacity : Int32
  contact_capacity : Int32
  vertex_capacity : Int32
  graph_capacity : Int32
  hfield_capacity : Int32
  hfield_data_capacity : Int32
  polygon_capacity : Int32
  polygon_vertex_capacity : Int32
  polygon_map_capacity : Int32
  efc_slots : Int32
  gjk_iterations : Int32
  epa_iterations : Int32
  epa_vertices : Int32
  epa_faces : Int32
  epa_horizon : Int32
  max_polygon_vertices : Int32
  tolerance : Double
  use_multiccd : Bool
} derive(FromJson, ToJson, Debug)

///|
pub(all) struct Parameter {
  name : String
  c_type : String
  kind : String
  dtype : String
  rank : Int32
  access : String
} derive(ToJson, Debug)

///|
pub(all) struct Entry {
  forward : String
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(ToJson, Debug)

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
} derive(FromJson, ToJson, Debug)

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
  {
    name,
    dtype,
    rank,
    access,
    kind: "array",
    c_type: "wp::array_t<" +
    (if dtype == "vec5f" { "mr_vec5f" } else { "wp::" + dtype }) +
    ">",
  }
}

///|
fn validate_request(r : Request) -> Unit raise {
  guard r.nworld > 0 &&
    r.ngeom > 0 &&
    r.candidate_capacity > 0 &&
    r.candidate_capacity <= 268435455 &&
    r.contact_capacity >= 0 &&
    r.contact_capacity <= 2147483647 - 8 * r.candidate_capacity &&
    r.vertex_capacity >= 0 &&
    r.graph_capacity >= 0 &&
    r.hfield_capacity >= 0 &&
    r.hfield_data_capacity >= 0 &&
    r.polygon_capacity >= 0 &&
    r.polygon_vertex_capacity >= 0 &&
    r.polygon_map_capacity >= 0 &&
    r.efc_slots > 0 &&
    r.contact_capacity <= 2147483647 / r.efc_slots &&
    r.gjk_iterations > 0 &&
    r.gjk_iterations <= 4096 &&
    r.epa_iterations > 0 &&
    r.epa_iterations <= 4096 &&
    r.epa_vertices >= 8 &&
    r.epa_vertices <= 1024 &&
    r.epa_faces >= 4 &&
    r.epa_faces <= 1024 &&
    r.epa_horizon >= 3 &&
    r.epa_horizon <= 1024 &&
    r.max_polygon_vertices >= 16 &&
    r.max_polygon_vertices <= 1024 &&
    !r.tolerance.is_nan() &&
    !r.tolerance.is_inf() &&
    r.tolerance >= 1.0e-15 &&
    r.tolerance <= 1.0e15 else {
    raise Unsupported::Invalid(
      "invalid/overflowing convex contact dimensions, EPA scratch or tolerance",
    )
  }
}

///|
/// Mandatory completed and synchronized readback gate, never a record-only claim.
pub fn validate_results(
  request : Request,
  candidate_count : Int32,
  contact_count : Int32,
  rejected : Array[Int32],
) -> Unit raise {
  validate_request(request)
  guard candidate_count >= 0 &&
    candidate_count <= request.candidate_capacity &&
    contact_count >= 0 &&
    contact_count <= request.contact_capacity &&
    rejected.length() == 8 &&
    rejected.all(n => n == 0) else {
    raise Unsupported::Invalid(
      "convex contact overflow/unsupported/algorithm/bounds result rejected",
    )
  }
}
