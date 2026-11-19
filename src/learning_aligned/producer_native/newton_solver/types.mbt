///|
/// Full-rebuild scalar-reference GPU iteration. Actual constraint data and
/// effective model metrics are explicit inputs; no model dynamics are invented.
pub(all) struct Request {
  nworld : Int32
  nv : Int32
  njmax : Int32
  ncon : Int32
  mass_nnz : Int32
  jacobian_capacity : Int32
  iterations : Int32
  ls_iterations : Int32
  solver : String
  jacobian_layout : String
  mass_layout : String
  cone : String
  warmstart : Bool
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
pub(all) struct PlanRequest {
  request : Request
  module : String
  convergence_module : String
  views : Map[String, Json]
} derive(FromJson, ToJson)

///|
pub fn supported_kernels() -> Array[String] {
  [
    "initialize-controls", "initialize-state", "constraint-gradient-hessian", "factor-direction",
    "line-search", "line-search-incremental", "cg-search-init", "unconstrained",
  ]
}

///|
fn validate(request : Request) -> Unit raise {
  guard request.nworld > 0 &&
    request.nworld <= 1000000 &&
    request.nv >= 0 &&
    request.nv <= 46340 &&
    request.njmax >= 0 &&
    request.ncon >= 0 &&
    request.ncon <= 1000000 &&
    request.mass_nnz >= request.nv &&
    request.mass_nnz <= request.nv * request.nv &&
    request.jacobian_capacity >= 0 &&
    (request.nv == 0 || request.nworld <= 2147483647 / request.nv / request.nv) &&
    (
      request.nv == 0 ||
      request.njmax == 0 ||
      request.nworld <= 2147483647 / request.njmax / request.nv
    ) &&
    request.iterations >= 0 &&
    request.iterations <= 1000000 &&
    request.ls_iterations >= 0 &&
    request.ls_iterations <= 1000000 &&
    ["newton", "cg"].contains(request.solver) &&
    ["dense", "csr"].contains(request.jacobian_layout) &&
    ["dense", "csr"].contains(request.mass_layout) &&
    ["pyramidal", "elliptic"].contains(request.cone) &&
    !request.kernels.is_empty() else {
    fail("unsupported or overflowing full-rebuild Newton/CG specialization")
  }
  if request.njmax == 0 || request.nv == 0 {
    guard request.kernels == ["unconstrained"] else {
      fail(
        "zero-constraint/zero-DOF branch requires only the genuine unconstrained kernel",
      )
    }
  } else {
    guard !request.kernels.contains("unconstrained") else {
      fail("general profile cannot substitute the unconstrained copy kernel")
    }
  }
}

///|
pub fn expected_shape(r : Request, name : String) -> Array[Int32] raise {
  match name {
    "ne"
    | "nf"
    | "nefc"
    | "ctx_done"
    | "ctx_ls_exhausted"
    | "status"
    | "ctx_grad_dot"
    | "ctx_newton_decrement"
    | "ctx_search_dot"
    | "ctx_alpha"
    | "ctx_improvement"
    | "ls_overflow"
    | "objective_cost" => [r.nworld]
    "nacon" | "nsolving" => [1]
    "solver_niter" => [r.nworld]
    "opt_tolerance"
    | "opt_ls_tolerance"
    | "stat_meaninertia"
    | "opt_impratio_invsqrt" => [r.nworld]
    "M_csr" => [r.nworld, r.mass_nnz]
    "M_rowadr" | "M_rownnz" => [r.nv]
    "M_colind" => [r.mass_nnz]
    "M_dense_in"
    | "mass_dense"
    | "added_metric"
    | "preconditioner_dense"
    | "hessian"
    | "factor" => [r.nworld, r.nv, r.nv]
    "efc_J_rownnz"
    | "efc_J_rowadr"
    | "efc_type"
    | "efc_id"
    | "efc_D"
    | "efc_frictionloss"
    | "efc_aref"
    | "ctx_Jaref"
    | "efc_force"
    | "efc_state"
    | "ctx_jv" => [r.nworld, r.njmax]
    "efc_J_colind" => [r.nworld, 1, r.jacobian_capacity]
    "efc_J" =>
      if r.jacobian_layout == "dense" {
        [r.nworld, r.njmax, r.nv]
      } else {
        [r.nworld, 1, r.jacobian_capacity]
      }
    "contact_dim"
    | "contact_worldid"
    | "contact_friction"
    | "contact_dist"
    | "contact_includemargin" => [r.ncon]
    "contact_efc_address" => [r.ncon, 6]
    "qacc_warmstart"
    | "qacc_smooth"
    | "qfrc_smooth"
    | "qacc"
    | "ctx_Ma"
    | "qfrc_constraint"
    | "ctx_grad"
    | "ctx_Mgrad"
    | "ctx_search"
    | "ctx_prev_grad"
    | "ctx_prev_Mgrad"
    | "ctx_mv" => [r.nworld, r.nv]
    _ => fail("unknown Newton solver parameter: " + name)
  }
}

///|
pub fn immutable_parameters(r : Request) -> Array[String] raise {
  validate(r)
  if r.njmax == 0 || r.nv == 0 {
    return ["qacc_smooth"]
  }
  let names = [
    "ne", "nf", "nefc", "nacon", "efc_type", "efc_id", "efc_D", "efc_frictionloss",
    "efc_aref", "efc_J", "contact_dim", "contact_worldid", "contact_efc_address",
    "contact_friction", "contact_dist", "contact_includemargin", "opt_tolerance",
    "opt_ls_tolerance", "stat_meaninertia", "opt_impratio_invsqrt", "qacc_warmstart",
    "qacc_smooth", "qfrc_smooth", "added_metric",
  ]
  if r.mass_layout == "dense" {
    names.push("M_dense_in")
  } else {
    names.append(["M_csr", "M_rowadr", "M_rownnz", "M_colind"])
  }
  if r.jacobian_layout == "csr" {
    names.append(["efc_J_rownnz", "efc_J_rowadr", "efc_J_colind"])
  }
  if r.solver == "cg" {
    names.push("preconditioner_dense")
  }
  names
}

///|
fn parameters(r : Request, key : String) -> Array[Parameter] raise {
  guard supported_kernels().contains(key) else {
    fail("unsupported Newton solver kernel")
  }
  if key == "initialize-controls" {
    return [
      ("ctx_done", "bool", 1, "inout"),
      ("solver_niter", "int32", 1, "inout"),
      ("nsolving", "int32", 1, "inout"),
      ("ctx_search_dot", "float32", 1, "inout"),
      ("status", "int32", 1, "inout"),
    ].map(fn(p) {
      let (name, dtype, rank, access) = p
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
    })
  }
  if key == "unconstrained" {
    return [
      ("qacc_smooth", "float32", 2, "input"),
      ("qacc", "float32", 2, "inout"),
      ("qfrc_constraint", "float32", 2, "inout"),
      ("solver_niter", "int32", 1, "inout"),
      ("status", "int32", 1, "inout"),
    ].map(fn(p) {
      let (name, dtype, rank, access) = p
      {
        name,
        dtype,
        rank,
        access,
        kind: "array",
        c_type: "wp::array_t<wp::" + dtype + ">",
      }
    })
  }
  let all : Array[(String, String, Int32)] = []
  for
    name in [
      "ne", "nf", "nefc", "nacon", "contact_dim", "contact_worldid", "nsolving",
    ] {
    all.push((name, "int32", 1))
  }
  for name in ["efc_type", "efc_id", "contact_efc_address"] {
    all.push((name, "int32", 2))
  }
  if r.mass_layout == "dense" {
    all.push(("M_dense_in", "float32", 3))
  } else {
    all.push(("M_csr", "float32", 2))
    for name in ["M_rowadr", "M_rownnz", "M_colind"] {
      all.push((name, "int32", 1))
    }
  }
  all.push(("efc_J", "float32", 3))
  if r.jacobian_layout == "csr" {
    for name in ["efc_J_rownnz", "efc_J_rowadr"] {
      all.push((name, "int32", 2))
    }
    all.push(("efc_J_colind", "int32", 3))
  }
  for
    name in [
      "efc_D", "efc_frictionloss", "efc_aref", "qacc_warmstart", "qacc_smooth", "qfrc_smooth",
    ] {
    all.push((name, "float32", 2))
  }
  all.push(("contact_friction", "vec5f", 1))
  for name in ["contact_dist", "contact_includemargin"] {
    all.push((name, "float32", 1))
  }
  for
    name in [
      "opt_tolerance", "opt_ls_tolerance", "stat_meaninertia", "opt_impratio_invsqrt",
    ] {
    all.push((name, "float32", 1))
  }
  all.push(("added_metric", "float32", 3))
  all.push(("ctx_done", "bool", 1))
  all.push(("ctx_ls_exhausted", "bool", 1))
  all.push(("status", "int32", 1))
  all.push(("ls_overflow", "int32", 1))
  if r.solver == "cg" {
    all.push(("preconditioner_dense", "float32", 3))
  }
  for name in ["mass_dense", "hessian", "factor"] {
    all.push((name, "float32", 3))
  }
  for
    name in [
      "qacc", "ctx_Ma", "qfrc_constraint", "ctx_grad", "ctx_Mgrad", "ctx_search",
      "ctx_prev_grad", "ctx_prev_Mgrad", "ctx_mv", "ctx_Jaref", "efc_force", "ctx_jv",
    ] {
    all.push((name, "float32", 2))
  }
  all.push(("efc_state", "int32", 2))
  for
    name in [
      "ctx_grad_dot", "ctx_newton_decrement", "ctx_search_dot", "ctx_alpha", "ctx_improvement",
      "objective_cost",
    ] {
    all.push((name, "float32", 1))
  }
  let writes = match key {
    "initialize-controls" => ["solver_niter", "ctx_search_dot"]
    "initialize-state" =>
      [
        "mass_dense", "qacc", "ctx_Ma", "ctx_Jaref", "qfrc_constraint", "ctx_grad_dot",
        "ctx_newton_decrement", "ctx_search_dot", "ctx_improvement",
      ]
    "constraint-gradient-hessian" =>
      [
        "efc_force", "efc_state", "qfrc_constraint", "ctx_grad", "ctx_grad_dot",
        "hessian", "objective_cost",
      ]
    "factor-direction" =>
      [
        "factor", "ctx_Mgrad", "ctx_search", "ctx_newton_decrement", "ctx_search_dot",
      ]
    "line-search" | "line-search-incremental" =>
      [
        "ctx_mv", "ctx_jv", "qacc", "ctx_Ma", "ctx_Jaref", "ctx_improvement", "ls_overflow",
      ]
    "cg-search-init" =>
      ["ctx_search", "ctx_prev_grad", "ctx_prev_Mgrad", "ctx_search_dot"]
    _ => []
  }
  all.map(fn(item) {
    let (name, dtype, rank) = item
    {
      name,
      dtype,
      rank,
      kind: "array",
      c_type: "wp::array_t<" +
      (if dtype == "bool" {
        "bool"
      } else if dtype == "vec5f" {
        "mr_vec5f"
      } else {
        "wp::" + dtype
      }) +
      ">",
      access: if name == "status" ||
        name == "ctx_alpha" ||
        writes.contains(name) ||
        (
          (key == "cg-search-init" || key == "initialize-controls") &&
          (name == "ctx_done" || name == "nsolving")
        ) ||
        (key == "initialize-state" && name == "ls_overflow") ||
        (key == "line-search-incremental" && name == "ctx_ls_exhausted") {
        "inout"
      } else {
        "input"
      },
    }
  })
}
