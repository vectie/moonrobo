///|
/// Explicit capacities of real effective-metric arrays. No metric coefficient
/// or flex/contact descriptor is synthesized from a count.
pub(all) struct Request {
  nworld : Int32
  nv : Int32
  nC : Int32
  nK : Int32
  nblock : Int32
  nefm0 : Int32
  nefm0L : Int32
  ntendon : Int32
  tendon_nnz : Int32
  nactuator : Int32
  moment_nnz : Int32
  njmax : Int32
  jacobian_nnz : Int32
  ncon : Int32
  contact_width : Int32
  ntree : Int32
  sparse_jacobian : Bool
  sleep : Bool
  check_skip : Bool
  architecture : Int32
  kernels : Array[String]
} derive(FromJson, ToJson)

///|
pub extend Request with @json.FromJson::{from_json}

///|
pub extend Request with ToJson::{to_json}

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
pub extend Parameter with ToJson::{to_json}

///|
pub(all) struct Entry {
  key : String
  forward : String
  launch_shape : Array[Int32]
  parameters : Array[Parameter]
} derive(ToJson)

///|
pub extend Entry with ToJson::{to_json}

///|
pub(all) struct LaunchPolicy {
  block_dim : Int32
  forward_smem : Int32
  backward_smem : Int32
  grid_stride : Bool
  coord_mult : Int32
} derive(ToJson)

///|
pub extend LaunchPolicy with ToJson::{to_json}

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
  owner : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  offset_bytes : UInt64
  capacity_bytes : UInt64
} derive(FromJson, ToJson)

///|
pub extend Binding with @json.FromJson::{from_json}

///|
pub extend Binding with ToJson::{to_json}

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
pub extend CompileConfig with @json.FromJson::{from_json}

///|
pub extend CompileConfig with ToJson::{to_json}

///|
pub fn supported_kernels() -> Array[String] {
  [
    "effective-force", "zero-sleeping", "copy-backbone-rhs", "block-solve", "efm0-solve",
    "build-blocks", "factor-blocks", "factor-folded-blocks", "fold-tendon", "fold-actuator",
    "fold-efc-sparse", "fold-contact-rank1", "mul-diag", "mul-diag-csr", "mul-tendon",
    "mul-actuator", "mul-contact", "mul-fluid", "add-qh-diag", "add-tendon-qh-diag",
    "add-actuator-qh-diag", "add-fluid-qh",
  ]
}

///|
fn validate(r : Request) -> Unit raise {
  guard r.nworld > 0 &&
    r.nv > 0 &&
    r.nv <= 65536 &&
    r.nC >= r.nv &&
    r.nC <= 33554432 &&
    r.nK >= 0 &&
    r.nK <= 33554432 &&
    r.nblock >= 0 &&
    r.nblock <= r.nv / 3 &&
    r.nefm0 >= 0 &&
    r.nefm0 <= r.nv &&
    r.nefm0L >= 0 &&
    r.nefm0L <= 33554432 &&
    r.ntendon >= 0 &&
    r.tendon_nnz >= 0 &&
    r.nactuator >= 0 &&
    r.moment_nnz >= 0 &&
    r.njmax >= 0 &&
    r.jacobian_nnz >= 0 &&
    r.ncon >= 0 &&
    r.contact_width >= 0 &&
    r.contact_width <= r.nv &&
    r.ntree >= 0 &&
    (!r.sleep || r.ntree > 0) &&
    [60, 61, 62, 70, 72, 75, 80, 86, 87, 89, 90, 100, 103, 110, 120, 121].contains(
      r.architecture,
    ) &&
    !r.kernels.is_empty() else {
    fail("unsupported effective-metric capacity or architecture")
  }
  let seen : Map[String, Unit] = Map([])
  for key in r.kernels {
    guard supported_kernels().contains(key) && !seen.contains(key) else {
      fail("unknown/duplicate metric helper")
    }
    seen[key] = ()
    if [
        "block-solve", "build-blocks", "factor-blocks", "factor-folded-blocks", "fold-tendon",
        "fold-actuator", "fold-efc-sparse", "fold-contact-rank1",
      ].contains(key) {
      guard r.nblock > 0 else {
        fail("selected3x3 helper requires actual nonempty efm_dofid")
      }
    }
    if key == "efm0-solve" {
      guard r.nefm0 > 0 && r.nefm0L >= r.nefm0 else {
        fail("efm0 solve requires actual sparse factor metadata")
      }
    }
    if key.contains("tendon") {
      guard r.ntendon > 0 && r.tendon_nnz > 0 else {
        fail("selected tendon helper requires real rows")
      }
    }
    if key.contains("actuator") {
      guard r.nactuator > 0 && r.moment_nnz > 0 else {
        fail("selected actuator helper requires real rows")
      }
    }
    if key == "fold-efc-sparse" {
      guard r.sparse_jacobian && r.njmax > 0 && r.jacobian_nnz > 0 else {
        fail("sparse efc fold requires actual J rows")
      }
    }
    if key == "fold-contact-rank1" || key == "mul-contact" {
      guard r.ncon > 0 && r.contact_width > 0 else {
        fail(
          "selected contact helper requires actual rank1 contact descriptors",
        )
      }
    }
    if key == "zero-sleeping" {
      guard r.ntree > 0 else { fail("sleep mask requires actual tree mapping") }
    }
  }
}

