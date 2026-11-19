///|
fn collect_newton_initialization(
  program : Array[Op],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  initialized : Map[String, Call],
  controls : Map[String, Call],
  line_flags : Map[String, StickyStatus],
  depth : Int32,
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) =>
        if modules[call.module].kind ==
          "moonrobo-native-newton-solver-module-v1" {
          let request : @newton_solver.Request = @json.from_json(
            modules[call.module].request,
          )
          if call.entry.key == "initialize-controls" {
            guard depth == 0 && !initialized.contains(call.module) else {
              fail(
                "one unconditional control reset must begin each Newton module",
              )
            }
            for world in 0..<request.nworld {
              guard !scalar_bool(call.named["ctx_done"], buffers, world) &&
                scalar_i32(call.named["solver_niter"], buffers, [world]) == 0 else {
                fail(
                  "Newton control owners require canonical initial done/niter bytes",
                )
              }
            }
            guard scalar_i32(call.named["nsolving"], buffers, [0]) ==
              request.nworld else {
              fail(
                "Newton control reset requires canonical initial world count",
              )
            }
            for name in ["ctx_done", "solver_niter", "nsolving"] {
              let owner = call.named[name].buffer
              guard !controls.contains(owner) else {
                fail("one native initializer per control owner")
              }
              controls[owner] = call
            }
            initialized[call.module] = call
          } else if call.entry.key == "initialize-state" ||
            call.entry.key == "unconstrained" {
            guard depth == 0 &&
              (if call.entry.key == "unconstrained" {
                !initialized.contains(call.module)
              } else {
                initialized.get(call.module) is Some(reset) &&
                reset.entry.key == "initialize-controls"
              }) else {
              fail(
                "one unconditional initializer must precede every Newton module use",
              )
            }
            if call.entry.key == "initialize-state" {
              let reset = initialized[call.module]
              for name in ["ctx_done", "nsolving", "ctx_search_dot", "status"] {
                guard reset.named[name].to_json() == call.named[name].to_json() else {
                  fail("Newton state and control initialization owners differ")
                }
              }
            }
            initialized[call.module] = call
            if call.entry.key == "initialize-state" {
              for world in 0..<request.nworld {
                guard !scalar_bool(call.named["ctx_done"], buffers, world) else {
                  fail(
                    "a new Newton solve requires initially unfinished worlds",
                  )
                }
              }
              guard scalar_i32(call.named["nsolving"], buffers, [0]) ==
                request.nworld else {
                fail(
                  "a new Newton solve requires the canonical unfinished-world count",
                )
              }
              let flags = call.named["ls_overflow"]
              guard flags.dtype == "int32" &&
                flags.shape == [request.nworld] &&
                flags.byte_strides == [4] &&
                flags.offset_bytes == 0UL &&
                buffers[flags.buffer].bytes.length() / 4 == request.nworld &&
                buffers[flags.buffer].bytes.length() % 4 == 0 &&
                !line_flags.contains(flags.buffer) else {
                fail(
                  "Newton line-search flags require a distinct complete world owner",
                )
              }
              for world in 0..<request.nworld {
                guard scalar_i32(flags, buffers, [world]) == 0 else {
                  fail("Newton line-search flags must initially be zero")
                }
              }
              line_flags[flags.buffer] = { module: call.module, view: flags, }
            }
          } else {
            guard initialized.get(call.module) is Some(first) &&
              first.entry.key == "initialize-state" &&
              first.named.to_json() == call.named.to_json() else {
              fail(
                "Newton stages must follow initialization and use identical owned state views",
              )
            }
          }
        }
      If(_, yes, no) => {
        collect_newton_initialization(
          yes,
          modules,
          buffers,
          initialized,
          controls,
          line_flags,
          depth + 1,
        )
        collect_newton_initialization(
          no,
          modules,
          buffers,
          initialized,
          controls,
          line_flags,
          depth + 1,
        )
      }
      While(_, body) =>
        collect_newton_initialization(
          body,
          modules,
          buffers,
          initialized,
          controls,
          line_flags,
          depth + 1,
        )
      _ => ()
    }
  }
}

