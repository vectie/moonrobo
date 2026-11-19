///|
async fn header_paths(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => header_paths(root, path, paths)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          guard paths.length() < 4096 else {
            fail("too many Warp native headers")
          }
          paths.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          fail("header symlink/special file rejected")
        }
    }
  }
}

///|
async fn write_nested(root : String, path : String, bytes : Bytes) -> Unit {
  let parts = path.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    fail("unsafe source snapshot path")
  }
  let mut folder = root
  @fs.mkdir(folder, recursive=true)
  for i in 0..<(parts.length() - 1) {
    folder += parts[i] + "/"
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + path, bytes, create_mode=CreateNew)
}

///|
/// Explicit offline compilation API. This function is never invoked by
/// check/info/fmt or by the pipeline loader. It opens the real C NVRTC compiler.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    fail("fresh device convergence output required")
  }
  let kind = match config.kind {
    "ptx" => @compiler.Ptx
    "cubin" => @compiler.Cubin
    _ => fail("PTX or CUBIN required")
  }
  let arch = config.options.filter(o => {
    o.has_prefix("--gpu-architecture=") || o.has_prefix("-arch=")
  })
  guard arch.length() == 1 &&
    (
      (config.kind == "ptx" && arch[0].contains("=compute_")) ||
      (config.kind == "cubin" && arch[0].contains("=sm_"))
    ) else {
    fail("one explicit matching architecture required")
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
  let root = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let solver = @fs.read_file(root + "solver.py").binary()
  let types = @fs.read_file(root + "types.py").binary()
  guard @artifacts.sha256(solver) == source_sha256() &&
    @artifacts.sha256(types) ==
    "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b" else {
    fail("pinned MuJoCo-Warp 3.15 solver/constant source differs")
  }
  let native = @fs.realpath(config.warp_native)
  let paths : Array[String] = []
  header_paths(native, "", paths)
  let headers : Array[@compiler.Header] = []
  let header_bytes : Map[String, Bytes] = {}
  let inventory : Array[Json] = []
  let mut total = 0
  for path in paths {
    let bytes = @fs.read_file(native + "/" + path).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      fail("Warp header inventory capacity exceeded")
    }
    total += bytes.length()
    header_bytes[path] = bytes
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
    guard header_bytes.get(name) is Some(bytes) &&
      @artifacts.sha256(bytes) == sha else {
      fail("pinned Warp 1.17 ABI header differs")
    }
  }
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let compiler = @compiler.Compiler::open(nvrtc)
  let compiled = compiler.compile({
    source: lowered.source,
    program_name: "moonrobo-device-convergence.cu",
    headers,
    options,
    kind,
  })
  let manifest : Json = {
    "format": "moonrobo-device-convergence-module-v1",
    "producer": "moonbit-typed-mujoco-warp-convergence",
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
    "request": config.request.to_json(),
    "source": {
      "path": "convergence.cu",
      "sha256": Json(lowered.source_sha256),
    },
    "specialization_sha256": Json(lowered.specialization_sha256),
    "entries": lowered.entries.to_json(),
    "upstream_files": [
      {
        "file": "solver.py",
        "sha256": Json(source_sha256()),
        "path": "upstream/solver.py.source",
      },
      {
        "file": "types.py",
        "sha256": Json(@artifacts.sha256(types)),
        "path": "upstream/types.py.source",
      },
    ],
    "upstream_symbols": [
      "_rescale", "_solve_done", "_solve_beta_finalize_tiled", "_solve_search_update_cg_tiled",
      "_solve", "OverflowType.ITERATIONS",
    ],
    "headers": Json(inventory),
    "abi_headers_attested": ["array.h", "builtin.h"],
    "external_include_bytes_attested": false,
    "compiler": {
      "path": Json(nvrtc),
      "sha256": Json(compiler_sha),
      "version": compiled.version.to_json(),
      "options": Json(options),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "path": Json("module." + config.kind),
      "kind": Json(config.kind),
      "sha256": Json(@artifacts.sha256(compiled.image)),
    },
    "log": {
      "path": "compile.log",
      "sha256": Json(@artifacts.sha256(@utf8.encode(compiled.log))),
    },
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_coord_mult": 1,
    "launch_policy": {
      "block_dim": 256,
      "forward_smem": 0,
      "backward_smem": 0,
      "grid_stride": true,
      "coord_mult": 1,
    },
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "cg_reduction": "fp32-serial-nv-one-thread-per-world",
    "upstream_tiled_reduction_order_preserved": false,
    "done_input_output_alias": "one-explicit-inout-parameter",
    "iteration_overflow_bit": 512,
    "full_solver_closure": false,
    "complete_timestep_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(
    folder + "convergence.cu",
    lowered.source,
    create_mode=CreateNew,
  )
  @fs.write_file(
    folder + "module." + config.kind,
    compiled.image,
    create_mode=CreateNew,
  )
  @fs.write_file(folder + "compile.log", compiled.log, create_mode=CreateNew)
  for path in paths {
    write_nested(folder + "headers/", path, header_bytes[path])
  }
  write_nested(folder + "upstream/", "solver.py.source", solver)
  write_nested(folder + "upstream/", "types.py.source", types)
  @fs.write_file(
    folder + "manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
