///|
fn cg_metric_views(
  ops : Array[Op],
  module_name : String,
  views : Map[String, Json],
) -> Unit raise {
  for op in ops {
    guard op is Kernel(call) else {
      fail("effective CG preconditioner must use genuine helper launches")
    }
    if call.module == module_name {
      for name, view in call.named {
        let value = view.to_json()
        if views.get(name) is Some(previous) {
          guard previous == value else {
            fail("effective CG helper changed a live owned view: " + name)
          }
        } else {
          views[name] = value
        }
      }
    }
  }
}

///|
fn cg_operator_plan(
  ops : Array[Op],
  first : Call,
  modules : Map[String, Module],
  core_views : Map[String, Json],
) -> @solver_metrics.PreconditionerPlan raise {
  let metric_name = Ref("")
  let mixed_name = Ref("")
  let folded = Ref(false)
  let contact = Ref(false)
  let efm0 = Ref(false)
  for op in ops {
    guard op is Kernel(call) else {
      fail("unrecognized CG preconditioner command")
    }
    match modules[call.module].kind {
      "moonrobo-native-solver-metrics-module-v1" => {
        guard metric_name.val.is_empty() || metric_name.val == call.module else {
          fail("one canonical metric specialization per CG operator")
        }
        metric_name.val = call.module
        if call.entry.key == "build-blocks" {
          folded.val = true
        }
        if call.entry.key == "fold-contact-rank1" {
          contact.val = true
        }
        if call.entry.key == "efm0-solve" {
          efm0.val = true
        }
      }
      "moonrobo-native-mixed-sparse-solver-module-v1" => {
        guard call.entry.key == "mixed-solve" &&
          (mixed_name.val.is_empty() || mixed_name.val == call.module) else {
          fail("CG backbone must be the genuine mixed solve")
        }
        mixed_name.val = call.module
      }
      _ =>
        fail(
          "external CG preconditioning requires the recognized genuine metric/mixed operator family",
        )
    }
  }
  guard !metric_name.val.is_empty() else {
    fail("missing genuine effective CG operator")
  }
  let request : @solver_metrics.Request = @json.from_json(
    modules[metric_name.val].request,
  )
  let core : @newton_solver.Request = @json.from_json(
    modules[first.module].request,
  )
  guard request.nworld == core.nworld &&
    request.nv == core.nv &&
    request.check_skip else {
    fail("CG metric operator dimensions/done guard differ")
  }
  let views : Map[String, Json] = Map([])
  cg_metric_views(ops, metric_name.val, views)
  for
    (a, b) in [("rhs", "ctx_grad"), ("res", "ctx_Mgrad"), ("skip", "ctx_done")] {
    guard views.get(a) == core_views.get(b) && views.contains(a) else {
      fail("CG metric operator does not use the real live state: " + a)
    }
  }
  // Folded J-D terms must be the same real constraints refreshed by the core.
  for
    (a, b) in [
      ("nefc", "nefc"),
      ("efc_J", "efc_J"),
      ("efc_D", "efc_D"),
      ("efc_J_rownnz", "efc_J_rownnz"),
      ("efc_J_rowadr", "efc_J_rowadr"),
      ("efc_J_colind", "efc_J_colind"),
    ] {
    if views.get(a) is Some(actual) {
      guard core_views.get(b) == Some(actual) else {
        fail("folded CG operator changed actual constraint input: " + a)
      }
    }
  }
  // Neither scratch nor factor owners may overwrite another core state through
  // an argument absent from that particular helper's local alias validator.
  for op in ops {
    guard op is Kernel(call) else { fail("CG helper launch required") }
    for p in call.entry.parameters {
      let actual = call.named[p.name]
      for _, core_view in first.named {
        if actual.buffer == core_view.buffer {
          let role = match p.name {
            "rhs" =>
              if call.module == mixed_name.val {
                "ctx_Mgrad"
              } else {
                "ctx_grad"
              }
            "res" | "solution" => "ctx_Mgrad"
            "skip" | "done" => "ctx_done"
            "efc_J"
            | "efc_D"
            | "nefc"
            | "efc_J_rownnz"
            | "efc_J_rowadr"
            | "efc_J_colind"
            | "M_rowadr"
            | "M_rownnz"
            | "M_colind" => p.name
            "M" => "M_csr"
            _ => ""
          }
          guard !role.is_empty() &&
            core_views.get(role) == Some(actual.to_json()) else {
            fail(
              "CG operator factor/scratch/model view aliases unrelated core state",
            )
          }
        }
      }
    }
  }
  let mixed_views : Map[String, Json] = Map([])
  let mixed_request = if mixed_name.val.is_empty() {
    None
  } else {
    cg_metric_views(ops, mixed_name.val, mixed_views)
    Some(@json.from_json(modules[mixed_name.val].request))
  }
  {
    request,
    module_name: metric_name.val,
    mixed_module: mixed_name.val,
    mixed_request,
    views,
    mixed_views,
    efm0_active: efm0.val,
    folded_blocks: folded.val,
    fold_contact: contact.val,
  }
}

