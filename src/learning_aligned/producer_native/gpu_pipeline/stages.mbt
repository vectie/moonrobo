///|
/// Adapt actual owned array descriptors to each module's domain proof.
fn validate_stage(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  if module.kind == "moonrobo-native-convex-gjk-module-v1" {
    let request : @convex.Request = @json.from_json(module.request)
    let bindings = call.entry.parameters.map(fn(p) {
      let v = call.named[p.name]
      @convex.Binding::{
        name: p.name,
        allocation: v.buffer,
        dtype: v.dtype,
        shape: v.shape,
        byte_strides: v.byte_strides,
        byte_offset: v.offset_bytes.to_int64(),
        buffer_bytes: buffers[v.buffer].bytes.length().to_int64(),
      }
    })
    @convex.validate_bindings(request, bindings)
    for i in 0..<5 {
      guard scalar_i32(call.named["rejected_out"], buffers, [i]) == 0 else {
        fail("convex stage requires initial zero rejection counters")
      }
    }
  } else if module.kind == "moonrobo-native-convex-contact-module-v1" {
    let request : @convex_contacts.Request = @json.from_json(module.request)
    let bindings = call.entry.parameters.map(fn(p) {
      let v = call.named[p.name]
      @convex_contacts.Binding::{
        name: p.name,
        allocation: v.buffer,
        dtype: v.dtype,
        shape: v.shape,
        byte_strides: v.byte_strides,
        byte_offset: v.offset_bytes.to_int64(),
        buffer_bytes: buffers[v.buffer].bytes.length().to_int64(),
      }
    })
    @convex_contacts.validate_bindings(request, bindings)
    guard scalar_i32(call.named["nacon_out"], buffers, [0]) == 0 else {
      fail("convex contact stream must initially have a zero append count")
    }
    for i in 0..<8 {
      guard scalar_i32(call.named["rejected_out"], buffers, [i]) == 0 else {
        fail("convex contacts require initially zero rejection counters")
      }
    }
  } else {
    let request : @tile_solver.Request = @json.from_json(module.request)
    let bindings = call.entry.parameters.map(fn(p) {
      let v = call.named[p.name]
      @tile_solver.Binding::{
        name: p.name,
        owner: v.buffer,
        dtype: v.dtype,
        shape: v.shape,
        byte_strides: v.byte_strides,
        offset_bytes: v.offset_bytes,
        capacity_bytes: buffers[v.buffer].bytes.length().to_uint64(),
      }
    })
    @tile_solver.validate_bindings(request, call.entry.key, bindings)
  }
}

///|
/// Failed factor/status outputs must not be hidden by a later zero, copy or
/// another kernel. Terminal GJK's append rejection owner is protected likewise.
fn protect_stages(
  program : Array[Op],
  modules : Map[String, Module],
  protected : Map[String, String],
  tiles : Array[Call],
  convex : Ref[Call?],
  collect : Bool,
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) => {
        let key = call.module + "::" + call.entry.key
        if collect {
          let names = if modules[call.module].kind ==
            "moonrobo-mathdx-tile-module-v1" {
            tiles.push(call)
            ["status"]
          } else if modules[call.module].kind ==
            "moonrobo-native-convex-gjk-module-v1" {
            guard convex.val is None else {
              fail("one terminal GJK stage only")
            }
            convex.val = Some(call)
            ["rejected_out"]
          } else if modules[call.module].kind ==
            "moonrobo-native-convex-contact-module-v1" {
            ["rejected_out"]
          } else {
            []
          }
          for name in names {
            let owner = call.named[name].buffer
            guard !protected.contains(owner) else {
              fail("stage result gates require unique owner/producers")
            }
            protected[owner] = key
          }
        } else {
          for p in call.entry.parameters {
            if p.kind == "array" && p.access != "input" {
              if protected.get(call.named[p.name].buffer) is Some(producer) {
                guard producer == key else {
                  fail("another kernel rewrites stage status/rejection owner")
                }
              }
            }
          }
        }
      }
      CopyBytes(copy) =>
        if !collect {
          guard !protected.contains(copy.destination) else {
            fail("copy overwrites stage result gate")
          }
        }
      ZeroBytes(zero) =>
        if !collect {
          guard !protected.contains(zero.buffer) else {
            fail("zero overwrites stage result gate")
          }
        }
      If(_, yes, no) => {
        protect_stages(yes, modules, protected, tiles, convex, collect)
        protect_stages(no, modules, protected, tiles, convex, collect)
      }
      While(_, body) =>
        protect_stages(body, modules, protected, tiles, convex, collect)
    }
  }
}

///|
fn validate_stage_results(
  prepared : Prepared,
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  for call in prepared.tiles {
    let request : @tile_solver.Request = @json.from_json(
      prepared.modules[call.module].request,
    )
    for i in 0..<request.batch_size {
      guard scalar_i32(call.named["status"], buffers, [i]) == 0 else {
        fail("MathDx factor/solve status refused publication")
      }
    }
  }
  if prepared.convex is Some(call) {
    let request : @convex.Request = @json.from_json(
      prepared.modules[call.module].request,
    )
    let count = scalar_i32(call.named["ncollision_in"], buffers, [0])
    let status = Array::makei(request.candidate_capacity, i => {
      scalar_i32(call.named["status_out"], buffers, [i])
    })
    let rejected = Array::makei(5, i => {
      scalar_i32(call.named["rejected_out"], buffers, [i])
    })
    @convex.validate_results(request, count, status, rejected)
  }
  if prepared.convex_contacts is Some(call) {
    let request : @convex_contacts.Request = @json.from_json(
      prepared.modules[call.module].request,
    )
    @convex_contacts.validate_results(
      request,
      scalar_i32(call.named["ncollision_in"], buffers, [0]),
      scalar_i32(call.named["nacon_out"], buffers, [0]),
      Array::makei(8, i => scalar_i32(call.named["rejected_out"], buffers, [i])),
    )
  }
}
