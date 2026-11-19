///|
fn view_offset(view : View, indices : Array[Int32]) -> Int32 raise {
  guard indices.length() == view.shape.length() else {
    fail("typed metadata index rank differs")
  }
  let mut offset = view.offset_bytes.to_int()
  for axis, index in indices {
    guard index >= 0 && index < view.shape[axis] else {
      fail("typed metadata index exceeds shape")
    }
    offset += index * view.byte_strides[axis]
  }
  offset
}

///|
fn scalar_f32(
  view : View,
  buffers : Map[String, HostBuffer],
  indices : Array[Int32],
) -> Float raise {
  guard view.dtype == "float32" else {
    fail("metadata must have actual float32 dtype")
  }
  let offset = view_offset(view, indices)
  let bytes = buffers[view.buffer].bytes
  let bits = bytes[offset].to_uint() |
    (bytes[offset + 1].to_uint() << 8) |
    (bytes[offset + 2].to_uint() << 16) |
    (bytes[offset + 3].to_uint() << 24)
  Float::reinterpret_from_int(bits.to_int())
}

///|
fn scalar_bool(
  view : View,
  buffers : Map[String, HostBuffer],
  index : Int32,
) -> Bool raise {
  guard view.dtype == "bool" else {
    fail("metadata must have actual bool dtype")
  }
  let byte = buffers[view.buffer].bytes[view_offset(view, [index])]
  guard byte == 0 || byte == 1 else { fail("noncanonical observed bool state") }
  byte == 1
}

///|
fn validate_convergence(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let request : @device_convergence.Request = @json.from_json(module.request)
  let bindings = call.entry.parameters.map(fn(p) {
    let v = call.named[p.name]
    @device_convergence.Binding::{
      name: p.name,
      allocation: v.buffer,
      dtype: v.dtype,
      shape: v.shape,
      byte_strides: v.byte_strides,
      byte_offset: v.offset_bytes.to_int64(),
      buffer_bytes: buffers[v.buffer].bytes.length().to_int64(),
    }
  })
  @device_convergence.validate_bindings(request, call.entry.key, bindings)
  let mut unfinished = 0
  for world in 0..<request.nworld {
    let done = scalar_bool(call.named["ctx_done"], buffers, world)
    let niter = scalar_i32(call.named["solver_niter"], buffers, [world])
    let overflow = scalar_i32(call.named["overflow"], buffers, [world])
    guard niter >= 0 &&
      niter <= request.iterations &&
      (done || niter < request.iterations) &&
      overflow >= 0 else {
      fail("initial device convergence iteration/overflow state invalid")
    }
    if !done {
      unfinished += 1
    }
  }
  guard scalar_i32(call.named["nsolving"], buffers, [0]) == unfinished else {
    fail(
      "initial device predicate must equal the actual unfinished world count",
    )
  }
  for param in call.entry.parameters {
    if param.dtype == "float32" && param.access == "input" {
      let view = call.named[param.name]
      for i in 0..<view.shape[0] {
        let n = if param.rank == 1 { 1 } else { view.shape[1] }
        for j in 0..<n {
          let value = scalar_f32(
            view,
            buffers,
            if param.rank == 1 {
              [i]
            } else {
              [i, j]
            },
          )
          guard !value.is_nan() && !value.is_inf() else {
            fail("nonfinite initial device convergence input")
          }
          if param.name == "stat_meaninertia" {
            guard value > 0.0F else {
              fail("device mean inertia must be positive")
            }
          }
          if param.name == "opt_tolerance" || param.name == "ctx_grad_dot" {
            guard value >= 0.0F else {
              fail("device tolerance/gradient norm must be nonnegative")
            }
          }
        }
      }
    }
  }
  // These model constants participate in the termination-domain proof.
  for name in ["opt_tolerance", "stat_meaninertia"] {
    index_owner(call.named[name], immutable)
  }
}

///|
/// Unlike append counters, these control owners may not even be zeroed by
/// another operation. Initial nsolving/done/niter consistency must survive all
/// branches and iterations; the only writer is their unique real producer.
fn protect_convergence(
  program : Array[Op],
  modules : Map[String, Module],
  protected : Map[String, String],
  calls : Array[Call],
  collect : Bool,
  initializers~ : Map[String, Call] = {},
  control_initializers~ : Map[String, Call] = {},
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) => {
        let key = call.module + "::" + call.entry.key
        if collect &&
          modules[call.module].kind == "moonrobo-device-convergence-module-v1" {
          calls.push(call)
          for name in ["ctx_done", "solver_niter", "overflow", "nsolving"] {
            let owner = call.named[name].buffer
            guard !protected.contains(owner) else {
              fail(
                "device convergence states require distinct owners and one static producer",
              )
            }
            protected[owner] = key
          }
        } else if !collect {
          for param in call.entry.parameters {
            if param.kind == "array" && param.access != "input" {
              if protected.get(call.named[param.name].buffer) is Some(producer) {
                let initial = initializers.get(call.named[param.name].buffer)
                let cg_initialization = initial is Some(allowed) &&
                  allowed.module == call.module &&
                  allowed.entry.key == call.entry.key &&
                  ["ctx_done", "nsolving"].contains(param.name) &&
                  allowed.named[param.name].to_json() ==
                  call.named[param.name].to_json()
                let reset = control_initializers.get(
                  call.named[param.name].buffer,
                )
                let canonical_reset = reset is Some(allowed) &&
                  allowed.module == call.module &&
                  call.entry.key == "initialize-controls" &&
                  ["ctx_done", "solver_niter", "nsolving"].contains(param.name) &&
                  allowed.named[param.name].to_json() ==
                  call.named[param.name].to_json()
                guard producer == key || cg_initialization || canonical_reset else {
                  fail(
                    "another kernel writes a device convergence control owner",
                  )
                }
              }
            }
          }
        }
      }
      CopyBytes(copy) =>
        if !collect {
          guard !protected.contains(copy.destination) else {
            fail("copy would invalidate device convergence state/count proof")
          }
        }
      ZeroBytes(zero) =>
        if !collect {
          guard !protected.contains(zero.buffer) else {
            fail("zero would invalidate device convergence state/count proof")
          }
        }
      If(_, yes, no) => {
        protect_convergence(
          yes,
          modules,
          protected,
          calls,
          collect,
          initializers~,
          control_initializers~,
        )
        protect_convergence(
          no,
          modules,
          protected,
          calls,
          collect,
          initializers~,
          control_initializers~,
        )
      }
      While(_, body) =>
        protect_convergence(
          body,
          modules,
          protected,
          calls,
          collect,
          initializers~,
          control_initializers~,
        )
    }
  }
}

