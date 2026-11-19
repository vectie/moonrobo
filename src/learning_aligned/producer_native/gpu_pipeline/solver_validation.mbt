///|
fn solver_bindings(
  call : Call,
  buffers : Map[String, HostBuffer],
) -> Array[@sparse_solver.Binding] {
  call.entry.parameters
  .filter(p => p.kind == "array")
  .map(fn(p) {
    let view = call.named[p.name]
    @sparse_solver.Binding::{
      name: p.name,
      owner: view.buffer,
      dtype: view.dtype,
      shape: view.shape,
      byte_strides: view.byte_strides,
      offset_bytes: view.offset_bytes,
      capacity_bytes: buffers[view.buffer].bytes.length().to_uint64(),
    }
  })
}

///|
fn validate_sparse_solver(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let bindings = solver_bindings(call, buffers)
  if module.kind == "moonrobo-native-mixed-sparse-solver-module-v1" {
    let request : @sparse_solver.Request = @json.from_json(module.request)
    @sparse_solver.validate_bindings(request, call.entry.key, bindings)
    let lower = @sparse_solver.lower(request)
    let metadata = lower.metadata.map(fn(item) {
      let view = call.named[item.name]
      index_owner(view, immutable)
      @sparse_solver.MetadataInput::{
        name: item.name,
        bytes: packed_view(view, buffers),
      }
    })
    @sparse_solver.validate_metadata(request, call.entry.key, metadata)
  } else {
    let request : @sparse_solver.LuRequest = @json.from_json(module.request)
    @sparse_solver.validate_lu_bindings(request, call.entry.key, bindings)
    let lower = @sparse_solver.lower_lu(request)
    let metadata = lower.metadata.map(fn(item) {
      let view = call.named[item.name]
      index_owner(view, immutable)
      @sparse_solver.MetadataInput::{
        name: item.name,
        bytes: packed_view(view, buffers),
      }
    })
    @sparse_solver.validate_lu_metadata(request, call.entry.key, metadata)
  }
}

///|
fn validate_newton_solver(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let request : @newton_solver.Request = @json.from_json(module.request)
  let bindings = call.entry.parameters
    .filter(p => p.kind == "array")
    .map(fn(p) {
      let view = call.named[p.name]
      @newton_solver.Binding::{
        name: p.name,
        allocation: view.buffer,
        dtype: view.dtype,
        shape: view.shape,
        byte_strides: view.byte_strides,
        byte_offset: view.offset_bytes.to_int64(),
        buffer_bytes: buffers[view.buffer].bytes.length().to_int64(),
      }
    })
  @newton_solver.validate_bindings(request, call.entry.key, bindings)
  if call.entry.key == "initialize-controls" {
    return
  }
  let metadata : Map[String, Bytes] = {}
  for name in @newton_solver.immutable_parameters(request) {
    guard call.named.get(name) is Some(view) else {
      fail("Newton solver omitted an immutable input")
    }
    metadata[name] = packed_view(view, buffers)
    // Index bounds and convergence constants are proved from initial bytes.
    // Numeric model values are also checked by every real device entry and may
    // be produced by a native preparation prefix before state initialization.
    if view.dtype == "int32" ||
      [
        "opt_tolerance", "opt_ls_tolerance", "stat_meaninertia", "opt_impratio_invsqrt",
      ].contains(name) {
      index_owner(view, immutable)
    }
  }
  @newton_solver.validate_metadata(request, metadata)
}

///|
fn validate_solver_metrics(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let request : @solver_metrics.Request = @json.from_json(module.request)
  let bindings = call.entry.parameters.map(fn(p) {
    let view = call.named[p.name]
    @solver_metrics.Binding::{
      name: p.name,
      owner: view.buffer,
      dtype: view.dtype,
      shape: view.shape,
      byte_strides: view.byte_strides,
      offset_bytes: view.offset_bytes,
      capacity_bytes: buffers[view.buffer].bytes.length().to_uint64(),
    }
  })
  @solver_metrics.validate_bindings(request, call.entry.key, bindings)
  for name in @solver_metrics.immutable_parameters() {
    if call.named.get(name) is Some(view) {
      index_owner(view, immutable)
    }
  }
}

///|
fn validate_solver_adapters(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let request : @solver_adapters.Request = @json.from_json(module.request)
  let bindings = call.entry.parameters.map(fn(p) {
    let view = call.named[p.name]
    @solver_adapters.Binding::{
      name: p.name,
      allocation: view.buffer,
      dtype: view.dtype,
      shape: view.shape,
      byte_strides: view.byte_strides,
      byte_offset: view.offset_bytes.to_int64(),
      buffer_bytes: buffers[view.buffer].bytes.length().to_int64(),
    }
  })
  @solver_adapters.validate_bindings(request, call.entry.key, bindings)
  let snapshots : Map[String, Bytes] = {}
  for name in @solver_adapters.immutable_parameters(request, call.entry.key) {
    let view = call.named[name]
    snapshots[name] = packed_view(view, buffers)
    index_owner(view, immutable)
  }
  @solver_adapters.validate_metadata(request, call.entry.key, snapshots)
}
