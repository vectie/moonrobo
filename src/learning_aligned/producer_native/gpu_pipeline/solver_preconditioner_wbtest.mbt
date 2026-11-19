///|
// Structural proof regression definitions only; not executed during migration.
// These in-memory fixtures exercise ownership rejection, never a native module.
fn pending_cg_view(name : String) -> View {
  {
    buffer: name,
    dtype: "float32",
    shape: [1, 3],
    byte_strides: [12, 4],
    offset_bytes: 0UL,
  }
}

///|
#warnings("-reserved_keyword")
fn pending_cg_call(name : String, rhs : String) -> Call {
  {
    module: name,
    entry: {
      key: "block-solve",
      forward: "unused_fixture",
      shape: [1],
      parameters: [],
    },
    arguments: [],
    named: Map([
      ("rhs", pending_cg_view(rhs)),
      ("res", pending_cg_view("Mgrad")),
      (
        "skip",
        {
          buffer: "done",
          dtype: "bool",
          shape: [1],
          byte_strides: [1],
          offset_bytes: 0UL,
        },
      ),
    ]),
  }
}

///|
fn pending_cg_module(id : String, kind : String, request : Json) -> Module {
  {
    id,
    kind,
    request,
    manifest: b"",
    manifest_sha256: "",
    source: b"",
    source_name: "",
    source_sha256: "",
    image: b"",
    image_kind: "cubin",
    image_sha256: "",
    specialization_sha256: "",
    entries: Map([]),
    policy: {
      block_dim: 256,
      forward_smem: 0,
      backward_smem: 0,
      grid_stride: false,
      coord_mult: 1,
    },
    notice: None,
  }
}

///|
test "pending CG proof rejects actual gradient/result mislink" {
  let request : Json = {
    "nworld": 1,
    "nv": 3,
    "nC": 6,
    "nK": 0,
    "nblock": 1,
    "nefm0": 0,
    "nefm0L": 0,
    "ntendon": 0,
    "tendon_nnz": 0,
    "nactuator": 0,
    "moment_nnz": 0,
    "njmax": 0,
    "jacobian_nnz": 0,
    "ncon": 0,
    "contact_width": 0,
    "ntree": 0,
    "sparse_jacobian": false,
    "sleep": false,
    "check_skip": true,
    "architecture": 80,
    "kernels": ["block-solve"],
  }
  let core : Json = {
    "nworld": 1,
    "nv": 3,
    "njmax": 1,
    "ncon": 0,
    "mass_nnz": 0,
    "jacobian_capacity": 0,
    "iterations": 0,
    "ls_iterations": 1,
    "solver": "cg",
    "jacobian_layout": "dense",
    "mass_layout": "dense",
    "cone": "pyramidal",
    "warmstart": false,
    "kernels": ["cg-search-init"],
  }
  let modules = Map([
    (
      "metric",
      pending_cg_module(
        "metric", "moonrobo-native-solver-metrics-module-v1", request,
      ),
    ),
    (
      "core",
      pending_cg_module("core", "moonrobo-native-newton-solver-module-v1", core),
    ),
  ])
  let done : Json = {
    "buffer": "done",
    "dtype": "bool",
    "shape": [1],
    "byte_strides": [1],
    "offset_bytes": 0,
  }
  let views = Map([
    ("ctx_grad", pending_cg_view("grad").to_json()),
    ("ctx_Mgrad", pending_cg_view("Mgrad").to_json()),
    ("ctx_done", done),
  ])
  try
    cg_operator_plan(
      [Kernel(pending_cg_call("metric", "wrong-gradient"))],
      pending_cg_call("core", "grad"),
      modules,
      views,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("mislinked actual gradient accepted")
  }
}

///|
test "pending CG proof rejects changing actual helper view" {
  let views : Map[String, Json] = Map([])
  try
    cg_metric_views(
      [
        Kernel(pending_cg_call("metric", "first")),
        Kernel(pending_cg_call("metric", "second")),
      ],
      "metric",
      views,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("helper changed original RHS owner")
  }
}

///|
fn pending_proof_call(
  id : String,
  key : String,
  ps : Array[Parameter],
  views : Map[String, View],
) -> Call {
  let named : Map[String, View] = Map([])
  for p in ps {
    named[p.name] = views[p.name]
  }
  {
    module: id,
    entry: {
      key,
      forward: "unused_structural_fixture",
      shape: [1],
      parameters: ps,
    },
    arguments: [],
    named,
  }
}

///|
test "pending canonical Newton rejects convergence-only WHILE" {
  // Real signature/planner metadata; no matrix values, device or numerical solve.
  let request : @newton_solver.Request = {
    nworld: 1,
    nv: 3,
    njmax: 1,
    ncon: 0,
    mass_nnz: 0,
    jacobian_capacity: 0,
    iterations: 2,
    ls_iterations: 1,
    solver: "newton",
    jacobian_layout: "dense",
    mass_layout: "dense",
    cone: "pyramidal",
    warmstart: false,
    kernels: [
      "initialize-controls", "initialize-state", "constraint-gradient-hessian", "factor-direction",
      "line-search",
    ],
  }
  let core = @newton_solver.lower(request)
  let transition : @device_convergence.Request = {
    nworld: 1,
    nv: 3,
    iterations: 2,
    warn_overflow: 0,
    kernels: ["newton-done-with-ls"],
  }
  let tail = @device_convergence.lower(transition)
  let signatures : Map[String, Array[Parameter]] = Map([])
  for entry in core.entries {
    signatures[entry.key] = @json.from_json(Json(entry.parameters))
  }
  signatures["newton-done-with-ls"] = @json.from_json(
    Json(tail.entries[0].parameters),
  )
  let views : Map[String, View] = Map([])
  for _, ps in signatures {
    for p in ps {
      if !views.contains(p.name) {
        let width = if p.dtype == "bool" {
          1
        } else if p.dtype == "vec5f" {
          20
        } else {
          4
        }
        views[p.name] = {
          buffer: p.name,
          dtype: p.dtype,
          shape: Array::make(p.rank, 1),
          byte_strides: Array::make(p.rank, width),
          offset_bytes: 0UL,
        }
      }
    }
  }
  let modules = Map([
    (
      "newton",
      pending_cg_module(
        "newton",
        "moonrobo-native-newton-solver-module-v1",
        Json(request),
      ),
    ),
    (
      "tail",
      pending_cg_module(
        "tail",
        "moonrobo-device-convergence-module-v1",
        Json(transition),
      ),
    ),
  ])
  let initial = [
    "initialize-controls", "initialize-state", "constraint-gradient-hessian", "factor-direction",
  ].map(key => Kernel(pending_proof_call("newton", key, signatures[key], views)))
  let body = ["line-search", "constraint-gradient-hessian", "factor-direction"].map(key => {
      Kernel(pending_proof_call("newton", key, signatures[key], views))
    },
  )
  let finish = Kernel(
    pending_proof_call(
      "tail",
      "newton-done-with-ls",
      signatures["newton-done-with-ls"],
      views,
    ),
  )
  body.push(finish)
  let good = initial.copy()
  good.push(While(views["nsolving"], body))
  validate_reference_newton_order(good, modules)
  let bad = initial.copy()
  bad.push(While(views["nsolving"], [finish]))
  try validate_reference_newton_order(bad, modules) catch {
    _ => ()
  } noraise {
    _ => fail("convergence tail without Newton iteration body accepted")
  }
}