///|
pub fn expected_shape(r : Request, name : String) -> Array[Int32] raise {
  let one = fn(n) { if n == 0 { 1 } else { n } }
  match name {
    "failure" | "skip" | "nefc" => [r.nworld]
    "nacon" => [1]
    "M_rownnz"
    | "M_rowadr"
    | "K_rownnz"
    | "K_rowadr"
    | "efm_dofblk"
    | "dof_treeid" => [r.nv]
    "M_colind" => [r.nC]
    "K_colind" => [one(r.nK)]
    "M" | "qH" | "efm_fluid" => [r.nworld, r.nC]
    "K_val" => [r.nworld, one(r.nK)]
    "efm_dofid" => [r.nblock]
    "epB" | "epL" | "efm_L" => [r.nworld, 9 * r.nblock]
    "efm0_dofid" | "efm0_L_rownnz" | "efm0_L_rowadr" => [r.nefm0]
    "efm0_L_colind" | "efm0_L" => [r.nefm0L]
    "ten_rownnz" | "ten_rowadr" => [r.ntendon]
    "ten_colind" => [r.tendon_nnz]
    "ten_J" => [r.nworld, r.tendon_nnz]
    "efm_ts" => [r.nworld, r.ntendon]
    "moment_rownnz" | "moment_rowadr" | "efm_as" => [r.nworld, r.nactuator]
    "moment_colind" | "actuator_moment" => [r.nworld, r.moment_nnz]
    "efc_J_rownnz" | "efc_J_rowadr" | "efc_D" => [r.nworld, r.njmax]
    "efc_J_colind" => [r.nworld, 1, r.jacobian_nnz]
    "efc_J" =>
      if r.sparse_jacobian {
        [r.nworld, 1, r.jacobian_nnz]
      } else {
        [r.nworld, r.njmax, r.nv]
      }
    "contact_worldid" | "contact_nnz" | "contact_scale" => [r.ncon]
    "contact_dof" | "contact_val" => [r.ncon, r.contact_width]
    "tree_awake" => [r.nworld, r.ntree]
    "M_mulm_rowadr" => [r.nv + 1]
    "M_mulm_col" | "M_mulm_madr" => [2 * r.nC - r.nv]
    "qfrc_smooth"
    | "efm_c"
    | "efm_ca"
    | "effective_force"
    | "vec"
    | "res"
    | "rhs"
    | "efm_diag" => [r.nworld, r.nv]
    _ => fail("unknown metric array: " + name)
  }
}

