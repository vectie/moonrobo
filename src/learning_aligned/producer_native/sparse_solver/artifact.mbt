///|
priv struct Build {
  format : String
  request : Json
  source : String
  source_sha256 : String
  specialization_sha256 : String
  entries : Array[Entry]
  launch_policy : LaunchPolicy
  metadata : Array[Metadata]
  details : Json
  architecture : Int32
}

///|
fn strict(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise SolverError {
  guard value is Object(fields) &&
    fields.length() == allowed.length() &&
    fields.keys().all(key => allowed.contains(key)) else {
    raise Invalid("solver record contains missing or unknown fields")
  }
  fields
}

///|
pub fn decode_config(value : Json) -> CompileConfig raise {
  let fields = strict(value, [
    "request", "nvrtc_library", "warp_native", "mujoco_warp_root", "cuda_include_dirs",
    "output",
  ])
  let request = strict(fields["request"], [
    "layout", "dtype", "nworld", "block_dim", "architecture", "check_done",
  ])
  let layout = strict(request["layout"], [
    "tree_dofadr", "tree_dofnum", "dof_parentid", "m_rownnz", "m_rowadr", "m_colind",
    "qLD_block_adr", "qLD_block_total", "blocks",
  ])
  guard layout["blocks"] is Array(blocks) else {
    raise Invalid("actual mixed block list required")
  }
  for block in blocks {
    ignore(strict(block, ["start", "size", "elemid"]))
  }
  let config : CompileConfig = @json.from_json(value)
  ignore(lower(config.request))
  config
}

///|
pub fn decode_lu_config(value : Json) -> LuCompileConfig raise {
  let fields = strict(value, [
    "request", "nvrtc_library", "warp_native", "mujoco_warp_root", "cuda_include_dirs",
    "output",
  ])
  let request = strict(fields["request"], [
    "layout", "dtype", "nworld", "block_dim", "architecture", "check_done",
  ])
  ignore(
    strict(request["layout"], ["d_rownnz", "d_rowadr", "d_diag", "d_colind"]),
  )
  let config : LuCompileConfig = @json.from_json(value)
  ignore(lower_lu(config.request))
  config
}

///|
async fn headers_in(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  guard paths.length() <= 4096 else {
    raise Invalid("too many Warp native headers")
  }
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => headers_in(root, path, paths)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          paths.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          raise Invalid("symlink/special native headers are not supported")
        }
    }
  }
}

///|
async fn write_nested(root : String, path : String, bytes : Bytes) -> Unit {
  let parts = path.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    raise Invalid("unsafe solver artifact path")
  }
  let mut folder = root
  for index in 0..<(parts.length() - 1) {
    folder += "/" + parts[index]
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + "/" + path, bytes, create_mode=CreateNew)
}

