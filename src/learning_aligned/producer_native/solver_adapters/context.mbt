///|
/// CPU-owned byte storage for the actual upstream workspace constructors.
/// These are input/ownership buffers, not a live GPU SolverContext transaction.
pub(all) struct Workspace {
  name : String
  scalar_type : String
  shape : Array[Int32]
  bytes : Bytes
  initialization : String
}

///|
pub(all) struct ContextRequest {
  nworld : Int32
  nv : Int32
  nv_pad : Int32
  njmax : Int32
  solver : String
  incremental : Bool
} derive(FromJson, ToJson)

///|
fn workspace(
  name : String,
  shape : Array[Int32],
  dtype : String,
  source_zero : Bool,
) -> Workspace raise {
  let width = if dtype == "bool" { 1 } else { 4 }
  let mut count = width
  for n in shape {
    guard n >= 0 && (n == 0 || count <= 2147483647 / n) else {
      fail("host workspace byte capacity overflow")
    }
    count *= n
  }
  {
    name,
    scalar_type: dtype,
    shape,
    bytes: Bytes::make(count, 0),
    initialization: if source_zero {
      "source-zero-initialized"
    } else {
      "source-empty-storage-zeroed-on-host; actual-init-kernel-required"
    },
  }
}

///|
/// Faithful allocation shape/optional-array choices of _create_solver_context.
/// For our serial reference backend factor is additional storage even nv<=32;
/// callers obtain that separate native workspace using native_control_buffers.
pub fn allocate_solver_context(r : ContextRequest) -> Array[Workspace] raise {
  guard r.nworld > 0 &&
    r.nv >= 0 &&
    r.nv_pad >= r.nv &&
    r.njmax >= 0 &&
    ["newton", "cg"].contains(r.solver) &&
    (!r.incremental || r.solver == "newton") else {
    fail("invalid source solver context allocation")
  }
  let w = r.nworld
  let h = r.solver == "newton"
  let cg = r.solver == "cg"
  let out = []
  for name in ["Jaref", "jv"] {
    out.push(workspace(name, [w, r.njmax], "float32", false))
  }
  out.push(workspace("quad", [w, r.njmax, 3], "float32", false))
  out.push(workspace("done", [w], "bool", false))
  out.push(workspace("ls_exhausted", [w], "bool", true))
  out.push(workspace("search_unchanged", [w], "bool", false))
  for
    name in [
      "search_dot", "grad_dot", "newton_decrement", "alpha", "grad_scale", "improvement",
    ] {
    out.push(workspace(name, [w], "float32", false))
  }
  out.push(workspace("grad", [w, r.nv_pad], "float32", true))
  out.push(
    workspace("Mgrad", [w, if cg { r.nv_pad } else { 0 }], "float32", false),
  )
  for name in ["search", "mv"] {
    out.push(workspace(name, [w, r.nv], "float32", false))
  }
  for name in ["prev_grad", "prev_Mgrad"] {
    out.push(workspace(name, [w, if cg { r.nv } else { 0 }], "float32", false))
  }
  out.push(workspace("beta", [if cg { w } else { 0 }], "float32", false))
  out.push(
    workspace(
      "h",
      [w, if h { r.nv_pad } else { 0 }, if h { r.nv_pad } else { 0 }],
      "float32",
      false,
    ),
  )
  out.push(
    workspace(
      "hfactor",
      [
        w,
        if h && r.nv > 32 {
          r.nv_pad
        } else {
          0
        },
        if h && r.nv > 32 {
          r.nv_pad
        } else {
          0
        },
      ],
      "float32",
      false,
    ),
  )
  out.push(
    workspace(
      "quad_changed_ids",
      [w, if r.incremental { r.njmax } else { 0 }],
      "int32",
      false,
    ),
  )
  for name in ["quad_changed_count", "state_changed_count"] {
    out.push(
      workspace(name, [if r.incremental { w } else { 0 }], "int32", false),
    )
  }
  out
}

///|
/// Actual create_inverse_context array shapes, including intentionally empty
/// change queues/counters. Host buffers have no GPU/APIC identity until imported.
pub fn allocate_inverse_context(
  nworld : Int32,
  njmax : Int32,
) -> Array[Workspace] raise {
  guard nworld > 0 && njmax >= 0 else {
    fail("invalid source inverse context allocation")
  }
  [
    workspace("Jaref", [nworld, njmax], "float32", false),
    workspace("search_dot", [nworld], "float32", false),
    workspace("done", [nworld], "bool", false),
    workspace("quad_changed_ids", [nworld, 0], "int32", false),
    workspace("quad_changed_count", [0], "int32", false),
    workspace("state_changed_count", [0], "int32", false),
    workspace("ls_exhausted", [0], "bool", false),
  ]
}

///|
/// Real canonical native control storage plus the serial backend's complete
/// factor scratch. Status/overflow remain sticky after this initial allocation;
/// graph replay uses the actual initialize-controls kernel rather than host reset.
pub fn native_control_buffers(
  nworld : Int32,
  nv : Int32,
) -> Array[Workspace] raise {
  guard nworld > 0 && nv >= 0 else {
    fail("invalid native control storage dimensions")
  }
  let value = nworld.reinterpret_as_uint()
  let count : Workspace = {
    name: "nsolving",
    scalar_type: "int32",
    shape: [1],
    bytes: Bytes::makei(4, i => (value >> (i * 8)).to_byte()),
    initialization: "actual-world-count-little-endian",
  }
  [
    workspace("ctx_done", [nworld], "bool", true),
    workspace("solver_niter", [nworld], "int32", true),
    workspace("status", [nworld], "int32", true),
    workspace("overflow", [nworld], "int32", true),
    count,
    workspace("factor", [nworld, nv, nv], "float32", false),
  ]
}
