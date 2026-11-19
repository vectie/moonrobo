///|
fn incremental_adapter_call(call : Call, modules : Map[String, Module]) -> Bool {
  modules[call.module].kind == "moonrobo-native-solver-adapters-module-v1" &&
  (
    call.entry.key.has_prefix("incremental-") ||
    call.entry.key == "recover-qfrc"
  )
}

///|
fn incremental_command(op : Op) -> Json raise {
  match op {
    Kernel(call) => {
      guard call.entry.parameters.all(p => p.kind == "array") else {
        fail(
          "incremental canonical schedule requires actual array-only entries",
        )
      }
      let arguments : Map[String, Json] = {}
      for name, view in call.named {
        arguments[name] = view.to_json()
      }
      {
        "operation": "launch",
        "parameters": {
          "module": Json(call.module),
          "entry": Json(call.entry.key),
          "arguments": Json(arguments),
        },
      }
    }
    CopyBytes(copy) => { "operation": "copy", "parameters": copy.to_json() }
    ZeroBytes(zero) => { "operation": "zero", "parameters": zero.to_json() }
    If(predicate, yes, no) =>
      {
        "operation": "if",
        "parameters": {
          "condition": predicate.to_json(),
          "on_true": Json(yes.map(incremental_command)),
          "on_false": Json(no.map(incremental_command)),
        },
      }
    While(predicate, body) =>
      {
        "operation": "while",
        "parameters": {
          "condition": predicate.to_json(),
          "body": Json(body.map(incremental_command)),
        },
      }
  }
}

///|
fn incremental_views(
  ops : Array[Op],
  module_name : String,
  views : Map[String, Json],
) -> Unit raise {
  for op in ops {
    match op {
      Kernel(call) =>
        if call.module == module_name {
          for name, view in call.named {
            let actual = view.to_json()
            if views.get(name) is Some(previous) {
              guard previous == actual else {
                fail(
                  "incremental stages changed the actual owned state view: " +
                  name,
                )
              }
            } else {
              views[name] = actual
            }
          }
        }
      If(_, yes, no) => {
        incremental_views(yes, module_name, views)
        incremental_views(no, module_name, views)
      }
      While(_, body) => incremental_views(body, module_name, views)
      _ => ()
    }
  }
}

///|
fn reject_unplanned_incremental(
  ops : Array[Op],
  modules : Map[String, Module],
) -> Unit raise {
  for op in ops {
    match op {
      Kernel(call) => {
        guard !incremental_adapter_call(call, modules) &&
          !(modules[call.module].kind ==
          "moonrobo-native-newton-solver-module-v1" &&
          call.entry.key == "line-search-incremental") else {
          fail(
            "incremental stages require the complete canonical initialized native schedule",
          )
        }
      }
      If(_, yes, no) => {
        reject_unplanned_incremental(yes, modules)
        reject_unplanned_incremental(no, modules)
      }
      While(_, body) => reject_unplanned_incremental(body, modules)
      _ => ()
    }
  }
}

///|
fn incremental_outputs(ops : Array[Op], owners : Map[String, Unit]) -> Unit {
  for op in ops {
    match op {
      Kernel(call) =>
        for p in call.entry.parameters {
          // Failure sharing is separately authenticated by protect_solver_status.
          if p.kind == "array" && p.access != "input" && p.name != "status" {
            owners[call.named[p.name].buffer] = ()
          }
        }
      If(_, yes, no) => {
        incremental_outputs(yes, owners)
        incremental_outputs(no, owners)
      }
      While(_, body) => incremental_outputs(body, owners)
      _ => ()
    }
  }
}

///|
fn protect_completed_incremental(
  ops : Array[Op],
  owners : Map[String, Unit],
) -> Unit raise {
  for op in ops {
    match op {
      Kernel(call) =>
        for p in call.entry.parameters {
          if p.kind == "array" && p.access != "input" {
            guard !owners.contains(call.named[p.name].buffer) else {
              fail(
                "a later operation rewrites a completed incremental solve's state",
              )
            }
          }
        }
      CopyBytes(copy) => {
        guard !owners.contains(copy.destination) else {
          fail("copy rewrites a completed incremental solve's state")
        }
      }
      ZeroBytes(zero) => {
        guard !owners.contains(zero.buffer) else {
          fail("zero rewrites a completed incremental solve's state")
        }
      }
      If(_, yes, no) => {
        protect_completed_incremental(yes, owners)
        protect_completed_incremental(no, owners)
      }
      While(_, body) => protect_completed_incremental(body, owners)
    }
  }
}