///|
async fn compile_module(
  build : Build,
  nvrtc_library : String,
  warp_native : String,
  mujoco_warp_root : String,
  cuda_include_dirs : Array[String],
  destination : String,
) -> Json {
  guard !destination.is_empty() && !@fs.exists(destination) else {
    raise Invalid("fresh solver module output directory required")
  }
  let native = @fs.realpath(warp_native)
  let nvrtc = @fs.realpath(nvrtc_library)
  let mjw = @fs.realpath(mujoco_warp_root) + "/mujoco_warp/_src/"
  let sources : Map[String, Bytes] = Map([])
  let evidence = []
  for
    (name, sha) in [
      (
        "smooth.py", "6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef",
      ),
      (
        "io.py", "2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0",
      ),
    ] {
    let bytes = @fs.read_file(mjw + name).binary()
    guard @artifacts.sha256(bytes) == sha else {
      raise Invalid(
        "pinned MuJoCo-Warp3.15 factorization source differs: " + name,
      )
    }
    sources[name] = bytes
    evidence.push({ "path": Json(name), "sha256": Json(sha) })
  }
  let paths = []
  headers_in(native, "", paths)
  let headers : Array[@compiler.Header] = []
  let snapshots : Map[String, Bytes] = Map([])
  let inventory = []
  let mut total = 0
  for path in paths {
    let bytes = @fs.read_file(native + "/" + path).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise Invalid("solver native header inventory exceeds128MiB")
    }
    total += bytes.length()
    snapshots[path] = bytes
    headers.push({ include_name: path, source: @utf8.decode(bytes), })
    inventory.push({
      "include_name": Json(path),
      "path": Json("headers/" + path),
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
      (
        "tile.h", "27cf1ea9f52814d51174b98df4904899e9ff32a3923ccf6635458c12d5893f4f",
      ),
      (
        "tile_cholesky.h", "2941d27c329535c63f9f8b0e23dc414bc4d1a70f33b8242291982be4fad224f5",
      ),
      (
        "tile_solve.h", "c0976c1b1072781ec7890ec7074fd964690f54ab8d84832f1f8b2c467112efbf",
      ),
    ] {
    guard snapshots.get(name) is Some(bytes) && @artifacts.sha256(bytes) == sha else {
      raise Invalid("pinned actual Warp1.17 header differs: " + name)
    }
  }
  guard snapshots.get("version.h") is Some(version) &&
    @utf8.decode(version).contains("#define WP_VERSION_STRING \"1.17.0\"") else {
    raise Invalid("genuineWarp1.17 version header required")
  }
  let options = [
    "--gpu-architecture=sm_" + build.architecture.to_string(),
    "--std=c++17",
    "--device-as-default-execution-space",
    "--fmad=false",
  ]
  guard cuda_include_dirs.length() <= 64 else {
    raise Invalid("too many explicit CUDA include paths")
  }
  for path in cuda_include_dirs {
    let resolved = @fs.realpath(path)
    guard @fs.kind(resolved) == Directory else {
      raise Invalid("existing CUDA include directory required")
    }
    options.push("--include-path=" + resolved)
  }
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let compiler = @compiler.Compiler::open(nvrtc)
  let compiled = compiler.compile({
    source: build.source,
    program_name: "moonrobo-mixed-sparse-solver.cu",
    headers,
    options,
    kind: @compiler.ImageKind::Cubin,
  })
  guard !compiled.image.is_empty() &&
    @artifacts.sha256(@fs.read_file(nvrtc).binary()) == compiler_sha else {
    raise Invalid("native compiler returned no actual CUBIN")
  }
  @fs.mkdir(destination, recursive=true)
  let output = @fs.realpath(destination)
  @fs.write_file(output + "/solver.cu", build.source, create_mode=CreateNew)
  @fs.write_file(
    output + "/module.cubin",
    compiled.image,
    create_mode=CreateNew,
  )
  @fs.write_file(output + "/compile.log", compiled.log, create_mode=CreateNew)
  for path, bytes in snapshots {
    write_nested(output, "headers/" + path, bytes)
  }
  for path, bytes in sources {
    write_nested(output, "upstream/" + path, bytes)
  }
  let metadata = []
  for item in build.metadata {
    let path = "metadata/" + item.name + ".i32.bin"
    write_nested(output, path, item.bytes)
    metadata.push({
      "name": Json(item.name),
      "dtype": Json(item.dtype),
      "shape": Json(item.shape),
      "path": Json(path),
      "sha256": Json(item.sha256),
    })
  }
  let manifest : Json = {
    "format": Json(build.format),
    "producer": "moonbit-native-complete-supported-mixed-sparse-lowering",
    "request": build.request,
    "source": { "path": "solver.cu", "sha256": Json(build.source_sha256) },
    "specialization_sha256": Json(build.specialization_sha256),
    "entries": Json(build.entries),
    "image": {
      "kind": "cubin",
      "path": "module.cubin",
      "sha256": Json(@artifacts.sha256(compiled.image)),
    },
    "launch_policy": Json(build.launch_policy),
    "warp_version": "1.17.0",
    "mujoco_warp_version": "3.15.0",
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_coord_mult": 1,
    "compiler": {
      "library_path": Json(nvrtc),
      "library_sha256": Json(compiler_sha),
      "version": Json(compiled.version),
      "options": Json(options),
      "transitive_native_dependencies_attested": false,
    },
    "headers": Json(inventory),
    "upstream_sources": Json(evidence),
    "metadata": Json(metadata),
    "details": build.details,
    "callables": callable_map(),
    "log": {
      "path": "compile.log",
      "sha256": Json(@artifacts.sha256(@utf8.encode(compiled.log))),
    },
    "all_supplied_warp_header_bytes_snapshotted": true,
    "all_headers_attested_against_upstream": false,
    "external_include_bytes_attested": false,
    "sticky_failure_parameter": "failure",
    "failure_initial_zero_required": true,
    "publication_requires_all_failure_zero": true,
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "mathdx_accelerated": false,
    "full_constraint_solver_generated": false,
    "full_physics_step_generated": false,
    "apic_capture_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.write_file(
    output + "/manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}

///|
pub async fn compile_artifact(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  compile_module(
    {
      format: "moonrobo-native-mixed-sparse-solver-module-v1",
      request: Json(config.request),
      source: lowered.source,
      source_sha256: lowered.source_sha256,
      specialization_sha256: lowered.specialization_sha256,
      entries: lowered.entries,
      launch_policy: lowered.launch_policy,
      metadata: lowered.metadata,
      architecture: config.request.architecture,
      details: {
        "nv": Json(lowered.nv),
        "nC": Json(lowered.nC),
        "factor_width": Json(lowered.factor_width),
        "sparse_levels": Json(lowered.sparse_levels),
        "body_static_shared_bytes": Json(lowered.body_static_shared_bytes),
        "mixed_factor_solve_source_closure_generated": true,
        "gather_backend": "genuine-Warp-cooperative-scalar-fallback",
      },
    },
    config.nvrtc_library,
    config.warp_native,
    config.mujoco_warp_root,
    config.cuda_include_dirs,
    config.output,
  )
}

///|
pub async fn compile_lu_artifact(config : LuCompileConfig) -> Json {
  let lowered = lower_lu(config.request)
  compile_module(
    {
      format: "moonrobo-native-sparse-lu-module-v1",
      request: Json(config.request),
      source: lowered.source,
      source_sha256: lowered.source_sha256,
      specialization_sha256: lowered.specialization_sha256,
      entries: lowered.entries,
      launch_policy: lowered.launch_policy,
      metadata: lowered.metadata,
      architecture: config.request.architecture,
      details: {
        "nv": Json(lowered.nv),
        "nD": Json(lowered.nD),
        "no_pivot": true,
        "reverse_elimination_profile_closed": true,
        "solution_is_row_count_scratch": true,
      },
    },
    config.nvrtc_library,
    config.warp_native,
    config.mujoco_warp_root,
    config.cuda_include_dirs,
    config.output,
  )
}
