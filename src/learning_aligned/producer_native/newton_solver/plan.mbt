///|
fn launch(
  module : String,
  key : String,
  ps : Array[Parameter],
  views : Map[String, Json],
) -> Json raise {
  let arguments : Map[String, Json] = {}
  for p in ps {
    guard views.get(p.name) is Some(view) else {
      fail("missing planned solver view: " + p.name)
    }
    arguments[p.name] = view
  }
  {
    "operation": "launch",
    "parameters": {
      "module": Json(module),
      "entry": Json(key),
      "arguments": Json(arguments),
    },
  }
}

///|
/// Actual source-derived initial/iteration order, expressed as native pipeline
/// commands. The planner never executes a kernel, solver or numeric example.
pub fn plan(config : PlanRequest) -> Json raise {
  plan_impl(config, None)
}

///|
/// Composes the actual native preconditioner stages supplied by the operator
/// backend. They must be authenticated/validated by the pipeline just like all
/// other modules. No matrix inverse or effective-mass surrogate is fabricated.
pub fn plan_with_preconditioner(
  config : PlanRequest,
  program : Array[Json],
) -> Json raise {
  guard config.request.solver == "cg" && !program.is_empty() else {
    fail("external native preconditioner is a nonempty CG-only program")
  }
  for command in program {
    guard command is Object(fields) &&
      fields.length() == 2 &&
      fields.contains("operation") &&
      fields.contains("parameters") &&
      [Json("launch"), Json("copy"), Json("zero")].contains(fields["operation"]) else {
      fail(
        "preconditioner stages must be explicit native launch/copy/zero commands",
      )
    }
  }
  plan_impl(config, Some(program))
}

///|
/// Typed linkage of the actual derivative.eff_prec operator. This validates
/// the live RHS/result/done identities before building its source-derived chain;
/// module identity, frozen topology and status gates remain pipeline obligations.
pub fn plan_with_effective_preconditioner(
  config : PlanRequest,
  operator : @solver_metrics.PreconditionerPlan,
) -> Json raise {
  let r = config.request
  guard r.solver == "cg" &&
    operator.request.nworld == r.nworld &&
    operator.request.nv == r.nv &&
    operator.request.check_skip else {
    fail(
      "effective CG operator requires matching world/DOF shape and actual done guard",
    )
  }
  for
    (a, b) in [("rhs", "ctx_grad"), ("res", "ctx_Mgrad"), ("skip", "ctx_done")] {
    guard operator.views.get(a) is Some(v) && config.views.get(b) == Some(v) else {
      fail("effective CG operator must bind the actual live state: " + a)
    }
  }
  plan_with_preconditioner(
    config,
    @solver_metrics.preconditioner_plan(operator),
  )
}