///|
/// Recompute the genuine planner from actual authenticated module requests and
/// actual live views. Accept only its exact initialization/iteration/recovery
/// sequence. No numeric computation, graph execution or source facade is used.
/// Unrelated preparation prefixes and disjoint suffixes remain possible.
fn validate_solver_adapter_order(
  program : Array[Op],
  modules : Map[String, Module],
) -> Unit raise {
  let segments : Map[Int32, (Int32, Map[String, Unit])] = {}
  let covered = Array::make(program.length(), false)
  for index, op in program {
    if op is Kernel(init) &&
      modules[init.module].kind == "moonrobo-native-solver-adapters-module-v1" &&
      init.entry.key == "incremental-initialize" {
      guard index >= 4 &&
        program[index - 4] is Kernel(first) &&
        modules[first.module].kind == "moonrobo-native-newton-solver-module-v1" &&
        first.entry.key == "initialize-controls" else {
        fail(
          "incremental initialization must follow genuine core controls/state/H/factor initialization",
        )
      }
      let request : @newton_solver.Request = @json.from_json(
        modules[first.module].request,
      )
      let adapter : @solver_adapters.Request = @json.from_json(
        modules[init.module].request,
      )
      // The compact planner constructs the exact M/J/vectors consumed by the
      // core, then scatters recovered state and refreshes full-coordinate Ma.
      // Including those genuine producers in the exact comparison proves the
      // full/compact mathematical coupling, not only index bounds.
      let prefix = if adapter.compact { 4 } else { 0 }
      guard index >= 4 + prefix else {
        fail("compact incremental input producers are missing")
      }
      let start = index - 4 - prefix
      let end = index +
        (if request.iterations > 0 { 3 } else { 2 }) +
        (if adapter.compact { 2 } else { 0 })
      guard end <= program.length() else {
        fail("incremental recovery or iteration is missing")
      }
      for i in start..<end {
        guard !covered[i] else {
          fail("incremental canonical schedules overlap")
        }
        covered[i] = true
      }
      guard program[index - 3] is Kernel(state) &&
        state.module == first.module &&
        state.entry.key == "initialize-state" else {
        fail("incremental solve has no genuine initial native state")
      }
      let core_views : Map[String, Json] = {}
      for name, view in state.named {
        core_views[name] = view.to_json()
      }
      for name, view in first.named {
        if core_views.get(name) is Some(previous) {
          guard previous == view.to_json() else {
            fail("incremental control/state owners differ")
          }
        } else {
          core_views[name] = view.to_json()
        }
      }
      let views : Map[String, Json] = {}
      for
        (a, b) in [
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
        ] {
        guard core_views.get(b) is Some(view) else {
          fail("incremental core omitted actual state: " + b)
        }
        views[a] = view
      }
      if !adapter.compact {
        guard core_views.get("efc_J") is Some(j) else {
          fail("incremental core omitted actual Jacobian")
        }
        views["J"] = j
      }
      let segment = program[start:end].to_owned()
      incremental_views(segment, init.module, views)
      if adapter.compact {
        // Full M is read both by the input gather and the final full-space Ma
        // refresh. Per-kernel alias checks alone cannot stop an intermediate
        // core scratch/output from sharing and destroying this source owner.
        guard views.get("M") is Some(value) else {
          fail("compact incremental schedule omitted the actual full mass")
        }
        let full_mass = strict_view(value)
        let retained_mass : Map[String, Unit] = {}
        retained_mass[full_mass.buffer] = ()
        protect_completed_incremental(segment, retained_mass)
      }
      let convergence_module = if request.iterations > 0 {
        guard program[index + 1] is While(_, body) &&
          !body.is_empty() &&
          body[body.length() - 1] is Kernel(tail) &&
          modules[tail.module].kind == "moonrobo-device-convergence-module-v1" else {
          fail(
            "incremental iteration requires its genuine native convergence WHILE",
          )
        }
        // The core planner uses the same convergence views as its actual body.
        for name, view in tail.named {
          if core_views.get(name) is Some(previous) {
            guard previous == view.to_json() else {
              fail("incremental convergence changed an actual state view")
            }
          } else {
            core_views[name] = view.to_json()
          }
        }
        tail.module
      } else {
        ""
      }
      let expected = @solver_adapters.incremental_plan({
        request: adapter,
        module_name: init.module,
        views,
        solver: {
          request,
          module: first.module,
          convergence_module,
          views: core_views,
        },
      })
      guard expected is { "program": Array(commands), .. } &&
        Json(segment.map(incremental_command)) == Json(commands) else {
        fail(
          "incremental native sequence/state differs from the actual source-derived planner",
        )
      }
      let outputs : Map[String, Unit] = {}
      incremental_outputs(segment, outputs)
      segments[start] = (end, outputs)
    }
  }
  let frozen : Map[String, Unit] = {}
  let mut index = 0
  while index < program.length() {
    if segments.get(index) is Some((end, outputs)) {
      protect_completed_incremental(program[index:end].to_owned(), frozen)
      for owner, _ in outputs {
        frozen[owner] = ()
      }
      index = end
    } else {
      let singleton = [program[index]]
      reject_unplanned_incremental(singleton, modules)
      protect_completed_incremental(singleton, frozen)
      index += 1
    }
  }
}
