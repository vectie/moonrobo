///|
/// A bounded convergence tail alone does not establish that a Newton step ran.
/// Authenticate the actual full-rebuild initialization and repeated body against
/// its source-derived planner, using the live bound views. Incremental schedules
/// are checked independently by validate_solver_adapter_order.
fn validate_reference_newton_order(
  program : Array[Op],
  modules : Map[String, Module],
) -> Unit raise {
  let segments : Map[Int32, Int32] = {}
  for index, op in program {
    if op is Kernel(reset) &&
      modules[reset.module].kind == "moonrobo-native-newton-solver-module-v1" &&
      reset.entry.key == "initialize-controls" {
      let request : @newton_solver.Request = @json.from_json(
        modules[reset.module].request,
      )
      if request.solver != "newton" {
        continue
      }
      if index + 4 < program.length() &&
        program[index + 4] is Kernel(adapter) &&
        modules[adapter.module].kind ==
        "moonrobo-native-solver-adapters-module-v1" &&
        adapter.entry.key == "incremental-initialize" {
        continue
      }
      let end = index + 4 + (if request.iterations > 0 { 1 } else { 0 })
      guard end <= program.length() &&
        program[index + 1] is Kernel(state) &&
        state.module == reset.module &&
        state.entry.key == "initialize-state" else {
        fail("Newton requires its full unconditional initialization")
      }
      let views : Map[String, Json] = {}
      for name, view in state.named {
        views[name] = view.to_json()
      }
      for name, view in reset.named {
        guard !views.contains(name) || views[name] == view.to_json() else {
          fail("Newton control/state views differ")
        }
        views[name] = view.to_json()
      }
      let convergence_module = if request.iterations > 0 {
        guard program[index + 4] is While(_, body) &&
          !body.is_empty() &&
          body[body.length() - 1] is Kernel(tail) &&
          modules[tail.module].kind == "moonrobo-device-convergence-module-v1" else {
          fail("Newton requires its actual repeated body and convergence tail")
        }
        for name, view in tail.named {
          guard !views.contains(name) || views[name] == view.to_json() else {
            fail("Newton tail changed a live state view")
          }
          views[name] = view.to_json()
        }
        tail.module
      } else {
        ""
      }
      let expected = @newton_solver.plan({
        request,
        module: reset.module,
        convergence_module,
        views,
      })
      guard expected is { "program": Array(commands), .. } &&
        Json(program[index:end].to_owned().map(incremental_command)) ==
        Json(commands) else {
        fail(
          "Newton native sequence differs from the actual initialized line-search/gradient/factor planner",
        )
      }
      segments[index] = end
    }
  }
  let frozen : Map[String, Unit] = {}
  let mut index = 0
  while index < program.length() {
    if segments.get(index) is Some(end) {
      let segment = program[index:end].to_owned()
      protect_completed_incremental(segment, frozen)
      incremental_outputs(segment, frozen)
      index = end
    } else {
      protect_completed_incremental([program[index]], frozen)
      index += 1
    }
  }
}
