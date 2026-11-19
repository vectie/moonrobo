///|
pub(all) struct Request {
  layout : @factorization.MixedLayout
  dtype : String
  nworld : Int32
  block_dim : Int32
  architecture : Int32
  check_done : Bool
} derive(FromJson, ToJson)

///|
pub(all) struct Parameter {
  name : String
  c_type : String
  kind : String
  dtype : String
  rank : Int32
  access : String
} derive(ToJson)

///|
pub(all) struct Entry {
  key : String
  forward : String
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(ToJson)

///|
pub(all) struct LaunchPolicy {
  block_dim : Int32
  forward_smem : Int32
  backward_smem : Int32
  grid_stride : Bool
  coord_mult : Int32
} derive(ToJson)

///|
pub(all) struct Metadata {
  name : String
  dtype : String
  shape : Array[Int32]
  bytes : Bytes
  sha256 : String
}

///|
pub(all) struct MetadataInput {
  name : String
  bytes : Bytes
}

///|
pub(all) struct Binding {
  name : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  offset_bytes : UInt64
  capacity_bytes : UInt64
  owner : String
} derive(FromJson, ToJson)

///|
pub(all) struct Lowered {
  request : Request
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Array[Entry]
  launch_policy : LaunchPolicy
  metadata : Array[Metadata]
  factor_width : Int32
  nC : Int32
  nv : Int32
  sparse_levels : Int32
  body_static_shared_bytes : Int32
}

///|
pub(all) struct CompileConfig {
  request : Request
  nvrtc_library : String
  warp_native : String
  mujoco_warp_root : String
  cuda_include_dirs : Array[String]
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct LuLayout {
  d_rownnz : Array[Int32]
  d_rowadr : Array[Int32]
  d_diag : Array[Int32]
  d_colind : Array[Int32]
} derive(FromJson, ToJson)

///|
pub(all) struct LuRequest {
  layout : LuLayout
  dtype : String
  nworld : Int32
  block_dim : Int32
  architecture : Int32
  check_done : Bool
} derive(FromJson, ToJson)

///|
pub(all) struct LuLowered {
  request : LuRequest
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Array[Entry]
  launch_policy : LaunchPolicy
  metadata : Array[Metadata]
  nv : Int32
  nD : Int32
}

///|
pub(all) struct LuCompileConfig {
  request : LuRequest
  nvrtc_library : String
  warp_native : String
  mujoco_warp_root : String
  cuda_include_dirs : Array[String]
  output : String
} derive(FromJson, ToJson)

///|
pub suberror SolverError {
  Invalid(String)
} derive(Debug)

///|
pub extend Request with @json.FromJson::{from_json}

///|
pub extend Request with ToJson::{to_json}

///|
pub extend Parameter with ToJson::{to_json}

///|
pub extend Entry with ToJson::{to_json}

///|
pub extend LaunchPolicy with ToJson::{to_json}

///|
pub extend Binding with @json.FromJson::{from_json}

///|
pub extend Binding with ToJson::{to_json}

///|
pub extend CompileConfig with @json.FromJson::{from_json}

///|
pub extend CompileConfig with ToJson::{to_json}

///|
pub extend LuLayout with @json.FromJson::{from_json}

///|
pub extend LuLayout with ToJson::{to_json}

///|
pub extend LuRequest with @json.FromJson::{from_json}

///|
pub extend LuRequest with ToJson::{to_json}

///|
pub extend LuCompileConfig with @json.FromJson::{from_json}

///|
pub extend LuCompileConfig with ToJson::{to_json}

///|
pub extend SolverError with @debug.Debug::{to_repr}