///|
fn protect_newton_line_flags(
  program : Array[Op],
  modules : Map[String, Module],
  flags : Map[String, StickyStatus],
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) =>
        for parameter in call.entry.parameters {
          if parameter.kind == "array" && parameter.access != "input" {
            let view = call.named[parameter.name]
            if flags.get(view.buffer) is Some(state) {
              guard state.module == call.module &&
                parameter.name == "ls_overflow" &&
                modules[call.module].kind ==
                "moonrobo-native-newton-solver-module-v1" &&
                ["initialize-state", "line-search", "line-search-incremental"].contains(
                  call.entry.key,
                ) &&
                state.view.to_json() == view.to_json() else {
                fail(
                  "another operation overwrites Newton line-search overflow flags",
                )
              }
            }
          }
        }
      CopyBytes(copy) => {
        guard !flags.contains(copy.destination) else {
          fail("copy hides line-search overflow")
        }
      }
      ZeroBytes(zero) => {
        guard !flags.contains(zero.buffer) else {
          fail("zero hides line-search overflow")
        }
      }
      If(_, yes, no) => {
        protect_newton_line_flags(yes, modules, flags)
        protect_newton_line_flags(no, modules, flags)
      }
      While(_, body) => protect_newton_line_flags(body, modules, flags)
    }
  }
}

///|
fn validate_newton_transitions(
  initialized : Map[String, Call],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  convergence : Array[Call],
  controls : Map[String, Call],
) -> Unit raise {
  for id, first in initialized {
    guard first.entry.key != "initialize-controls" else {
      fail(
        "Newton control initialization must be followed by real state initialization",
      )
    }
    if first.entry.key == "unconstrained" {
      continue
    }
    let request : @newton_solver.Request = @json.from_json(modules[id].request)
    let matched : Ref[Call?] = Ref(None)
    for tail in convergence {
      if tail.named["ctx_done"].to_json() == first.named["ctx_done"].to_json() &&
        tail.named["nsolving"].to_json() == first.named["nsolving"].to_json() {
        guard matched.val is None else {
          fail(
            "one Newton state cannot drive independent convergence producers",
          )
        }
        matched.val = Some(tail)
      }
    }
    if request.iterations == 0 {
      guard matched.val is None else {
        fail("zero-iteration Newton solve may not drive a convergence loop")
      }
      continue
    }
    guard matched.val is Some(tail) &&
      tail.entry.key ==
      (if request.solver == "newton" {
        "newton-done-with-ls"
      } else {
        "cg-beta-search-finalize"
      }) else {
      fail(
        "Newton iteration body must use its genuine matching convergence transition",
      )
    }
    let transition : @device_convergence.Request = @json.from_json(
      modules[tail.module].request,
    )
    guard transition.nworld == request.nworld &&
      transition.nv == request.nv &&
      transition.iterations == request.iterations else {
      fail("Newton body and convergence dimensions/iteration limit differ")
    }
    guard controls.get(tail.named["ctx_done"].buffer) is Some(reset) &&
      reset.named["solver_niter"].to_json() ==
      tail.named["solver_niter"].to_json() &&
      reset.named["nsolving"].to_json() == tail.named["nsolving"].to_json() else {
      fail(
        "Newton control reset and convergence must own identical iteration/count states",
      )
    }
    for world in 0..<request.nworld {
      guard scalar_i32(tail.named["solver_niter"], buffers, [world]) == 0 else {
        fail("a new Newton solve requires initially zero iteration counters")
      }
    }
    let names = [
      "ctx_grad_dot", "ctx_improvement", "ctx_alpha", "ls_overflow", "opt_tolerance",
      "stat_meaninertia",
    ]
    if request.solver == "newton" {
      names.push("ctx_newton_decrement")
    }
    for name in names {
      guard tail.named.get(name) is Some(view) &&
        first.named.get(name) is Some(body_view) &&
        view.to_json() == body_view.to_json() else {
        fail(
          "Newton body and convergence transition use different state owners",
        )
      }
    }
  }
}

///|
fn validate_line_flag_results(
  flags : Array[StickyStatus],
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  for state in flags {
    for world in 0..<state.view.shape[0] {
      let value = scalar_i32(state.view, buffers, [world])
      guard value == 0 || value == 1024 else {
        fail("line-search overflow contains unsupported state bits")
      }
    }
  }
}
