///|
/// The substituted program must contain actual authenticated native stages.
/// Its mathematical operator is owned by its backend, not inferred from names.
pub(all) struct CompactPlan {
  request : Request
  module_name : String
  views : Map[String, Json]
  solve_program : Array[Json]
} derive(FromJson, ToJson)

///|
pub extend CompactPlan with @json.FromJson::{from_json}

///|
fn stage(
  r : Request,
  module_name : String,
  key : String,
  views : Map[String, Json],
) -> Json raise {
  guard r.kernels.contains(key) && !module_name.is_empty() else {
    fail("adapter stage is not compiled or module is missing: " + key)
  }
  let args : Map[String, Json] = {}
  for p in parameters(r, key) {
    guard views.get(p.name) is Some(v) else {
      fail("missing real adapter view: " + p.name)
    }
    args[p.name] = v
  }
  {
    "operation": "launch",
    "parameters": {
      "module": Json(module_name),
      "entry": Json(key),
      "arguments": Json(args),
    },
  }
}

///|
fn explicit_program(program : Array[Json]) -> Unit raise {
  guard !program.is_empty() else {
    fail("an empty program cannot replace actual factor/solve")
  }
  for command in program {
    guard command is Object(f) &&
      f.length() == 2 &&
      f.contains("parameters") &&
      [Json("launch"), Json("copy"), Json("zero"), Json("while"), Json("if")].contains(
        f["operation"],
      ) else {
      fail("expected explicit native program commands")
    }
  }
}

///|
/// Source smooth_solve_compact order, using the caller's real native Cholesky
/// factor/solve stages on M_c/rhs_c, then scattering actual solution_c.
pub fn compact_smooth_plan(c : CompactPlan) -> Array[Json] raise {
  validate(c.request)
  explicit_program(c.solve_program)
  let result = []
  for
    key in ["compact-inertia-init", "compact-mass-gather", "compact-rhs-gather"] {
    result.push(stage(c.request, c.module_name, key, c.views))
  }
  result.append(c.solve_program)
  result.push(
    stage(c.request, c.module_name, "compact-solution-scatter", c.views),
  )
  result
}

///|
/// Full dense compact reference path: actual M/J/vectors gather, supplied
/// native constraint solve, qacc/qfrc scatter, and full-coordinate Ma refresh.
/// Callers bind vec_full to scattered qacc_full and res_full to the true full Ma.
pub fn compact_constraint_plan(c : CompactPlan) -> Array[Json] raise {
  validate(c.request)
  explicit_program(c.solve_program)
  guard c.views.get("vec_full") == c.views.get("qacc_full") &&
    c.views.contains("vec_full") else {
    fail("full Ma refresh must read the actual scattered qacc")
  }
  let result = []
  for
    key in [
      "compact-inertia-init", "compact-mass-gather", "compact-jacobian-gather", "compact-vectors-gather",
    ] {
    result.push(stage(c.request, c.module_name, key, c.views))
  }
  result.append(c.solve_program)
  for key in ["compact-vectors-scatter", "full-mass-multiply"] {
    result.push(stage(c.request, c.module_name, key, c.views))
  }
  result
}

///|
pub(all) struct IncrementalPlan {
  solver : @newton_solver.PlanRequest
  request : Request
  module_name : String
  views : Map[String, Json]
} derive(FromJson, ToJson)

///|
pub extend IncrementalPlan with @json.FromJson::{from_json}

///|
/// Typed real operator linkage for the preferred CPU-free CG launch planner.
pub(all) struct EffectiveCGPlan {
  solver : @newton_solver.PlanRequest
  operator : @solver_metrics.PreconditionerPlan
} derive(FromJson)

///|
pub extend EffectiveCGPlan with @json.FromJson::{from_json}

///|
pub fn effective_cg_plan(c : EffectiveCGPlan) -> Json raise {
  @newton_solver.plan_with_effective_preconditioner(c.solver, c.operator)
}

