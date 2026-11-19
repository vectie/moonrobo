///|
async fn headers(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => headers(root, path, paths)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          guard paths.length() < 4096 else {
            fail("Warp header inventory too large")
          }
          paths.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          fail("Warp header symlink/special file rejected")
        }
    }
  }
}

///|
async fn store(root : String, path : String, bytes : Bytes) -> Unit {
  let parts = path.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    fail("unsafe solver snapshot path")
  }
  let mut folder = root
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  for i in 0..<(parts.length() - 1) {
    folder += parts[i] + "/"
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + path, bytes, create_mode=CreateNew)
}

///|
/// Explicit real C NVRTC compilation, never invoked by source checking or
/// metadata/plan generation. Original sources/headers are passive snapshots.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  compile_generated(
    {
      mujoco_warp_root: config.mujoco_warp_root,
      warp_native: config.warp_native,
      nvrtc_library: config.nvrtc_library,
      options: config.options,
      kind: config.kind,
      output: config.output,
    },
    {
      format: "moonrobo-native-newton-solver-module-v1",
      source_name: "solver.cu",
      request: config.request.to_json(),
      source: lowered.source,
      source_sha256: lowered.source_sha256,
      specialization_sha256: lowered.specialization_sha256,
      entries: lowered.entries.to_json(),
      launch_policy: lowered.launch_policy.to_json(),
      coverage: source_coverage(),
    },
  )
}

///|
/// Shared native compiler/evidence engine for actual typed solver modules.
pub(all) struct NativeCompileConfig {
  mujoco_warp_root : String
  warp_native : String
  nvrtc_library : String
  options : Array[String]
  kind : String
  output : String
}

///|
pub(all) struct NativeModule {
  format : String
  source_name : String
  request : Json
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Json
  launch_policy : Json
  coverage : Json
}

///|
/// Does not run a numerical algorithm or a GPU. Only explicit callers invoke
/// the real compiler; lowerers and static checks never invoke this function.
pub async fn compile_generated(
  config : NativeCompileConfig,
  lowered : NativeModule,
) -> Json {
  guard !lowered.source_name.is_empty() &&
    !lowered.source_name.contains("/") &&
    !lowered.source_name.contains("\\") &&
    !lowered.source_name.contains("..") &&
    lowered.source_sha256 == @artifacts.sha256(@utf8.encode(lowered.source)) else {
    fail("invalid typed module source identity")
  }
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    fail("fresh Newton solver artifact output required")
  }
  let kind = match config.kind {
    "ptx" => @compiler.Ptx
    "cubin" => @compiler.Cubin
    _ => fail("PTX or CUBIN image kind required")
  }
  let arch = config.options.filter(o => {
    o.has_prefix("--gpu-architecture=") || o.has_prefix("-arch=")
  })
  guard arch.length() == 1 &&
    (
      (config.kind == "ptx" && arch[0].contains("=compute_")) ||
      (config.kind == "cubin" && arch[0].contains("=sm_"))
    ) else {
    fail("one explicit matching native target required")
  }
  guard !config.options.any(o => {
    (o.has_prefix("--std=") || o.has_prefix("-std=")) &&
    o != "--std=c++17" &&
    o != "-std=c++17"
  }) else {
    fail("C++17 required")
  }
  let options = config.options.copy()
  if !options.contains("--std=c++17") && !options.contains("-std=c++17") {
    options.push("--std=c++17")
  }
  if !options.contains("--device-as-default-execution-space") {
    options.push("--device-as-default-execution-space")
  }
  let upstream = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let source_bytes : Map[String, Bytes] = {}
  let evidence : Array[Json] = []
  for (name, sha) in primary_sources() {
    let bytes = @fs.read_file(upstream + name).binary()
    guard @artifacts.sha256(bytes) == sha else {
      fail("pinned solver primary source differs: " + name)
    }
    source_bytes[name] = bytes
    evidence.push({
      "file": Json(name),
      "sha256": Json(sha),
      "snapshot": Json("upstream/" + name + ".source"),
    })
  }
  let native = @fs.realpath(config.warp_native)
  let paths : Array[String] = []
  headers(native, "", paths)
  let supplied : Array[@compiler.Header] = []
  let header_bytes : Map[String, Bytes] = {}
  let inventory : Array[Json] = []
  let mut total = 0
  for name in paths {
    let bytes = @fs.read_file(native + "/" + name).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      fail("Warp headers exceed fixed byte budget")
    }
    total += bytes.length()
    header_bytes[name] = bytes
    supplied.push({ include_name: name, source: @utf8.decode(bytes), })
    inventory.push({
      "include_name": Json(name),
      "path": Json("headers/" + name),
      "sha256": Json(@artifacts.sha256(bytes)),
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
      fail("genuine Warp 1.17 array ABI header differs")
    }
  }
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let backend = @compiler.Compiler::open(nvrtc)
  let result = backend.compile({
    source: lowered.source,
    program_name: lowered.source_name,
    headers: supplied,
    options,
    kind,
  })
  let receipt : Json = {
    "format": Json(lowered.format),
    "producer": "moonbit-native-typed-solver-module",
    "request": lowered.request,
    "source": {
      "path": Json(lowered.source_name),
      "sha256": Json(lowered.source_sha256),
    },
    "entries": lowered.entries,
    "specialization_sha256": Json(lowered.specialization_sha256),
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
    "upstream_files": Json(evidence),
    "callable_coverage": lowered.coverage,
    "headers": Json(inventory),
    "abi_headers_attested": ["array.h", "builtin.h"],
    "external_include_bytes_attested": false,
    "compiler": {
      "path": Json(nvrtc),
      "sha256": Json(compiler_sha),
      "version": result.version.to_json(),
      "options": Json(options),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "kind": Json(config.kind),
      "path": Json("module." + config.kind),
      "sha256": Json(@artifacts.sha256(result.image)),
    },
    "log": {
      "path": "compile.log",
      "sha256": Json(@artifacts.sha256(@utf8.encode(result.log))),
    },
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_coord_mult": 1,
    "launch_policy": lowered.launch_policy,
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "status_parameter": "status",
    "status_is_sticky": true,
    "publication_requires_status_zero": true,
    "reference_reduction": "serial-fp32-per-world",
    "factorization": "actual-global-scratch-dense-cholesky",
    "tiled_association_preserved": false,
    "added_metric_construction": "explicit-caller-owned-effective-metric",
    "full_model_dynamics_generated": false,
    "supported_reference_iteration_body_generated": Json(
      lowered.format == "moonrobo-native-newton-solver-module-v1",
    ),
    "incremental_fast_path_generated": false,
    "compact_sleep_adapters_generated": false,
    "full_upstream_solver_closure": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(
    folder + lowered.source_name,
    lowered.source,
    create_mode=CreateNew,
  )
  @fs.write_file(
    folder + "module." + config.kind,
    result.image,
    create_mode=CreateNew,
  )
  @fs.write_file(folder + "compile.log", result.log, create_mode=CreateNew)
  for name in paths {
    store(folder + "headers/", name, header_bytes[name])
  }
  for name, bytes in source_bytes {
    store(folder + "upstream/", name + ".source", bytes)
  }
  @fs.write_file(
    folder + "manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
