///|
fn solver_status_parameter(kind : String) -> String? {
  match kind {
    "moonrobo-native-newton-solver-module-v1" => Some("status")
    "moonrobo-native-solver-adapters-module-v1" => Some("status")
    "moonrobo-native-mixed-sparse-solver-module-v1" => Some("failure")
    "moonrobo-native-sparse-lu-module-v1" => Some("failure")
    "moonrobo-native-solver-metrics-module-v1" => Some("failure")
    _ => None
  }
}

///|
fn shared_operator_failure(a : String, b : String) -> Bool {
  let family = [
    "moonrobo-native-mixed-sparse-solver-module-v1", "moonrobo-native-sparse-lu-module-v1",
    "moonrobo-native-solver-metrics-module-v1",
  ]
  let newton = [
    "moonrobo-native-newton-solver-module-v1", "moonrobo-native-solver-adapters-module-v1",
  ]
  (family.contains(a) && family.contains(b)) ||
  (newton.contains(a) && newton.contains(b))
}

///|
fn solver_failure_writer(
  state : StickyStatus,
  call : Call,
  modules : Map[String, Module],
) -> Bool {
  state.module == call.module ||
  shared_operator_failure(modules[state.module].kind, modules[call.module].kind)
}

///|
/// A sticky failure may be written by entries of one genuine module or the
/// explicit mixed/LU/metric operator family, through their failure parameter.
/// No other argument, module, copy or zero may rewrite it. Each accepted
/// lowerer checks a nonzero failure before work and never clears it.
/// The initial proof therefore survives every reachable branch and iteration.
fn protect_solver_status(
  program : Array[Op],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  protected : Map[String, StickyStatus],
  collect : Bool,
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) =>
        if collect {
          if solver_status_parameter(modules[call.module].kind) is Some(name) {
            let view = call.named[name]
            let count : Int32 = @json.from_json(
              field(modules[call.module].request, "nworld"),
            )
            guard count > 0 &&
              view.dtype == "int32" &&
              view.shape == [count] &&
              view.byte_strides == [4] &&
              view.offset_bytes == 0UL &&
              buffers[view.buffer].bytes.length() / 4 == count &&
              buffers[view.buffer].bytes.length() % 4 == 0 else {
              fail(
                "solver failure state must own a complete int32 world vector",
              )
            }
            if protected.get(view.buffer) is Some(previous) {
              guard solver_failure_writer(previous, call, modules) &&
                previous.view.to_json() == view.to_json() else {
                fail(
                  "only matching authenticated solver operators may share failure owners",
                )
              }
            } else {
              for world in 0..<count {
                guard scalar_i32(view, buffers, [world]) == 0 else {
                  fail("solver failure state must initially be zero")
                }
              }
              protected[view.buffer] = { module: call.module, view, }
            }
          }
        } else {
          for parameter in call.entry.parameters {
            if parameter.kind == "array" && parameter.access != "input" {
              let view = call.named[parameter.name]
              if protected.get(view.buffer) is Some(state) {
                guard solver_failure_writer(state, call, modules) &&
                  solver_status_parameter(modules[call.module].kind) ==
                  Some(parameter.name) &&
                  state.view.to_json() == view.to_json() else {
                  fail("program overwrites a persistent solver failure state")
                }
              }
            }
          }
        }
      CopyBytes(copy) =>
        if !collect {
          guard !protected.contains(copy.destination) else {
            fail("copy may not hide a solver failure")
          }
        }
      ZeroBytes(zero) =>
        if !collect {
          guard !protected.contains(zero.buffer) else {
            fail("zero may not hide a solver failure")
          }
        }
      If(_, yes, no) => {
        protect_solver_status(yes, modules, buffers, protected, collect)
        protect_solver_status(no, modules, buffers, protected, collect)
      }
      While(_, body) =>
        protect_solver_status(body, modules, buffers, protected, collect)
    }
  }
}

///|
fn validate_solver_results(
  states : Array[StickyStatus],
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  for state in states {
    for world in 0..<state.view.shape[0] {
      guard scalar_i32(state.view, buffers, [world]) == 0 else {
        fail("native solver failure refused result publication")
      }
    }
  }
}