///|
fn plan_impl(config : PlanRequest, preconditioner : Array[Json]?) -> Json raise {
  let r = config.request
  let lowered = lower(r)
  guard !config.module.is_empty() &&
    (
      r.iterations == 0 ||
      r.njmax == 0 ||
      r.nv == 0 ||
      (
        !config.convergence_module.is_empty() &&
        config.convergence_module != config.module
      )
    ) else {
    fail("distinct real solver and convergence module identities required")
  }
  let entries : Map[String, Entry] = {}
  for e in lowered.entries {
    entries[e.key] = e
  }
  let initial : Array[Json] = []
  let final : Array[Json] = []
  let program : Array[Json] = []
  if r.njmax == 0 || r.nv == 0 {
    let call = launch(
      config.module,
      "unconstrained",
      entries["unconstrained"].parameters,
      config.views,
    )
    initial.push(call)
    program.push(call)
    return {
      "format": "moonrobo-native-newton-program-v1",
      "request": r.to_json(),
      "initial": Json(initial),
      "iteration": [],
      "final": Json(final),
      "program": Json(program),
      "convergence_request": Json(null),
      "zero_constraint_or_dof_branch": true,
      "full_model_dynamics_generated": false,
      "runtime_equivalence_verified": false,
    }
  }
  let required = [
    "initialize-controls", "initialize-state", "constraint-gradient-hessian",
  ]
  if preconditioner is None {
    required.push("factor-direction")
  }
  if r.iterations > 0 {
    required.push("line-search")
  }
  if r.solver == "cg" {
    required.push("cg-search-init")
  }
  for key in required {
    guard entries.contains(key) else {
      fail("complete reference iteration plan requires compiled kernel: " + key)
    }
  }
  for
    key in [
      "initialize-controls", "initialize-state", "constraint-gradient-hessian",
    ] {
    initial.push(
      launch(config.module, key, entries[key].parameters, config.views),
    )
  }
  match preconditioner {
    Some(stages) => initial.append(stages)
    None =>
      initial.push(
        launch(
          config.module,
          "factor-direction",
          entries["factor-direction"].parameters,
          config.views,
        ),
      )
  }
  if r.solver == "cg" {
    initial.push(
      launch(
        config.module,
        "cg-search-init",
        entries["cg-search-init"].parameters,
        config.views,
      ),
    )
  }
  program.append(initial)
  let iteration : Array[Json] = []
  let mut convergence_request : Json = Json(null)
  if r.iterations > 0 {
    let key = if r.solver == "cg" {
      "cg-beta-search-finalize"
    } else {
      "newton-done-with-ls"
    }
    let request : @device_convergence.Request = {
      nworld: r.nworld,
      nv: r.nv,
      iterations: r.iterations,
      warn_overflow: 0,
      kernels: [key],
    }
    let convergence = @device_convergence.lower(request)
    convergence_request = request.to_json()
    for name in ["line-search", "constraint-gradient-hessian"] {
      iteration.push(
        launch(config.module, name, entries[name].parameters, config.views),
      )
    }
    match preconditioner {
      Some(stages) => iteration.append(stages)
      None =>
        iteration.push(
          launch(
            config.module,
            "factor-direction",
            entries["factor-direction"].parameters,
            config.views,
          ),
        )
    }
    let args : Map[String, Json] = {}
    for p in convergence.entries[0].parameters {
      guard config.views.get(p.name) is Some(view) else {
        fail("missing actual convergence view: " + p.name)
      }
      args[p.name] = view
    }
    iteration.push({
      "operation": "launch",
      "parameters": {
        "module": Json(config.convergence_module),
        "entry": Json(key),
        "arguments": Json(args),
      },
    })
    guard config.views.get("nsolving") is Some(predicate) else {
      fail("real nsolving predicate view required")
    }
    program.push({
      "operation": "while",
      "parameters": { "condition": predicate, "body": Json(iteration) },
    })
  }
  {
    "format": "moonrobo-native-newton-program-v1",
    "request": r.to_json(),
    "initial": Json(initial),
    "iteration": Json(iteration),
    "final": Json(final),
    "program": Json(program),
    "convergence_request": convergence_request,
    "required_initial_control_state": {
      "ctx_done": "all-false",
      "solver_niter": "all-zero",
      "nsolving": Json(r.nworld),
      "status": "all-zero",
      "overflow": "existing-nonnegative-bitmask",
    },
    "solver_niter_reset_owner": "actual-top-level-initialize-controls-kernel",
    "factor_backend": Json(
      if preconditioner is Some(_) {
        "explicit-authenticated-native-preconditioner-program"
      } else {
        "actual-serial-dense-cholesky-on-complete-H-or-authored-preconditioner"
      },
    ),
    "incremental_fast_path": false,
    "compact_or_sleep_adapter_generated": false,
    "effective_mass_metric_construction": "caller-authored-base-M-plus-explicit-added_metric",
    "constraint_construction": "caller-authored-real-J-D-aref-partitions-and-contact-mappings",
    "supported_reference_iteration_body_generated": true,
    "full_model_dynamics_generated": false,
    "full_upstream_solver_closure": false,
    "runtime_equivalence_verified": false,
  }
}
