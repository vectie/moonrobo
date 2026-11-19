///|
/// Explicitly compile real source-specialized operations, without constructing a
/// model or CUDA context. A module is not a complete physics solver or capture.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    raise Unsupported::Invalid("fresh output directory required")
  }
  let kind = match config.kind {
    "ptx" => @compiler.ImageKind::Ptx
    "cubin" => @compiler.ImageKind::Cubin
    _ => raise Unsupported::Invalid("kind must be ptx or cubin")
  }
  let options = compile_options(config.options, config.kind)
  let root = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let native = @fs.realpath(config.warp_native)
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let sources : Map[String, Bytes] = {}
  let definitions : Array[Json] = []
  for entry in lowered.entries {
    if !sources.contains(entry.source_file) {
      let bytes = @fs.read_file(root + entry.source_file).binary()
      guard @artifacts.sha256(bytes) == entry.source_sha256 else {
        raise Unsupported::Invalid(
          "MuJoCo-Warp 3.15 source differs: " + entry.source_file,
        )
      }
      sources[entry.source_file] = bytes
    }
    let text = @utf8.decode(sources[entry.source_file])
    let names = [entry.source_function]
    names.append(entry.helper_functions)
    for name in names {
      definitions.push({
        "entry": entry.key.to_json(),
        "file": entry.source_file.to_json(),
        "function": name.to_json(),
        "source_file_sha256": entry.source_sha256.to_json(),
        "definition_sha256": @artifacts.sha256(
          @utf8.encode(definition(text, name)),
        ).to_json(),
      })
    }
  }
  let layouts : Array[Json] = []
  if config.request.kernels.contains("mass-multiply-sparse") {
    let io = @fs.read_file(root + "io.py").binary()
    guard @artifacts.sha256(io) == source_sha("io.py") else {
      raise Unsupported::Invalid("MuJoCo-Warp sparse-layout source differs")
    }
    sources["io.py"] = io
    layouts.push({
      "function": "io.put_model",
      "ported_segment": "Gather-based sparse mul_m / row_elements to M_mulm CSR",
      "file": "io.py",
      "file_sha256": source_sha("io.py").to_json(),
      "segment_sha256": @artifacts.sha256(
        @utf8.encode(layout_excerpt(@utf8.decode(io))),
      ).to_json(),
    })
  }
  if config.request.kernels.contains("nxn-broadphase") {
    let types = @fs.read_file(root + "types.py").binary()
    guard @artifacts.sha256(types) ==
      "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b" else {
      raise Unsupported::Invalid(
        "MuJoCo-Warp collision enum/constant source differs",
      )
    }
    sources["types.py"] = types
  }
  let paths : Array[String] = []
  header_paths(native, "", paths)
  let headers : Array[@compiler.Header] = []
  let header_bytes : Map[String, Bytes] = {}
  let header_inventory : Array[Json] = []
  let mut total = 0
  for name in paths {
    let bytes = @fs.read_file(native + "/" + name).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise Unsupported::Invalid("native header capacity exceeded")
    }
    total += bytes.length()
    headers.push({ include_name: name, source: @utf8.decode(bytes), })
    header_bytes[name] = bytes
    header_inventory.push({
      "include_name": name.to_json(),
      "path": ("headers/" + name).to_json(),
      "sha256": @artifacts.sha256(bytes).to_json(),
    })
  }
  for
    (name, sha) in [
      (
        "builtin.h", "9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf",
      ),
      (
        "array.h", "f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a",
      ),
    ] {
    guard header_bytes.get(name) is Some(bytes) &&
      @artifacts.sha256(bytes) == sha else {
      raise Unsupported::Invalid("pinned Warp 1.17 ABI header differs: " + name)
    }
  }
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let compiler = @compiler.Compiler::open(nvrtc)
  let compiled = compiler.compile({
    source: lowered.source,
    program_name: "moonrobo-mjw-physics.cu",
    headers,
    options,
    kind,
  })
  let image = "module." + config.kind
  let manifest : Json = {
    "format": "moonrobo-mjw-concrete-physics-module-v1",
    "producer": "moonbit-native-typed-mujoco-warp-subset",
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
    "request": config.request.to_json(),
    "source": {
      "path": "physics.cu",
      "sha256": lowered.source_sha256.to_json(),
    },
    "specialization_sha256": lowered.specialization_sha256.to_json(),
    "entries": lowered.entries.to_json(),
    "definitions": definitions.to_json(),
    "layouts": layouts.to_json(),
    "headers": header_inventory.to_json(),
    "abi_headers_attested": ["array.h", "builtin.h"],
    "other_header_bytes_observed_and_snapshotted": true,
    "external_include_bytes_attested": false,
    "compiler": {
      "path": nvrtc.to_json(),
      "sha256": compiler_sha.to_json(),
      "version": compiled.version.to_json(),
      "options": options.to_json(),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "path": image.to_json(),
      "kind": config.kind.to_json(),
      "sha256": @artifacts.sha256(compiled.image).to_json(),
    },
    "log": {
      "path": "compile.log",
      "sha256": @artifacts.sha256(@utf8.encode(compiled.log)).to_json(),
    },
    "constant_bindings": {
      "mjMAXVAL": 1.0e10,
      "mjGEOM_MESH": 7,
      "source": "MuJoCo mjmodel.h; MuJoCo-Warp3.15 types.py imports",
    },
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_policy": {
      "block_dim": 256,
      "forward_smem": 0,
      "backward_smem": 0,
      "grid_stride": true,
      "coord_mult": 1,
    },
    "launch_coord_mult": 1,
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "full_collision_closure": false,
    "narrowphase_generated": false,
    "sparse_factorization_generated": false,
    "full_solver_closure": false,
    "complete_timestep_generated": false,
    "apic_capture_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(folder + "physics.cu", lowered.source, create_mode=CreateNew)
  @fs.write_file(folder + image, compiled.image, create_mode=CreateNew)
  @fs.write_file(folder + "compile.log", compiled.log, create_mode=CreateNew)
  for name in paths {
    write_nested(folder + "headers/", name, header_bytes[name])
  }
  for name, bytes in sources {
    write_nested(folder + "upstream/", name + ".source", bytes)
  }
  @fs.write_file(
    folder + "manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
