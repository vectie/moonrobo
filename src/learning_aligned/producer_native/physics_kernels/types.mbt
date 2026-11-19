///|
/// Concrete MuJoCo-Warp 3.15 source specializations. Unsupported solver and
/// broadphase variants fail before native compiler loading.
pub(all) struct Request {
  nworld : Int32
  nv : Int32
  ngeom : Int32
  npair : Int32
  njmax : Int32
  mass_nnz : Int32
  jacobian_capacity : Int32
  filter_bits : Int32
  ngeom_aabb : Int32
  ngeom_rbound : Int32
  ngeom_margin : Int32
  ngeom_gap : Int32
  ngeom_dataid : Int32
  check_skip : Bool
  compact : Bool
  enable_sleep : Bool
  incremental : Bool
  kernels : Array[String]
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
  key : String
  forward : String
  source_file : String
  source_function : String
  source_sha256 : String
  helper_functions : Array[String]
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(Debug, ToJson)

///|
pub(all) struct Lowered {
  source : String
  source_sha256 : String
  specialization_sha256 : String
  request : Request
  entries : Array[Entry]
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
  let element = if dtype == "bool" { "bool" } else { "wp::" + dtype }
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
fn scalar(name : String) -> Parameter {
  {
    name,
    c_type: "wp::int32",
    kind: "scalar",
    dtype: "int32",
    rank: 0,
    access: "input",
  }
}

///|
fn source_sha(path : String) -> String raise {
  match path {
    "support.py" =>
      "c924593f7be8447c76328bcf7dc5b4ce92b6a54458c4afdbf36806cb8e036d46"
    "solver.py" =>
      "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916"
    "collision_driver.py" =>
      "186f59493726610a4bf477301852fc06c306a12101a12161198a78b785affa6d"
    "io.py" =>
      "2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0"
    _ => raise Unsupported::Invalid("unknown MuJoCo-Warp 3.15 source file")
  }
}