///|
/// The genuine CG initialization has an initial-gradient early-exit gate. It
/// may transition done/count once before the corresponding device WHILE; it is
/// not a general exemption from the unique convergence control owner proof.
fn validate_cg_initializers(
  program : Array[Op],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  convergence : Array[Call],
) -> Map[String, Call] raise {
  let result : Map[String, Call] = {}
  for index, operation in program {
    if operation is Kernel(call) &&
      modules[call.module].kind == "moonrobo-native-newton-solver-module-v1" &&
      call.entry.key == "cg-search-init" {
      let request : @newton_solver.Request = @json.from_json(
        modules[call.module].request,
      )
      guard request.solver == "cg" else {
        fail("CG initialization requires the actual CG specialization")
      }
      for world in 0..<request.nworld {
        guard !scalar_bool(call.named["ctx_done"], buffers, world) else {
          fail(
            "CG initialization requires canonical initially unfinished worlds",
          )
        }
      }
      guard scalar_i32(call.named["nsolving"], buffers, [0]) == request.nworld else {
        fail(
          "CG initialization requires the exact initial unfinished world count",
        )
      }
      let matching : Ref[Call?] = Ref(None)
      for tail in convergence {
        if tail.named["ctx_done"].to_json() == call.named["ctx_done"].to_json() &&
          tail.named["nsolving"].to_json() == call.named["nsolving"].to_json() {
          guard matching.val is None else {
            fail("CG initialization cannot seed independent control loops")
          }
          matching.val = Some(tail)
        }
      }
      if request.iterations > 0 {
        guard matching.val is Some(tail) &&
          tail.entry.key == "cg-beta-search-finalize" else {
          fail(
            "CG initialization must seed its genuine beta/search convergence loop",
          )
        }
        let transition : @device_convergence.Request = @json.from_json(
          modules[tail.module].request,
        )
        guard transition.nworld == request.nworld &&
          transition.nv == request.nv &&
          transition.iterations == request.iterations else {
          fail("CG iteration and convergence specializations differ")
        }
        for
          name in [
            "ctx_grad", "ctx_Mgrad", "ctx_prev_grad", "ctx_prev_Mgrad", "ctx_search",
            "ctx_search_dot", "opt_tolerance", "stat_meaninertia",
          ] {
          guard tail.named.get(name) is Some(tail_view) &&
            call.named.get(name) is Some(init_view) &&
            tail_view.to_json() == init_view.to_json() else {
            fail(
              "CG initialization and convergence do not use identical state views",
            )
          }
        }
        let later_loop = Ref(false)
        for loop_index, op in program {
          if op is While(predicate, body) &&
            predicate.to_json() == call.named["nsolving"].to_json() &&
            body[body.length() - 1] is Kernel(last) &&
            last.module == tail.module &&
            last.entry.key == tail.entry.key {
            guard loop_index > index else {
              fail(
                "CG initialization must precede its unconditional control loop",
              )
            }
            later_loop.val = true
          }
        }
        guard later_loop.val else {
          fail("CG initialization has no matching top-level WHILE")
        }
      } else {
        guard matching.val is None else {
          fail(
            "zero-iteration CG initialization cannot drive a device iteration loop",
          )
        }
      }
      for name in ["ctx_done", "nsolving"] {
        let owner = call.named[name].buffer
        guard !result.contains(owner) else {
          fail("one CG initializer per control owner")
        }
        result[owner] = call
      }
    }
  }
  result
}

///|
/// Observation after a real graph launch. Recording alone proves no result.
fn validate_convergence_results(
  calls : Array[Call],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  for call in calls {
    let request : @device_convergence.Request = @json.from_json(
      modules[call.module].request,
    )
    guard scalar_i32(call.named["nsolving"], buffers, [0]) == 0 else {
      fail("executed device convergence loop did not finish")
    }
    for world in 0..<request.nworld {
      let niter = scalar_i32(call.named["solver_niter"], buffers, [world])
      guard scalar_bool(call.named["ctx_done"], buffers, world) &&
        niter >= 0 &&
        niter <= request.iterations else {
        fail("executed device convergence state failed publication gate")
      }
    }
  }
}
