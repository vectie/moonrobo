///|
fn PyValue::uint64(self : PyValue) -> UInt64 raise {
  let text = self.text()
  if text == "None" {
    0UL
  } else {
    @string.parse_uint64(text)
  }
}

///|
struct NativeModule {
  hash : String
  name : String
  filename : String
}

///|
struct NativeSnapshot {
  id : UInt32
  pointer : UInt64
  capacity : UInt64
  transient : Bool
}

///|
fn basename(name : String) -> Unit raise {
  guard @contracts.relative_path(name) && !name.contains("/") else {
    fail("compiled APIC module filename must be a portable basename")
  }
}

///|
async fn copy_module_file(source : String, destination : String) -> String {
  let bytes = @fs.read_file(source).binary()
  if @fs.exists(destination) {
    guard @fs.read_file(destination).binary() == bytes else {
      fail("different captured modules share one artifact filename")
    }
  } else {
    @fs.write_file(destination, bytes, create_mode=CreateNew)
  }
  @artifacts.sha256(bytes)
}

///|
/// Port of the pinned capture_save bookkeeping. Python still owns the live
/// scene/capture; MoonBit owns file packaging and calls the native APIC C ABI.
/// The graph and its allocation owners stay strongly referenced by this call.
async fn Scene::save_native(
  self : Scene,
  graph : PyValue,
  path : String,
  regions : Array[Region],
  config : ExportConfig,
) -> Json {
  guard graph.attr("apic").bool() && graph.attr("device").attr("is_cuda").bool() else {
    fail("native IO requires a genuine CUDA APIC graph")
  }
  let py = self.py
  let capture = graph.attr("_apic_capture")
  let state = graph.attr("apic_state").uint64()
  guard state != 0UL && state == capture.attr("apic_state").uint64() else {
    fail("graph does not own the supplied APIC recording state")
  }
  let device = graph.attr("device")
  let context = device.attr("context").uint64()
  let stream = device.attr("stream").attr("cuda_stream").uint64()
  let arch = py.method(device, "get_cuda_compile_arch").int()
  guard path.has_suffix(".wrp") else { fail("APIC path must end in .wrp") }
  let folder = path[:path.length() - 4].to_owned() + "_modules"
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  let modules : Array[NativeModule] = []
  let module_files : Array[Json] = []
  for entry in py.method(capture.attr("collected_modules"), "items").list(py) {
    let hash = py.index(entry, 0).text()
    let info = py.index(entry, 1)
    let filename = info.item(py.literal("binary_filename")).text()
    basename(filename)
    guard filename.has_suffix(".cubin") || filename.has_suffix(".ptx") else {
      fail("CUDA capture module must be an actual PTX or CUBIN image")
    }
    let source = info.item(py.literal("binary_path")).text()
    guard source != "None" && !source.is_empty() && @fs.exists(source) else {
      fail("captured module has no real compiled binary")
    }
    let name = info.item(py.literal("module_name")).text()
    guard !modules.any(m => m.hash == hash) else {
      fail("duplicate captured module hash")
    }
    let image_sha = copy_module_file(source, folder + "/" + filename)
    let suffix = if filename.has_suffix(".cubin") { 6 } else { 4 }
    let meta = filename[:filename.length() - suffix].to_owned() + ".meta"
    // Native APIC stores entry names/shared-memory metadata in the recording
    // and loads images directly. Preserve a genuine Python cache companion if
    // available, but do not manufacture one or require it for native loading.
    let parent = source.split("/").to_array()
    ignore(parent.pop())
    let meta_source = parent.join("/") + "/" + meta
    let metadata : Json = if @fs.exists(meta_source) {
      let meta_sha = copy_module_file(meta_source, folder + "/" + meta)
      { "path": meta.to_json(), "sha256": meta_sha.to_json() }
    } else {
      Json::null()
    }
    modules.push({ hash, name, filename, })
    module_files.push({
      "binary": filename.to_json(),
      "binary_sha256": image_sha.to_json(),
      "optional_warp_cache_metadata": metadata,
      "module_hash": hash.to_json(),
    })
  }
  let entries = py.method(capture.attr("_regions"), "values").list(py)
  let transient_ids = capture.attr("_transient_regions")
  let snapshots : Array[NativeSnapshot] = []
  for entry in entries {
    let raw_id = py.index(entry, 0)
    let id = raw_id.uint64()
    guard id > 0UL && id <= 2147483647UL else {
      fail("APIC region ID exceeds supported exact range")
    }
    snapshots.push({
      id: id.to_uint(),
      pointer: py.index(entry, 1).uint64(),
      capacity: py.index(entry, 2).uint64(),
      transient: py.method(transient_ids, "__contains__", args=[raw_id]).bool(),
    })
  }
  let bindings : Array[(String, UInt32)] = []
  for region in regions {
    let id = py.method(capture, "get_region_id", args=[region.base]).uint64()
    guard snapshots.any(item => {
      item.id.to_uint64() == id &&
      item.pointer == region.ptr.to_uint64() &&
      item.capacity == region.bytes.to_uint64() &&
      !item.transient
    }) else {
      fail("named numeric base is absent from the audited persistent recording")
    }
    bindings.push((region.name, id.to_uint()))
  }
  let kernels = py.method(capture.attr("collected_kernels"), "values").list(py)
  let meshes = capture.attr("collected_mesh_ids").list(py)
  let model_owner = self.model.identity()
  // Do all async file IO before borrowing the thread-affine native recording.
  // Borrowing never initializes Warp or takes ownership of the scene/context.
  let writer = @warp.Writer::borrow(
    config.warp_adapter,
    config.warp_library,
    state,
    context,
    stream,
    arch,
  )
  defer (writer.close() catch { _ => () })
  for item in modules {
    writer.register_module(item.hash, item.name, item.filename)
  }
  for info in kernels {
    writer.register_kernel(
      info.item(py.literal("kernel_key")).text(),
      info.item(py.literal("module_hash")).text(),
      info.item(py.literal("forward_name")).text(),
      info.item(py.literal("backward_name")).text(),
      info.item(py.literal("forward_smem_bytes")).int(),
      info.item(py.literal("backward_smem_bytes")).int(),
      info.item(py.literal("block_dim")).int(),
    )
  }
  for item in snapshots {
    writer.snapshot_region(
      item.id,
      item.pointer,
      item.capacity,
      transient=item.transient,
    )
  }
  for (name, id) in bindings {
    writer.register_binding(name, id)
  }
  for id in meshes {
    writer.register_mesh(id.uint64())
  }
  let count = writer.operation_count()
  guard count > 0U else { fail("native writer refuses an empty APIC capture") }
  writer.save(path)
  // These actual identity reads keep the graph, capture and complete model
  // owners alive through the final native snapshot/save, including early RC.
  guard graph.attr("apic_state").uint64() == state &&
    capture.attr("apic_state").uint64() == state &&
    self.model.identity() == model_owner else {
    fail("live capture/model owner changed during native save")
  }
  {
    "format": "moonrobo.apic-native-save.v1",
    "path": path.to_json(),
    "operation_count": count.to_json(),
    "modules": module_files.to_json(),
    "snapshot_regions": snapshots.length().to_json(),
    "python_capture_save_called": false,
    "live_capture_owner": "upstream-Python-SDK",
    "runtime_parity_verified": false,
  }
}
