///|
struct Recorded {
  operations : UInt32
  results : Map[String, Bytes]
  executed : Bool
  narrowphase_validated : Bool
}

///|
fn execute_ops(
  program : Array[Op],
  context : @dispatch.Context,
  buffers : Map[String, @dispatch.Buffer],
  kernels : Map[String, @dispatch.Kernel],
  state : UInt64,
  modules : Map[String, Module],
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) => {
        let arguments = call.arguments.map(fn(arg) {
          match arg {
            Array(view, width) =>
              @dispatch.Argument::array(
                buffers[view.buffer],
                view.shape,
                view.byte_strides,
                width.to_uint(),
                offset=view.offset_bytes,
              )
            Int32(value) => @dispatch.Argument::int32(value)
            Boolean(value) => @dispatch.Argument::boolean(value)
            Float32(value) => @dispatch.Argument::float32(value)
            Float64(value) => @dispatch.Argument::float64(value)
          }
        })
        kernels[call.module + "::" + call.entry.key].launch(
          call.entry.shape,
          arguments,
          capture_state=state,
          grid_stride=modules[call.module].policy.grid_stride,
        )
      }
      CopyBytes(copy) =>
        context.copy_external(
          buffers[copy.destination].pointer() + copy.destination_offset,
          buffers[copy.source].pointer() + copy.source_offset,
          copy.count_bytes,
          capture_state=state,
        )
      ZeroBytes(zero) =>
        context.zero_external(
          buffers[zero.buffer].pointer() + zero.offset_bytes,
          zero.count_bytes,
          capture_state=state,
        )
      If(view, yes, no) => {
        let predicate = buffers[view.buffer].typed_view(
          @dispatch.I32,
          1,
          offset=view.offset_bytes,
        )
        context.capture_if(
          predicate,
          capture_state=state,
          on_true=fn() {
            execute_ops(yes, context, buffers, kernels, state, modules)
          },
          on_false=fn() {
            execute_ops(no, context, buffers, kernels, state, modules)
          },
        )
      }
      While(view, body) => {
        let predicate = buffers[view.buffer].typed_view(
          @dispatch.I32,
          1,
          offset=view.offset_bytes,
        )
        context.capture_while(
          predicate,
          fn() { execute_ops(body, context, buffers, kernels, state, modules) },
          capture_state=state,
        )
      }
    }
  }
}