///|
fn cg_outputs(ops : Array[Op], owners : Map[String, Unit]) -> Unit {
  for op in ops {
    match op {
      Kernel(call) =>
        for p in call.entry.parameters {
          if p.kind == "array" &&
            p.access != "input" &&
            !["status", "failure"].contains(p.name) {
            owners[call.named[p.name].buffer] = ()
          }
        }
      If(_, yes, no) => {
        cg_outputs(yes, owners)
        cg_outputs(no, owners)
      }
      While(_, body) => cg_outputs(body, owners)
      _ => ()
    }
  }
}

///|
fn reject_unplanned_cg(
  ops : Array[Op],
  modules : Map[String, Module],
) -> Unit raise {
  for op in ops {
    match op {
      Kernel(call) =>
        if modules[call.module].kind ==
          "moonrobo-native-newton-solver-module-v1" {
          let request : @newton_solver.Request = @json.from_json(
            modules[call.module].request,
          )
          guard request.solver != "cg" || call.entry.key == "unconstrained" else {
            fail("CG stages require their complete canonical native schedule")
          }
        }
      If(_, yes, no) => {
        reject_unplanned_cg(yes, modules)
        reject_unplanned_cg(no, modules)
      }
      While(_, body) => reject_unplanned_cg(body, modules)
      _ => ()
    }
  }
}

///|
/// Recompute the actual core + effective-operator planner from authenticated
/// requests and actual owned views, including the repeated body. No algorithm
/// or device operation runs while proving this structural/ownership contract.
fn validate_cg_preconditioners(
  program : Array[Op],
  modules : Map[String, Module],
) -> Unit raise {
  let segments : Map[Int32, Int32] = Map([])
  let covered = Array::make(program.length(), false)
  for index, op in program {
    if op is Kernel(init) &&
      modules[init.module].kind == "moonrobo-native-newton-solver-module-v1" &&
      init.entry.key == "cg-search-init" {
      let request : @newton_solver.Request = @json.from_json(
        modules[init.module].request,
      )
      guard request.solver == "cg" && index >= 4 else {
        fail("canonical CG initialization is incomplete")
      }
      let start = Ref(-1)
      for back in 0..<index {
        let pos = index - 1 - back
        if program[pos] is Kernel(reset) &&
          reset.module == init.module &&
          reset.entry.key == "initialize-controls" {
          start.val = pos
          break
        }
      }
      let begin = start.val
      guard begin >= 0 &&
        begin + 3 < index &&
        program[begin] is Kernel(first) &&
        program[begin + 1] is Kernel(state) &&
        state.module == init.module &&
        state.entry.key == "initialize-state" &&
        program[begin + 2] is Kernel(gradient) &&
        gradient.module == init.module &&
        gradient.entry.key == "constraint-gradient-hessian" else {
        fail("CG requires exact controls/state/gradient initialization")
      }
      let end = index + 1 + (if request.iterations > 0 { 1 } else { 0 })
      guard end <= program.length() else {
        fail("CG convergence WHILE is missing")
      }
      let core_views : Map[String, Json] = Map([])
      for name, view in state.named {
        core_views[name] = view.to_json()
      }
      for name, view in first.named {
        guard !core_views.contains(name) || core_views[name] == view.to_json() else {
          fail("CG controls changed live state")
        }
        core_views[name] = view.to_json()
      }
      let convergence_module = if request.iterations > 0 {
        guard program[index + 1] is While(_, body) &&
          !body.is_empty() &&
          body[body.length() - 1] is Kernel(tail) &&
          modules[tail.module].kind == "moonrobo-device-convergence-module-v1" else {
          fail("CG requires genuine beta/search convergence WHILE")
        }
        for name, view in tail.named {
          guard !core_views.contains(name) || core_views[name] == view.to_json() else {
            fail("CG convergence changed actual state")
          }
          core_views[name] = view.to_json()
        }
        tail.module
      } else {
        ""
      }
      let config : @newton_solver.PlanRequest = @json.from_json({
        "request": Json(request),
        "module": Json(init.module),
        "convergence_module": Json(convergence_module),
        "views": Json(core_views),
      })
      let body = program[begin + 3:index].to_owned()
      let expected = if body.length() == 1 &&
        body[0] is Kernel(factor) &&
        factor.module == init.module &&
        factor.entry.key == "factor-direction" {
        @newton_solver.plan(config)
      } else {
        let operator = cg_operator_plan(body, state, modules, core_views)
        @newton_solver.plan_with_effective_preconditioner(config, operator)
      }
      let actual = program[begin:end].to_owned()
      guard expected is { "program": Array(commands), .. } &&
        Json(actual.map(incremental_command)) == Json(commands) else {
        fail(
          "CG native sequence/preconditioner linkage differs from the genuine canonical planner",
        )
      }
      for pos in begin..<end {
        guard !covered[pos] else { fail("CG canonical schedules overlap") }
        covered[pos] = true
      }
      segments[begin] = end
    }
  }
  let frozen : Map[String, Unit] = Map([])
  let mut index = 0
  while index < program.length() {
    if segments.get(index) is Some(end) {
      let segment = program[index:end].to_owned()
      protect_completed_incremental(segment, frozen)
      // Keep completed CG outputs stable against unplanned later producers.
      cg_outputs(segment, frozen)
      index = end
    } else {
      reject_unplanned_cg([program[index]], modules)
      protect_completed_incremental([program[index]], frozen)
      index += 1
    }
  }
}