///|
fn params(r : Request, key : String) -> Array[Parameter] raise {
  let lists : Map[String, Array[String]] = Map([
    ("effective-force", ["qfrc_smooth", "efm_c", "efm_ca", "effective_force"]),
    ("zero-sleeping", ["dof_treeid", "tree_awake", "res"]),
    ("copy-backbone-rhs", ["efm_dofblk", "rhs", "res"]),
    ("block-solve", ["efm_dofid", "efm_L", "rhs", "res"]),
    (
      "efm0-solve",
      [
        "efm0_dofid", "efm0_L_rownnz", "efm0_L_rowadr", "efm0_L_colind", "efm0_L",
        "rhs", "res",
      ],
    ),
    (
      "build-blocks",
      [
        "M_rownnz", "M_rowadr", "M_colind", "K_rownnz", "K_rowadr", "K_colind", "efm_dofid",
        "M", "K_val", "epB",
      ],
    ),
    (
      "factor-blocks",
      [
        "M_rownnz", "M_rowadr", "M_colind", "K_rownnz", "K_rowadr", "K_colind", "efm_dofid",
        "M", "K_val", "efm_L",
      ],
    ),
    ("factor-folded-blocks", ["epB", "epL"]),
    (
      "fold-tendon",
      [
        "ten_rownnz", "ten_rowadr", "ten_colind", "efm_dofid", "efm_dofblk", "ten_J",
        "efm_ts", "epB",
      ],
    ),
    (
      "fold-actuator",
      [
        "efm_dofid", "efm_dofblk", "moment_rownnz", "moment_rowadr", "moment_colind",
        "actuator_moment", "efm_as", "epB",
      ],
    ),
    (
      "fold-efc-sparse",
      [
        "efm_dofid", "efm_dofblk", "nefc", "efc_J_rownnz", "efc_J_rowadr", "efc_J_colind",
        "efc_J", "efc_D", "epB",
      ],
    ),
    (
      "fold-contact-rank1",
      [
        "efm_dofid", "efm_dofblk", "contact_worldid", "nacon", "contact_dof", "contact_val",
        "contact_scale", "contact_nnz", "epB",
      ],
    ),
    ("mul-diag", ["efm_diag", "vec", "res"]),
    (
      "mul-diag-csr",
      ["K_rownnz", "K_rowadr", "K_colind", "efm_diag", "K_val", "vec", "res"],
    ),
    (
      "mul-tendon",
      [
        "ten_rownnz", "ten_rowadr", "ten_colind", "ten_J", "efm_ts", "vec", "res",
      ],
    ),
    (
      "mul-actuator",
      [
        "moment_rownnz", "moment_rowadr", "moment_colind", "actuator_moment", "efm_as",
        "vec", "res",
      ],
    ),
    (
      "mul-contact",
      [
        "contact_worldid", "contact_dof", "contact_val", "contact_scale", "contact_nnz",
        "vec", "res",
      ],
    ),
    (
      "mul-fluid",
      ["M_mulm_rowadr", "M_mulm_col", "M_mulm_madr", "efm_fluid", "vec", "res"],
    ),
    ("add-qh-diag", ["M_rownnz", "M_rowadr", "efm_diag", "qH"]),
    (
      "add-tendon-qh-diag",
      [
        "ten_rownnz", "ten_rowadr", "ten_colind", "M_rownnz", "M_rowadr", "ten_J",
        "efm_ts", "qH",
      ],
    ),
    (
      "add-actuator-qh-diag",
      [
        "M_rownnz", "M_rowadr", "moment_rownnz", "moment_rowadr", "moment_colind",
        "actuator_moment", "efm_as", "qH",
      ],
    ),
    ("add-fluid-qh", ["efm_fluid", "qH"]),
  ])
  guard lists.get(key) is Some(original) else { fail("unknown metric helper") }
  let names = original.copy()
  if key == "build-blocks" && !r.sparse_jacobian && r.njmax > 0 {
    names.append(["nefc", "efc_J", "efc_D"])
  }
  if key == "effective-force" && r.sleep {
    names.append(["dof_treeid", "tree_awake"])
  }
  names.push("failure")
  if r.check_skip {
    names.push("skip")
  }
  let integers = [
    "failure", "nefc", "nacon", "M_rownnz", "M_rowadr", "M_colind", "K_rownnz", "K_rowadr",
    "K_colind", "efm_dofid", "efm_dofblk", "dof_treeid", "tree_awake", "efm0_dofid",
    "efm0_L_rownnz", "efm0_L_rowadr", "efm0_L_colind", "ten_rownnz", "ten_rowadr",
    "ten_colind", "moment_rownnz", "moment_rowadr", "moment_colind", "efc_J_rownnz",
    "efc_J_rowadr", "efc_J_colind", "contact_worldid", "contact_nnz", "contact_dof",
    "M_mulm_rowadr", "M_mulm_col", "M_mulm_madr",
  ]
  let outputs = match key {
    "effective-force" => ["effective_force"]
    "block-solve" | "efm0-solve" | "copy-backbone-rhs" | "zero-sleeping" =>
      ["res"]
    "factor-blocks" => ["efm_L"]
    "factor-folded-blocks" => ["epL"]
    _ =>
      if key.has_prefix("fold-") || key == "build-blocks" {
        ["epB"]
      } else if key.has_prefix("add-") {
        ["qH"]
      } else {
        ["res"]
      }
  }
  names.map(name => {
    let dtype = if name == "skip" {
      "bool"
    } else if integers.contains(name) {
      "int32"
    } else {
      "float32"
    }
    let shape = expected_shape(r, name)
    {
      name,
      dtype,
      kind: "array",
      rank: shape.length(),
      c_type: "wp::array_t<" +
      (if dtype == "bool" { "bool" } else { "wp::" + dtype }) +
      ">",
      access: if name == "failure" || outputs.contains(name) {
        "inout"
      } else {
        "input"
      },
    }
  })
}
