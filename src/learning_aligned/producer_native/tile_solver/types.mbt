///|
/// Independent row-major dense tiles, not a complete mixed MuJoCo solver.
pub(all) struct Request {
  operation : String
  dtype : String
  tile_size : Int32
  rhs_columns : Int32
  batch_size : Int32
  block_dim : Int32
  architecture : Int32
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
pub(all) struct Lowered {
  request : Request
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Array[Entry]
  launch_policy : LaunchPolicy
  static_shared_bytes : Int32
  potrf_symbol : String
  potrs_symbol : String?
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
pub(all) struct CompileConfig {
  request : Request
  warp_library : String
  warp_native : String
  cuda_include_dirs : Array[String]
  output : String
} derive(FromJson, ToJson)

///|
pub suberror TileError {
  Invalid(String)
  Native(String)
} derive(Debug)

///|
pub extend Request with @json.FromJson::{from_json}

///|
pub extend Request with ToJson::{to_json}

///|
pub extend Binding with @json.FromJson::{from_json}

///|
pub extend Binding with ToJson::{to_json}

///|
pub extend CompileConfig with @json.FromJson::{from_json}

///|
pub extend CompileConfig with ToJson::{to_json}

///|
pub extend Parameter with ToJson::{to_json}

///|
pub extend Entry with ToJson::{to_json}

///|
pub extend LaunchPolicy with ToJson::{to_json}

///|
pub extend TileError with @debug.Debug::{to_repr}
