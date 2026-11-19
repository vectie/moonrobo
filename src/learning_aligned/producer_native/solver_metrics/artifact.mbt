///|
fn record(value : Json, keys : Array[String]) -> Map[String, Json] raise {
  guard value is Object(fields) &&
    fields.length() == keys.length() &&
    fields.keys().all(k => keys.contains(k)) else {
    fail("metric record has missing or unknown fields")
  }
  fields
}

///|
pub fn decode_config(value : Json) -> CompileConfig raise {
  let fields = record(value, [
    "request", "nvrtc_library", "warp_native", "mujoco_warp_root", "cuda_include_dirs",
    "output",
  ])
  ignore(
    record(fields["request"], [
      "nworld", "nv", "nC", "nK", "nblock", "nefm0", "nefm0L", "ntendon", "tendon_nnz",
      "nactuator", "moment_nnz", "njmax", "jacobian_nnz", "ncon", "contact_width",
      "ntree", "sparse_jacobian", "sleep", "check_skip", "architecture", "kernels",
    ]),
  )
  let config : CompileConfig = @json.from_json(value)
  ignore(lower(config.request))
  config
}

///|
async fn collect_headers(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  guard paths.length() <= 4096 else { fail("too many Warp native headers") }
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => collect_headers(root, path, paths)
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
          fail("special or symlink native header rejected")
        }
    }
  }
}

///|
async fn write_snapshot(root : String, path : String, bytes : Bytes) -> Unit {
  let parts = path.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    fail("unsafe metric artifact path")
  }
  let mut folder = root
  for i in 0..<(parts.length() - 1) {
    folder += "/" + parts[i]
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + "/" + path, bytes, create_mode=CreateNew)
}

///|
/// Explicit opt-in real NVRTC C ABI compilation; never invoked by lower/check.
pub async fn compile_artifact(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    fail("fresh metric module output required")
  }
  let native = @fs.realpath(config.warp_native)
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let mjw = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let sources : Map[String, Bytes] = Map([])
  let evidence = []
  for
    (name, sha) in [
      (
        "derivative.py", "d2fb5a758e8774ea49546a0d7936534be48cc1f714629239aef71413be670a4a",
      ),
      (
        "smooth.py", "6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef",
      ),
      (
        "io.py", "2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0",
      ),
      (
        "solver.py", "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916",
      ),
    ] {
    let bytes = @fs.read_file(mjw + name).binary()
    guard @artifacts.sha256(bytes) == sha else {
      fail("pinned MuJoCo-Warp3.15 source differs: " + name)
    }
    sources[name] = bytes
    evidence.push({ "path": Json(name), "sha256": Json(sha) })
  }
  let paths = []
  collect_headers(native, "", paths)
  let snapshots : Map[String, Bytes] = Map([])
  let headers : Array[@compiler.Header] = []
  let inventory = []
  let mut total = 0
  for path in paths {
    let bytes = @fs.read_file(native + "/" + path).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      fail("metric header inventory exceeds128MiB")
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
    ] {
    guard snapshots.get(name) is Some(bytes) && @artifacts.sha256(bytes) == sha else {
      fail("pinned Warp1.17 ABI header differs: " + name)
    }
  }
  guard snapshots.get("version.h") is Some(version) &&
    @utf8.decode(version).contains("#define WP_VERSION_STRING \"1.17.0\"") else {
    fail("actual Warp1.17 version required")
  }
  let options = [
    "--gpu-architecture=sm_" + config.request.architecture.to_string(),
    "--std=c++17",
    "--device-as-default-execution-space",
    "--fmad=false",
  ]
  guard config.cuda_include_dirs.length() <= 64 else {
    fail("too many CUDA includes")
  }
  for path in config.cuda_include_dirs {
    let resolved = @fs.realpath(path)
    guard @fs.kind(resolved) == Directory else {
      fail("actual CUDA include directory required")
    }
    options.push("--include-path=" + resolved)
  }
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let backend = @compiler.Compiler::open(nvrtc)
  let compiled = backend.compile({
    source: lowered.source,
    program_name: "moonrobo-effective-metrics.cu",
    headers,
    options,
    kind: @compiler.ImageKind::Cubin,
  })
  guard !compiled.image.is_empty() &&
    @artifacts.sha256(@fs.read_file(nvrtc).binary()) == compiler_sha else {
    fail("empty CUBIN or NVRTC library changed")
  }
  @fs.mkdir(config.output, recursive=true)
  let output = @fs.realpath(config.output)
  @fs.write_file(output + "/metrics.cu", lowered.source, create_mode=CreateNew)
  @fs.write_file(
    output + "/module.cubin",
    compiled.image,
    create_mode=CreateNew,
  )
  @fs.write_file(output + "/compile.log", compiled.log, create_mode=CreateNew)
  for path, bytes in snapshots {
    write_snapshot(output, "headers/" + path, bytes)
  }
  for path, bytes in sources {
    write_snapshot(output, "upstream/" + path, bytes)
  }
  let manifest : Json = {
    "format": "moonrobo-native-solver-metrics-module-v1",
    "request": Json(config.request),
    "source": { "path": "metrics.cu", "sha256": Json(lowered.source_sha256) },
    "specialization_sha256": Json(lowered.specialization_sha256),
    "entries": Json(lowered.entries),
    "launch_policy": Json(lowered.launch_policy),
    "image": {
      "kind": "cubin",
      "path": "module.cubin",
      "sha256": Json(@artifacts.sha256(compiled.image)),
    },
    "compiler": {
      "library_path": Json(nvrtc),
      "library_sha256": Json(compiler_sha),
      "version": Json(compiled.version),
      "options": Json(options),
      "transitive_native_dependencies_attested": false,
    },
    "warp_version": "1.17.0",
    "mujoco_warp_version": "3.15.0",
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_coord_mult": 1,
    "headers": Json(inventory),
    "upstream_sources": Json(evidence),
    "immutable_parameters": Json(immutable_parameters()),
    "sticky_failure_parameter": "failure",
    "failure_initial_zero_required": true,
    "publication_requires_all_failure_zero": true,
    "serial_per_world_reduction": true,
    "three_by_three_pivot_floor_matches_source": true,
    "effective_metric_coefficient_construction_generated": false,
    "full_eff_mul_m_generated": false,
    "full_physics_step_generated": false,
    "runtime_equivalence_verified": false,
    "generated_adjoint": false,
    "all_supplied_warp_header_bytes_snapshotted": true,
    "all_headers_attested_against_upstream": false,
    "external_include_bytes_attested": false,
    "log": {
      "path": "compile.log",
      "sha256": Json(@artifacts.sha256(@utf8.encode(compiled.log))),
    },
  }
  @fs.write_file(
    output + "/manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
