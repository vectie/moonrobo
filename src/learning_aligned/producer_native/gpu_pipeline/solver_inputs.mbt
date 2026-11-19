///|
/// Numerical model arrays can be prepared by earlier authenticated kernels.
/// Once an actual solve starts they are frozen, including inside all branches
/// and repeated iterations. Index and termination-domain proofs remain global.
fn freeze_newton_inputs(
  program : Array[Op],
  modules : Map[String, Module],
  frozen : Map[String, Unit],
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) => {
        for parameter in call.entry.parameters {
          if parameter.kind == "array" && parameter.access != "input" {
            guard !frozen.contains(call.named[parameter.name].buffer) else {
              fail("a running Newton solve's model input was rewritten")
            }
          }
        }
        if modules[call.module].kind ==
          "moonrobo-native-newton-solver-module-v1" &&
          ["initialize-state", "unconstrained"].contains(call.entry.key) {
          let request : @newton_solver.Request = @json.from_json(
            modules[call.module].request,
          )
          for name in @newton_solver.immutable_parameters(request) {
            frozen[call.named[name].buffer] = ()
          }
        }
      }
      CopyBytes(copy) => {
        guard !frozen.contains(copy.destination) else {
          fail("copy rewrites a running Newton solve's model input")
        }
      }
      ZeroBytes(zero) => {
        guard !frozen.contains(zero.buffer) else {
          fail("zero rewrites a running Newton solve's model input")
        }
      }
      If(_, yes, no) => {
        freeze_newton_inputs(yes, modules, frozen)
        freeze_newton_inputs(no, modules, frozen)
      }
      While(_, body) => freeze_newton_inputs(body, modules, frozen)
    }
  }
}
