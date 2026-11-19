///|
/// Real pinned compact/incremental kernels over caller-supplied actual maps.
pub(all) struct Request {
  nworld : Int32
  nv : Int32
  nv_compact : Int32
  njmax : Int32
  mass_nnz : Int32
  jacobian_capacity : Int32
  gather_nnz : Int32
  jacobian_layout : String
  compact : Bool
  stable_fast : Bool
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
  launch_policy : @newton_solver.LaunchPolicy
}

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
pub fn supported_kernels() -> Array[String] {
  [
    "compact-inertia-init", "compact-mass-gather", "compact-rhs-gather", "compact-solution-scatter",
    "compact-vectors-gather", "compact-vectors-scatter", "compact-jacobian-gather",
    "compact-mass-multiply", "full-mass-multiply", "incremental-initialize", "incremental-zero-changes",
    "incremental-constraint-update", "incremental-qfrc-rebuild", "incremental-gradient-update",
    "incremental-hessian-update", "incremental-factor-direction", "recover-qfrc",
    "pad-hessian",
  ]
}

///|
fn validate(r : Request) -> Unit raise {
  guard r.nworld > 0 &&
    r.nv > 0 &&
    r.nv_compact > 0 &&
    r.nv <= 46340 &&
    r.nv_compact <= 46340 &&
    r.njmax >= 0 &&
    r.njmax < 2147483647 &&
    r.mass_nnz >= r.nv &&
    r.mass_nnz <= r.nv * r.nv &&
    r.jacobian_capacity >= 0 &&
    r.gather_nnz >= 0 &&
    r.nworld <= 2147483647 / r.nv_compact / r.nv_compact &&
    (r.njmax == 0 || r.nworld <= 2147483647 / r.njmax / r.nv) &&
    ["dense", "csr"].contains(r.jacobian_layout) &&
    (r.compact || r.nv_compact >= r.nv) &&
    !r.kernels.is_empty() else {
    fail("invalid or overflowing compact/incremental specialization")
  }
}

///|
pub fn expected_shape(r : Request, name : String) -> Array[Int32] raise {
  match name {
    "status"
    | "skip"
    | "ctx_done"
    | "ncdof"
    | "ne"
    | "nf"
    | "nefc"
    | "quad_changed_count"
    | "state_changed_count"
    | "ctx_ls_exhausted"
    | "ctx_alpha"
    | "ctx_grad_scale"
    | "ctx_grad_dot"
    | "ctx_newton_decrement"
    | "ctx_search_dot"
    | "ctx_search_unchanged" => [r.nworld]
    "M_rownnz" | "M_rowadr" => [r.nv]
    "M_colind" => [r.mass_nnz]
    "M_mulm_rowadr" => [r.nv + 1]
    "M_mulm_col" | "M_mulm_madr" => [r.gather_nnz]
    "M" => [r.nworld, r.mass_nnz]
    "dof_cdof"
    | "vec_full"
    | "vec_out"
    | "res_full"
    | "qacc_warmstart_full"
    | "qfrc_smooth_full"
    | "qacc_smooth_full"
    | "qacc_full"
    | "qfrc_constraint_full" => [r.nworld, r.nv]
    "cdof_dof"
    | "vec_c"
    | "res_c"
    | "qacc_warmstart_c"
    | "qfrc_smooth_c"
    | "qacc_smooth_c"
    | "qacc_c"
    | "qfrc_constraint_c"
    | "ctx_grad"
    | "ctx_Mgrad"
    | "ctx_search"
    | "qfrc_constraint"
    | "ctx_Ma"
    | "qfrc_smooth" => [r.nworld, r.nv_compact]
    "M_c" | "hessian" | "factor" => [r.nworld, r.nv_compact, r.nv_compact]
    "rhs_c" | "solution_c" => [r.nworld, r.nv_compact, 1]
    "J" =>
      if r.jacobian_layout == "dense" {
        [r.nworld, r.njmax, r.nv]
      } else {
        [r.nworld, 1, r.jacobian_capacity]
      }
    "J_c" => [r.nworld, r.njmax, r.nv_compact]
    "J_colind" => [r.nworld, 1, r.jacobian_capacity]
    "J_rownnz"
    | "J_rowadr"
    | "D"
    | "frictionloss"
    | "ctx_Jaref"
    | "force"
    | "state"
    | "efc_type"
    | "quad_changed_ids" => [r.nworld, r.njmax]
    _ => fail("unknown solver adapter parameter: " + name)
  }
}

///|
fn dtype(name : String) -> String {
  if [
      "status", "ncdof", "ne", "nf", "nefc", "M_rownnz", "M_rowadr", "M_colind",
      "M_mulm_rowadr", "M_mulm_col", "M_mulm_madr", "dof_cdof", "cdof_dof", "J_colind",
      "J_rownnz", "J_rowadr", "state", "efc_type", "quad_changed_ids", "quad_changed_count",
      "state_changed_count",
    ].contains(name) {
    "int32"
  } else if ["ctx_done", "skip", "ctx_ls_exhausted", "ctx_search_unchanged"].contains(
      name,
    ) {
    "bool"
  } else {
    "float32"
  }
}