///|
/// All native work is synchronous: no filesystem coroutine can yield and
/// move opening-thread-affine handles. Owners outlive capture/save/observation.
fn record(
  config : Config,
  prepared : Prepared,
  output : String,
) -> Recorded raise {
  let context = @dispatch.Context::create(
    prepared.dispatch_plugin,
    prepared.warp_library,
    config.device_ordinal,
  )
  defer context.close()
  guard context.architecture() == config.architecture else {
    fail("actual CUDA architecture differs from pinned image target")
  }
  let owned : Array[@dispatch.Buffer] = []
  defer (for buffer in owned {
    buffer.close()
  })
  let buffers : Map[String, @dispatch.Buffer] = {}
  for name, source in prepared.buffers {
    let buffer = context.allocate(source.bytes.length().to_uint64())
    owned.push(buffer)
    buffer.write(source.bytes)
    buffers[name] = buffer
  }
  let owned_kernels : Array[@dispatch.Kernel] = []
  defer (for kernel in owned_kernels {
    kernel.close()
  })
  let kernels : Map[String, @dispatch.Kernel] = {}
  for id, module in prepared.modules {
    for key, entry in module.entries {
      let kernel = context.load_kernel(
        output + "/pipeline_modules/" + id + "." + module.image_kind,
        "moonrobo_gpu_" + id,
        module.image_sha256,
        id + "::" + key,
        entry.forward,
        kernel_dim=entry.shape.length(),
        block_dim=module.policy.block_dim,
        forward_smem=module.policy.forward_smem,
        backward_smem=module.policy.backward_smem,
      )
      owned_kernels.push(kernel)
      kernels[id + "::" + key] = kernel
    }
  }
  let graph : Ref[@dispatch.Graph?] = Ref(None)
  let writer = @warp.Writer::create(
    prepared.writer_plugin,
    prepared.warp_library,
    context=context.pointer(),
    stream=context.stream(),
    arch=config.architecture,
  )
  defer (writer.close() catch { _ => () })
  defer (if graph.val is Some(value) { value.close() })
  guard writer.version() == "1.17.0" else {
    fail("actual Warp library ABI version differs")
  }
  for name, source in prepared.buffers {
    let buffer = buffers[name]
    let ptr = buffer.pointer()
    let size = source.bytes.length().to_uint64()
    let region = writer.register_region(ptr, size, element_size=1U)
    writer.snapshot_region(region, ptr, size, element_size=1U)
    writer.register_binding(name, region)
  }
  writer.begin()
  let state = writer.state_pointer()
  try {
    if config.mode == "capture" {
      graph.val = Some(
        context.capture_graph(
          fn() {
            execute_ops(
              prepared.program,
              context,
              buffers,
              kernels,
              state,
              prepared.modules,
            )
          },
          capture_state=state,
        ),
      )
    } else {
      execute_ops(
        prepared.program,
        context,
        buffers,
        kernels,
        state,
        prepared.modules,
      )
    }
  } catch {
    error => {
      // Native capture failure discards the graph and poisons its context.
      // No eager retry or successful receipt follows this failure.
      writer.end() catch {
        _ => ()
      }
      raise error
    }
  }
  writer.end()
  let operations = writer.operation_count()
  guard operations > 0U else { fail("actual APIC recording is empty") }
  let executed = config.mode == "eager" || config.launch_captured_graph
  if config.launch_captured_graph {
    guard graph.val is Some(value) else { fail("captured graph owner missing") }
    value.launch()
  }
  context.synchronize()
  let results : Map[String, Bytes] = {}
  let observed : Map[String, HostBuffer] = {}
  for name, source in prepared.buffers {
    let bytes = buffers[name].read(source.bytes.length())
    results[name] = bytes
    observed[name] = { name, scalar_type: source.scalar_type, bytes, }
  }
  let mut narrowphase_validated = false
  if executed {
    validate_convergence_results(
      prepared.convergence,
      prepared.modules,
      observed,
    )
    validate_stage_results(prepared, observed)
    validate_solver_results(prepared.sticky_status, observed)
    validate_line_flag_results(prepared.line_flags, observed)
  }
  if executed && prepared.narrowphase is Some(call) {
    let r : @narrowphase.Request = @json.from_json(
      prepared.modules[call.module].request,
    )
    let rejected = call.named["rejected_out"]
    let count = scalar_i32(call.named["nacon_out"], observed, [0])
    guard scalar_i32(rejected, observed, [0]) == 0 &&
      scalar_i32(rejected, observed, [1]) == 0 &&
      count >= 0 &&
      count <= r.contact_capacity else {
      fail(
        "narrowphase refused publication: rejected pair/input or contact capacity overflow",
      )
    }
    narrowphase_validated = true
  }
  writer.save(output + "/pipeline.wrp")
  { operations, results, executed, narrowphase_validated, }
}