///|
/// Actual incremental Newton body. Initial H/factor is built by the genuine
/// core kernels; changed rows update H, unchanged factors/search are reused,
/// and the real bounded convergence tail remains the final unconditional node.
pub fn incremental_plan(c : IncrementalPlan) -> Json raise {
  let r = c.solver.request
  validate(c.request)
  guard r.solver == "newton" &&
    r.cone == "pyramidal" &&
    r.nv > 0 &&
    r.njmax > 0 &&
    r.nworld == c.request.nworld &&
    r.nv == c.request.nv_compact &&
    r.njmax == c.request.njmax &&
    r.kernels.contains("line-search-incremental") else {
    fail(
      "incremental schedule requires matching real nonelliptic Newton profile",
    )
  }
  let mappings = [
    ("status", "status"),
    ("ctx_done", "ctx_done"),
    ("ne", "ne"),
    ("nf", "nf"),
    ("nefc", "nefc"),
    ("efc_type", "efc_type"),
    ("D", "efc_D"),
    ("frictionloss", "efc_frictionloss"),
    ("ctx_Jaref", "ctx_Jaref"),
    ("force", "efc_force"),
    ("state", "efc_state"),
    ("ctx_ls_exhausted", "ctx_ls_exhausted"),
    ("ctx_grad", "ctx_grad"),
    ("ctx_Mgrad", "ctx_Mgrad"),
    ("ctx_search", "ctx_search"),
    ("ctx_grad_dot", "ctx_grad_dot"),
    ("ctx_newton_decrement", "ctx_newton_decrement"),
    ("ctx_search_dot", "ctx_search_dot"),
    ("ctx_alpha", "ctx_alpha"),
    ("ctx_Ma", "ctx_Ma"),
    ("qfrc_smooth", "qfrc_smooth"),
    ("qfrc_constraint", "qfrc_constraint"),
    ("hessian", "hessian"),
    ("factor", "factor"),
  ]
  for (a, b) in mappings {
    guard c.views.get(a) is Some(v) && c.solver.views.get(b) == Some(v) else {
      fail("incremental/core state must be the same actual view: " + a)
    }
  }
  if !c.request.compact {
    guard c.views.get("J") == c.solver.views.get("efc_J") &&
      c.views.contains("J") &&
      c.request.nv == r.nv &&
      c.request.jacobian_layout == r.jacobian_layout else {
      fail("uncompacted incremental Jacobian must match core input")
    }
  } else {
    guard r.mass_layout == "dense" && r.jacobian_layout == "dense" else {
      fail("compact reference initialization reads actual gathered dense M/J")
    }
    for
      (a, b) in [
        ("M_c", "M_dense_in"),
        ("J_c", "efc_J"),
        ("qacc_warmstart_c", "qacc_warmstart"),
        ("qacc_smooth_c", "qacc_smooth"),
        ("qfrc_smooth_c", "qfrc_smooth"),
        ("qacc_c", "qacc"),
        ("qfrc_constraint_c", "qfrc_constraint"),
      ] {
      guard c.views.get(a) is Some(v) && c.solver.views.get(b) == Some(v) else {
        fail("compact/core state must be the same actual view: " + a)
      }
    }
    guard c.views.get("vec_full") == c.views.get("qacc_full") &&
      c.views.contains("vec_full") else {
      fail("compact final Ma refresh must use actual scattered acceleration")
    }
  }
  let base = @newton_solver.plan(c.solver)
  guard base is Object(fields) &&
    fields["initial"] is Array(initial) &&
    fields["iteration"] is Array(old_iteration) else {
    fail("unexpected native core program schema")
  }
  let first : Array[Json] = []
  if c.request.compact {
    for
      key in [
        "compact-inertia-init", "compact-mass-gather", "compact-jacobian-gather",
        "compact-vectors-gather",
      ] {
      first.push(stage(c.request, c.module_name, key, c.views))
    }
  }
  first.append(initial)
  first.push(stage(c.request, c.module_name, "incremental-initialize", c.views))
  let iteration : Array[Json] = []
  let program = first.copy()
  if r.iterations > 0 {
    let entries = @newton_solver.lower(r).entries
    let selected = entries.filter(e => e.key == "line-search-incremental")
    guard selected.length() == 1 else {
      fail("actual incremental linesearch kernel not compiled")
    }
    let entry = selected[0]
    let args : Map[String, Json] = {}
    for p in entry.parameters {
      guard c.solver.views.get(p.name) is Some(v) else {
        fail("missing core incremental linesearch view")
      }
      args[p.name] = v
    }
    iteration.push({
      "operation": "launch",
      "parameters": {
        "module": Json(c.solver.module),
        "entry": "line-search-incremental",
        "arguments": Json(args),
      },
    })
    for
      key in [
        "incremental-zero-changes", "incremental-constraint-update", "incremental-qfrc-rebuild",
        "incremental-gradient-update", "incremental-hessian-update", "incremental-factor-direction",
      ] {
      iteration.push(stage(c.request, c.module_name, key, c.views))
    }
    guard !old_iteration.is_empty() &&
      c.solver.views.get("nsolving") is Some(predicate) else {
      fail("true source convergence tail/predicate required")
    }
    iteration.push(old_iteration[old_iteration.length() - 1])
    program.push({
      "operation": "while",
      "parameters": { "condition": predicate, "body": Json(iteration) },
    })
  }
  let final = [stage(c.request, c.module_name, "recover-qfrc", c.views)]
  if c.request.compact {
    for key in ["compact-vectors-scatter", "full-mass-multiply"] {
      final.push(stage(c.request, c.module_name, key, c.views))
    }
  }
  program.append(final)
  {
    "format": "moonrobo-native-incremental-newton-program-v1",
    "initial": Json(first),
    "iteration": Json(iteration),
    "final": Json(final),
    "program": Json(program),
    "convergence_request": fields["convergence_request"],
    "shared_sticky_status": true,
    "full_upstream_solver_closure": false,
    "runtime_equivalence_verified": false,
  }
}
