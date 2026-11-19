///|
struct Recorded {
  operations : UInt32
  results : Map[String, Bytes]
}

///|
/// This synchronous scope owns all native resources. No filesystem coroutine
/// can yield between opening the thread-bound writer and closing its handles.
fn record(
  config : CaptureConfig,
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
    fail(
      "kernel capture: actual CUDA architecture differs from explicit compiled target",
    )
  }
  let owned : Array[@dispatch.Buffer] = []
  defer (for buffer in owned {
    buffer.close()
  })
  let buffers : Map[String, @dispatch.Buffer] = {}
  for source in prepared.buffers {
    let buffer = context.allocate(source.bytes.length().to_uint64())
    owned.push(buffer)
    buffer.write(source.bytes)
    buffers[source.input.name] = buffer
  }
  let module_hash = prepared.specialization.specialization_sha256
  let kernel = context.load_kernel(
    output + "/kernel_modules/module." + prepared.image_kind,
    "moonrobo_concrete_" + module_hash,
    module_hash,
    prepared.entry.key,
    prepared.entry.forward,
    kernel_dim=prepared.entry.launch_shape.length(),
    block_dim=256,
  )
  defer kernel.close()
  let arguments : Array[@dispatch.Argument] = prepared.arguments.map(fn(
    argument,
  ) {
    match argument {
      Array(array, width) =>
        @dispatch.Argument::array(
          buffers[array.buffer],
          array.shape,
          array.byte_strides,
          width.to_uint(),
          offset=array.offset_bytes,
        )
      Integer(value) => @dispatch.Argument::int32(value)
      Boolean(value) => @dispatch.Argument::boolean(value)
    }
  })
  let writer = @warp.Writer::create(
    prepared.writer_plugin,
    prepared.warp_library,
    context=context.pointer(),
    stream=context.stream(),
    arch=config.architecture,
  )
  defer (writer.close() catch { _ => () })
  guard writer.version() == "1.17.0" else {
    fail("kernel capture: actual Warp version differs from pinned ABI")
  }
  // APIC recording executes the CUDA launch. Snapshot *before* begin so replay
  // starts from the exact original inputs instead of applying an update twice.
  for source in prepared.buffers {
    let buffer = buffers[source.input.name]
    let pointer = buffer.pointer()
    let bytes = buffer.size()
    let region = writer.register_region(pointer, bytes, element_size=1U)
    writer.snapshot_region(region, pointer, bytes, element_size=1U)
    writer.register_binding(source.input.name, region)
  }
  writer.begin()
  kernel.launch(
    prepared.entry.launch_shape,
    arguments,
    capture_state=writer.state_pointer(),
  ) catch {
    error => {
      writer.end() catch {
        _ => ()
      }
      raise error
    }
  }
  writer.end()
  let operations = writer.operation_count()
  guard operations > 0U else {
    fail("kernel capture: actual APIC recording contains no operations")
  }
  context.synchronize()
  writer.save(output + "/kernel.wrp")
  let results : Map[String, Bytes] = {}
  for source in prepared.buffers {
    results[source.input.name] = buffers[source.input.name].read(
      source.bytes.length(),
    )
  }
  { operations, results, }
}

