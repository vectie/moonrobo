///|
/// This concrete lowerer specializes the pinned G1 array hooks, not arbitrary
/// Python/Warp source, Newton dynamics, or the MuJoCo-Warp constraint solver.
pub(all) struct SpecializationRequest {
  num_envs : Int32
  num_joints : Int32
  num_bodies : Int32
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
  upstream_file : String
  upstream_function : String
  upstream_file_sha256 : String
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(Debug, ToJson)

///|
pub(all) struct Specialization {
  source : String
  source_sha256 : String
  specialization_sha256 : String
  request : SpecializationRequest
  entries : Array[Entry]
} derive(Debug)

///|
pub(all) struct CompileConfig {
  specialization : SpecializationRequest
  isaaclab_root : String
  warp_native : String
  nvrtc_library : String
  options : Array[String]
  kind : String
  output : String
} derive(Debug, FromJson, ToJson)

///|
pub suberror LowerError {
  Invalid(String)
} derive(Debug)

///|
pub fn isaaclab_revision() -> String {
  "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed"
}

///|
fn ordering_path() -> String {
  "source/isaaclab/isaaclab/assets/articulation/ordering_kernels.py"
}

///|
fn shared_path() -> String {
  "source/isaaclab_newton/isaaclab_newton/assets/kernels.py"
}

///|
fn actuator_path() -> String {
  "source/isaaclab/isaaclab/actuators/newton/kernels.py"
}

///|
fn collection_path() -> String {
  "source/isaaclab/isaaclab/actuators/actuator_kernels.py"
}

///|
fn file_sha(path : String) -> String raise {
  match path {
    p if p == ordering_path() =>
      "f0be1e29a9d01ca46fec386178956df6ef8142ef53652ec679f7d89bc10d1715"
    p if p == shared_path() =>
      "9d76f4a358045d6f0dc0ef052d37ffc1013aac0d4972f40fb2a9a0faee1ada62"
    p if p == actuator_path() =>
      "1da47064c9571e7aa2169ee5c26061ce379d4e3cb4ba5a4fbc0e3da8244e44bd"
    p if p == collection_path() =>
      "6c2ce37270e12c3e04bf0c0e016bb8e93ba0adf99c4fcccefb893a57222171a2"
    _ => raise LowerError::Invalid("unknown pinned kernel source path")
  }
}

///|
fn array(
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
fn boolean(name : String) -> Parameter {
  {
    name,
    c_type: "bool",
    kind: "scalar",
    dtype: "bool",
    rank: 0,
    access: "input",
  }
}

///|
fn integer(name : String) -> Parameter {
  {
    name,
    c_type: "wp::int32",
    kind: "scalar",
    dtype: "int32",
    rank: 0,
    access: "input",
  }
}