///|
/// Explicit native execution/capture. No compiler, SDK, host factorization or
/// complete solver is implicitly invoked. Source checks never call this API.
pub async fn execute(
  config : Config,
  initial_buffers~ : Array[HostBuffer] = [],
) -> Json {
  let prepared = prepare(config, initial_buffers)
  @fs.mkdir(config.output, recursive=true)
  let output = @fs.realpath(config.output)
  for
    directory in [
      "pipeline_modules", "sources", "compiled", "initial", "observed",
    ] {
    @fs.mkdir(output + "/" + directory)
  }
  let request = @utf8.encode(config.to_json().stringify(indent=2))
  @fs.write_file(output + "/request.json", request, create_mode=CreateNew)
  let modules : Array[Json] = []
  let module_names = prepared.modules.keys().collect()
  module_names.sort()
  for id in module_names {
    let module = prepared.modules[id]
    let source = "sources/" + id + ".cu"
    let image = "pipeline_modules/" + id + "." + module.image_kind
    let manifest = "compiled/" + id + ".json"
    @fs.write_file(output + "/" + source, module.source, create_mode=CreateNew)
    @fs.write_file(output + "/" + image, module.image, create_mode=CreateNew)
    @fs.write_file(
      output + "/" + manifest,
      module.manifest,
      create_mode=CreateNew,
    )
    let notice : Json = match module.notice {
      Some(bytes) => {
        let path = "sources/" + id + ".NOTICE"
        @fs.write_file(output + "/" + path, bytes, create_mode=CreateNew)
        { "path": Json(path), "sha256": Json(@artifacts.sha256(bytes)) }
      }
      None => Json(null)
    }
    modules.push({
      "id": Json(id),
      "format": Json(module.kind),
      "compiled_manifest": {
        "path": Json(manifest),
        "sha256": Json(module.manifest_sha256),
      },
      "source": { "path": Json(source), "sha256": Json(module.source_sha256) },
      "image": { "path": Json(image), "sha256": Json(module.image_sha256) },
      "specialization_sha256": Json(module.specialization_sha256),
      "launch_policy": module.policy.to_json(),
      "notice": notice,
    })
  }
  let libraries : Array[Json] = []
  for
    (role, path) in [
      ("dispatch", prepared.dispatch_plugin),
      ("writer", prepared.writer_plugin),
      ("warp", prepared.warp_library),
    ] {
    libraries.push({
      "role": Json(role),
      "path": Json(path),
      "sha256": Json(@artifacts.sha256(@fs.read_file(path).binary())),
    })
  }
  let names = prepared.buffers.keys().collect()
  names.sort()
  let initial : Array[Json] = []
  for index, name in names {
    let buffer = prepared.buffers[name]
    let path = "initial/" + index.to_string() + ".bin"
    @fs.write_file(output + "/" + path, buffer.bytes, create_mode=CreateNew)
    initial.push({
      "name": Json(name),
      "path": Json(path),
      "scalar_type": Json(buffer.scalar_type),
      "byte_length": Json(buffer.bytes.length()),
      "sha256": Json(@artifacts.sha256(buffer.bytes)),
    })
  }
  let recorded = record(config, prepared, output)
  for identity in libraries {
    let path = text(identity, "path")
    guard @artifacts.sha256(@fs.read_file(path).binary()) ==
      text(identity, "sha256") else {
      fail("native library file changed during pipeline execution")
    }
  }
  let observed : Array[Json] = []
  for index, name in names {
    let bytes = recorded.results[name]
    let path = "observed/" + index.to_string() + ".bin"
    @fs.write_file(output + "/" + path, bytes, create_mode=CreateNew)
    observed.push({
      "name": Json(name),
      "path": Json(path),
      "byte_length": Json(bytes.length()),
      "sha256": Json(@artifacts.sha256(bytes)),
    })
  }
  let receipt : Json = {
    "format": "moonrobo-native-gpu-pipeline-v1",
    "producer": "moonbit-owned-native-module-program",
    "request": {
      "path": "request.json",
      "sha256": Json(@artifacts.sha256(request)),
    },
    "modules": Json(modules),
    "libraries": Json(libraries),
    "initial_buffers": Json(initial),
    "observed_buffers": Json(observed),
    "apic": {
      "path": "pipeline.wrp",
      "sha256": Json(
        @artifacts.sha256(@fs.read_file(output + "/pipeline.wrp").binary()),
      ),
      "operation_count": Json(recorded.operations),
    },
    "mode": Json(config.mode),
    "cuda_graph_recorded": Json(config.mode == "capture"),
    "device_program_executed": Json(recorded.executed),
    "captured_graph_launched": Json(config.launch_captured_graph),
    "narrowphase_postexecution_gate_passed": Json(
      recorded.narrowphase_validated,
    ),
    "narrowphase_present": Json(prepared.narrowphase is Some(_)),
    "json_while_profile": "final-unconditional-clear-or-real-device-convergence-producer",
    "device_convergence_loops": Json(prepared.convergence.length()),
    "device_convergence_postexecution_gate_passed": Json(
      recorded.executed && !prepared.convergence.is_empty(),
    ),
    "mathdx_tile_launches": Json(prepared.tiles.length()),
    "mathdx_status_postexecution_gate_passed": Json(
      recorded.executed && !prepared.tiles.is_empty(),
    ),
    "convex_gjk_present": Json(prepared.convex is Some(_)),
    "convex_contact_stream_present": Json(prepared.convex_contacts is Some(_)),
    "convex_contact_postexecution_gate_passed": Json(
      recorded.executed && prepared.convex_contacts is Some(_),
    ),
    "convex_gjk_postexecution_gate_passed": Json(
      recorded.executed && prepared.convex is Some(_),
    ),
    "native_solver_status_groups": Json(prepared.sticky_status.length()),
    "native_solver_status_postexecution_gate_passed": Json(
      recorded.executed && !prepared.sticky_status.is_empty(),
    ),
    "snapshot_timing": "all-owned-initial-bytes-before-begin",
    "compiler_invoked": false,
    "python_runtime_required": false,
    "full_solver_closure": false,
    "full_aligned_bundle": false,
    "device_convergence_condition_updates_implemented": true,
    "full_solver_iteration_body_implemented": false,
    "native_reference_newton_cg_iteration_body_implemented": true,
    "native_compact_incremental_adapters_implemented": true,
    "native_mixed_sparse_tail_implemented": true,
    "runtime_equivalence_verified": false,
    "runtime_replay_validated": false,
    "transitive_native_dependencies_attested": false,
  }
  @fs.write_file(
    output + "/manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