///|
fn parameters(r : Request, key : String) -> Array[Parameter] raise {
  guard supported_kernels().contains(key) else {
    fail("unknown solver adapter kernel")
  }
  let (input, output) = match key {
    "compact-inertia-init" => (["ncdof"], ["M_c"])
    "compact-mass-gather" =>
      (
        [
          "M_rownnz", "M_rowadr", "M_colind", "M", "ncdof", "dof_cdof", "cdof_dof",
        ],
        ["M_c"],
      )
    "compact-rhs-gather" =>
      (["ncdof", "dof_cdof", "cdof_dof", "vec_full"], ["rhs_c"])
    "compact-solution-scatter" =>
      (["ncdof", "dof_cdof", "cdof_dof", "solution_c"], ["vec_out"])
    "compact-vectors-gather" =>
      (
        [
          "ncdof", "dof_cdof", "cdof_dof", "qacc_warmstart_full", "qfrc_smooth_full",
          "qacc_smooth_full",
        ],
        ["qacc_warmstart_c", "qfrc_smooth_c", "qacc_smooth_c"],
      )
    "compact-vectors-scatter" =>
      (
        ["ncdof", "dof_cdof", "cdof_dof", "qacc_c", "qfrc_constraint_c"],
        ["qacc_full", "qfrc_constraint_full"],
      )
    "compact-jacobian-gather" =>
      (["ncdof", "dof_cdof", "cdof_dof", "nefc", "J"], ["J_c"])
    "compact-mass-multiply" =>
      (
        [
          "ncdof", "dof_cdof", "cdof_dof", "M_mulm_rowadr", "M_mulm_col", "M_mulm_madr",
          "M", "vec_c", "skip",
        ],
        ["res_c"],
      )
    "full-mass-multiply" =>
      (
        ["M_mulm_rowadr", "M_mulm_col", "M_mulm_madr", "M", "vec_full"],
        ["res_full"],
      )
    "incremental-initialize" =>
      (
        [],
        [
          "ctx_grad_scale", "ctx_search_unchanged", "ctx_ls_exhausted", "quad_changed_count",
          "state_changed_count",
        ],
      )
    "incremental-zero-changes" =>
      ([], ["quad_changed_count", "state_changed_count"])
    "incremental-constraint-update" =>
      (
        [
          "ne", "nf", "nefc", "efc_type", "D", "frictionloss", "ctx_Jaref", "ctx_ls_exhausted",
          "ctx_done",
        ],
        [
          "force", "state", "quad_changed_ids", "quad_changed_count", "state_changed_count",
        ],
      )
    "incremental-qfrc-rebuild" =>
      (
        ["nefc", "J", "force", "state_changed_count", "ctx_done"],
        ["qfrc_constraint"],
      )
    "incremental-gradient-update" =>
      (
        [
          "ctx_Ma", "qfrc_smooth", "qfrc_constraint", "ctx_alpha", "state_changed_count",
          "ctx_done",
        ],
        [
          "ctx_grad", "ctx_grad_dot", "ctx_newton_decrement", "ctx_grad_scale", "ctx_search_unchanged",
        ],
      )
    "incremental-hessian-update" =>
      (
        [
          "nefc", "J", "D", "state", "quad_changed_ids", "quad_changed_count", "ctx_done",
        ],
        ["hessian"],
      )
    "incremental-factor-direction" =>
      (
        [
          "ctx_grad", "hessian", "quad_changed_count", "state_changed_count", "ctx_done",
        ],
        [
          "factor", "ctx_Mgrad", "ctx_search", "ctx_search_dot", "ctx_newton_decrement",
        ],
      )
    "recover-qfrc" =>
      (
        ["ctx_Ma", "qfrc_smooth", "ctx_grad", "ctx_grad_scale"],
        ["qfrc_constraint"],
      )
    "pad-hessian" => (["ctx_done"], ["hessian"])
    _ => fail("unknown solver adapter kernel")
  }
  if [
      "compact-jacobian-gather", "incremental-qfrc-rebuild", "incremental-hessian-update",
    ].contains(key) {
    if r.jacobian_layout == "csr" {
      input.append(["J_rownnz", "J_rowadr", "J_colind"])
    }
    if key != "compact-jacobian-gather" && r.compact {
      input.append(["ncdof", "dof_cdof", "cdof_dof"])
    }
  }
  let result : Array[Parameter] = []
  for name in input {
    let dt = dtype(name)
    result.push({
      name,
      dtype: dt,
      rank: expected_shape(r, name).length(),
      access: "input",
      kind: "array",
      c_type: "wp::array_t<" +
      (if dt == "bool" { "bool" } else { "wp::" + dt }) +
      ">",
    })
  }
  for name in output {
    let dt = dtype(name)
    result.push({
      name,
      dtype: dt,
      rank: expected_shape(r, name).length(),
      access: "inout",
      kind: "array",
      c_type: "wp::array_t<" +
      (if dt == "bool" { "bool" } else { "wp::" + dt }) +
      ">",
    })
  }
  result.push({
    name: "status",
    dtype: "int32",
    rank: 1,
    access: "inout",
    kind: "array",
    c_type: "wp::array_t<wp::int32>",
  })
  result
}

///|
/// Only these actual model indices/domain inputs are frozen by the pipeline;
/// changed IDs/counts are produced dynamically and checked on device each use.
pub fn immutable_parameters(r : Request, key : String) -> Array[String] raise {
  parameters(r, key)
  .filter(p => {
    [
      "ncdof", "ne", "nf", "nefc", "efc_type", "D", "frictionloss", "M_rownnz", "M_rowadr",
      "M_colind", "M_mulm_rowadr", "M_mulm_col", "M_mulm_madr", "dof_cdof", "cdof_dof",
      "J_rownnz", "J_rowadr", "J_colind", "J",
    ].contains(p.name)
  })
  .map(p => p.name)
}