///|
/// Explicitly execute and serialize one real ported concrete kernel. This
/// command neither compiles code nor creates a complete G1 physics bundle.
pub async fn capture(config : CaptureConfig) -> Json {
  let prepared = prepare(config)
  @fs.mkdir(config.output, recursive=true)
  let output = @fs.realpath(config.output)
  @fs.mkdir(output + "/kernel_modules")
  @fs.write_file(
    output + "/kernel_modules/module." + prepared.image_kind,
    prepared.image,
    create_mode=CreateNew,
  )
  @fs.write_file(
    output + "/kernels.cu",
    prepared.specialization.source,
    create_mode=CreateNew,
  )
  @fs.write_file(
    output + "/compiled-manifest.json",
    prepared.manifest_bytes,
    create_mode=CreateNew,
  )
  @fs.write_file(output + "/NOTICE", prepared.notice, create_mode=CreateNew)
  @fs.write_file(
    output + "/request.json",
    config.to_json().stringify(indent=2),
    create_mode=CreateNew,
  )
  @fs.mkdir(output + "/inputs")
  @fs.mkdir(output + "/observed")
  let inputs : Array[Json] = []
  // File names use stable sequence numbers, never untrusted buffer names.
  for index, source in prepared.buffers {
    let path = "inputs/" + index.to_string() + ".bin"
    @fs.write_file(output + "/" + path, source.bytes, create_mode=CreateNew)
    inputs.push({
      "name": source.input.name.to_json(),
      "path": path.to_json(),
      "scalar_type": source.input.scalar_type.to_json(),
      "bytes": source.bytes.length().to_json(),
      "sha256": source.input.sha256.to_json(),
    })
  }
  let plugin_identities : Array[Json] = []
  for
    (role, path) in [
      ("dispatch", prepared.dispatch_plugin),
      ("writer", prepared.writer_plugin),
      ("warp", prepared.warp_library),
    ] {
    plugin_identities.push({
      "role": role.to_json(),
      "path": path.to_json(),
      "sha256": @artifacts.sha256(@fs.read_file(path).binary()).to_json(),
    })
  }
  let recorded = record(config, prepared, output)
  let observed : Array[Json] = []
  for index, source in prepared.buffers {
    let path = "observed/" + index.to_string() + ".bin"
    let bytes = recorded.results[source.input.name]
    @fs.write_file(output + "/" + path, bytes, create_mode=CreateNew)
    observed.push({
      "name": source.input.name.to_json(),
      "path": path.to_json(),
      "bytes": bytes.length().to_json(),
      "sha256": @artifacts.sha256(bytes).to_json(),
    })
  }
  let graph = @fs.read_file(output + "/kernel.wrp").binary()
  let receipt : Json = {
    "format": "moonrobo-concrete-kernel-apic-capture-v1",
    "producer": "moonbit-native-concrete-kernel-capture",
    "kernel_key": prepared.entry.key.to_json(),
    "entry": prepared.entry.to_json(),
    "specialization_sha256": prepared.specialization.specialization_sha256.to_json(),
    "source_sha256": prepared.specialization.source_sha256.to_json(),
    "compiled_manifest_sha256": config.compiled_manifest_sha256.to_json(),
    "notice_sha256": @artifacts.sha256(prepared.notice).to_json(),
    "image": {
      "path": ("kernel_modules/module." + prepared.image_kind).to_json(),
      "sha256": prepared.image_sha256.to_json(),
    },
    "graph": {
      "path": "kernel.wrp",
      "sha256": @artifacts.sha256(graph).to_json(),
      "operations": recorded.operations.to_json(),
    },
    "libraries": plugin_identities.to_json(),
    "initial_buffers": inputs.to_json(),
    "observed_after_capture": observed.to_json(),
    "arguments": config.arguments.to_json(),
    "snapshot_timing": "actual-owned-initial-bytes-before-first-launch",
    "cuda_device_ordinal": config.device_ordinal.to_json(),
    "cuda_architecture": config.architecture.to_json(),
    "warp_version": "1.17.0",
    "apic_capture_recorded": true,
    "capture_executes_kernel": true,
    "kernel_replayed_after_capture": false,
    "warp_meta_generated": false,
    "full_aligned_bundle": false,
    "full_g1_solver_closure": false,
    "runtime_equivalence_verified": false,
    "runtime_replay_validated": false,
    "compiler_invoked": false,
    "python_interpreter_initialized": false,
    "physics_solver_initialized": false,
    "transitive_native_dependencies_attested": false,
  }
  @fs.write_file(
    output + "/manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
