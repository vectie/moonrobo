///|
/// Explicit triangulated local-space geometry. Empty velocities mean the
/// Newton Mesh.finalize zero velocity buffer; empty groups mean no grouping.
pub(all) struct MeshRequest {
  vertices : Array[Double]
  indices : Array[Int32]
  velocities : Array[Double]
  groups : Array[Int32]
  bvh_constructor : String
  bvh_leaf_size : Int32
  support_winding_number : Bool
} derive(FromJson, ToJson)

///|
/// Owned little-endian contiguous f32 vec3 points/velocities and i32 indices.
/// No resource pointer, USD schema, hull or device is fabricated here.
pub struct PreparedMesh {
  points : Bytes
  velocities : Bytes
  indices : Bytes
  groups : Bytes
  vertex_count : Int32
  triangle_count : Int32
  bvh_constructor : String
  bvh_leaf_size : Int32
  support_winding_number : Bool
}

///|
pub(all) struct ExecuteRequest {
  request : MeshRequest
  adapter : String
  warp_library : String
  output : String
} derive(FromJson)
