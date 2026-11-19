///|
pub(all) struct Request {
  nworld : Int32
  ngeom : Int32
  candidate_capacity : Int32
  vertex_capacity : Int32
  gjk_iterations : Int32
  tolerance : Double
  cutoff : Double
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
  {
    name,
    c_type: "wp::array_t<wp::" + dtype + ">",
    kind: "array",
    dtype,
    rank,
    access,
  }
}

///|
fn validate_request(r : Request) -> Unit raise {
  guard r.nworld > 0 &&
    r.ngeom > 0 &&
    r.candidate_capacity > 0 &&
    r.candidate_capacity <= 2147483647 &&
    r.vertex_capacity >= 0 &&
    r.gjk_iterations > 0 &&
    r.gjk_iterations <= 4096 &&
    !r.tolerance.is_nan() &&
    !r.tolerance.is_inf() &&
    r.tolerance >= 1.0e-15 &&
    r.tolerance <= 1.0e15 &&
    !r.cutoff.is_nan() &&
    !r.cutoff.is_inf() &&
    r.cutoff >= 0.0 &&
    r.cutoff <= 1.0e32 else {
    raise Unsupported::Invalid(
      "invalid finite convex specialization dimensions/options",
    )
  }
}

///|
/// All values must come from completed, synchronized actual GPU readback. This
/// is mandatory before a consumer uses any distance or witness from this stage.
pub fn validate_results(
  request : Request,
  count : Int32,
  status : Array[Int32],
  rejected : Array[Int32],
) -> Unit raise {
  validate_request(request)
  guard count >= 0 &&
    count <= request.candidate_capacity &&
    status.length() == request.candidate_capacity &&
    rejected.length() == 5 &&
    rejected.all(x => x == 0) else {
    raise Unsupported::Invalid(
      "convex result count/capacity or rejection gate failed",
    )
  }
  for i, value in status {
    guard (if i < count { value >= 1 && value <= 3 } else { value == 0 }) else {
      raise Unsupported::Invalid(
        "convex incomplete/unsupported/failed candidate result",
      )
    }
  }
}
