///|
/// Concrete FP32 per-world convergence transitions. Each CUDA thread owns
/// one world's state. CG's nv reduction is serial, not a tile-order parity claim.
pub(all) struct Request {
  nworld : Int32
  nv : Int32
  iterations : Int32
  warn_overflow : Int32
  kernels : Array[String]
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
pub(all) struct Lowered {
  request : Request
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Array[Entry]
}

///|
pub(all) struct CompileConfig {
  request : Request
  mujoco_warp_root : String
  warp_native : String
  nvrtc_library : String
  options : Array[String]
  kind : String
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct Binding {
  name : String
  allocation : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  byte_offset : Int64
  buffer_bytes : Int64
} derive(FromJson, ToJson)

///|
pub fn source_sha256() -> String {
  "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916"
}

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
    (if dtype == "bool" { "bool" } else { "wp::" + dtype }) +
    ">",
  }
}
