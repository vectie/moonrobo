///|
fn primary_pins() -> Array[(String, String)] {
  [
    (
      "native/warp.h", "8dba30fadc4315eb7d08795888b822c2d7e30b4a0057861c5d41431310cf8c8b",
    ),
    (
      "native/warp.cu", "f8b9f4cef163b2c24fd45e8ded06d608c99d0392b8f89b45bef2931fa143c709",
    ),
    (
      "native/mathdx.cpp", "a8737e3144a800c88a6ac40d95d4422b134561524efdcaa8670cd1d8abc4e3a5",
    ),
    (
      "native/builtin.h", "9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf",
    ),
    (
      "native/array.h", "f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a",
    ),
    (
      "native/tile_cholesky.h", "2941d27c329535c63f9f8b0e23dc414bc4d1a70f33b8242291982be4fad224f5",
    ),
    (
      "native/tile_solve.h", "c0976c1b1072781ec7890ec7074fd964690f54ab8d84832f1f8b2c467112efbf",
    ),
    (
      "_src/build.py", "63d84f6814789a95366c9ef155fa2b35b566e53a5dae84ce316d650e16cd5513",
    ),
    (
      "_src/builtins.py", "24f5d991a21d480d43e26db91753528a4c2d9441dd9be9eb1aec380ea4ca6be6",
    ),
  ]
}

///|
fn object(
  value : Json,
  keys : Array[String],
) -> Map[String, Json] raise TileError {
  guard value is Object(fields) &&
    fields.length() == keys.length() &&
    fields.keys().all(key => keys.contains(key)) else {
    raise Invalid("tile compiler record contains missing or unknown fields")
  }
  fields
}

///|
pub fn decode_config(value : Json) -> CompileConfig raise {
  let fields = object(value, [
    "request", "warp_library", "warp_native", "cuda_include_dirs", "output",
  ])
  ignore(
    object(fields["request"], [
      "operation", "dtype", "tile_size", "rhs_columns", "batch_size", "block_dim",
      "architecture",
    ]),
  )
  let config : CompileConfig = @json.from_json(value)
  ignore(validate(config.request))
  config
}

///|
async fn collect_headers(
  root : String,
  relative : String,
  output : Array[String],
) -> Unit {
  guard output.length() <= 4096 else {
    raise Invalid("too many Warp native headers")
  }
  let directory = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(directory, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => collect_headers(root, path, output)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          output.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          raise Invalid("symlink/special Warp headers are unsupported")
        }
    }
  }
}

///|
async fn write_nested(root : String, path : String, bytes : Bytes) -> Unit {
  let parts = path.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    raise Invalid("unsafe artifact snapshot path")
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
/// Explicit native compilation, never invoked by lower/decode/check. Generates
/// real cuSolverDx LTOIR+FATBIN, then calls Warp's NVRTC+NVJitLink C entry point.
/// This does not initialize a CUDA context, load a module or execute a kernel.
pub async fn compile_artifact(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    raise Invalid("fresh tile compilation output directory required")
  }
  let native = @fs.realpath(config.warp_native)
  let root = @fs.realpath(native + "/..")
  guard @fs.realpath(root + "/native") == native else {
    raise Invalid(
      "warp_native must be the actual pinned source-tree native directory",
    )
  }
  let library = @fs.realpath(config.warp_library)
  let library_sha = @artifacts.sha256(@fs.read_file(library).binary())
  let include_paths = []
  guard config.cuda_include_dirs.length() <= 64 else {
    raise Invalid("too many explicit CUDA include directories")
  }
  for path in config.cuda_include_dirs {
    let resolved = @fs.realpath(path)
    guard @fs.kind(resolved) == Directory else {
      raise Invalid("CUDA include path must be an existing directory")
    }
    include_paths.push(resolved)
  }
  let snapshots : Map[String, Bytes] = Map([])
  let evidence = []
  for (path, expected) in primary_pins() {
    let bytes = @fs.read_file(root + "/" + path).binary()
    guard @artifacts.sha256(bytes) == expected else {
      raise Invalid("pinned Warp 1.17 primary source differs: " + path)
    }
    snapshots["upstream/" + path] = bytes
    evidence.push({ "path": Json(path), "sha256": Json(expected) })
  }
  let names = []
  collect_headers(native, "", names)
  let inventory = []
  let mut total = 0
  for path in names {
    let bytes = @fs.read_file(native + "/" + path).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise Invalid("Warp header inventory exceeds 128 MiB")
    }
    total += bytes.length()
    snapshots["headers/" + path] = bytes
    inventory.push({
      "include_name": Json(path),
      "stored_path": Json("headers/" + path),
      "sha256": Json(@artifacts.sha256(bytes)),
    })
  }
  // Only source/metadata reads have happened above. Directory creation and
  // explicit compilation begin here; failures leave no success manifest.
  @fs.mkdir(config.output, recursive=true)
  let output = @fs.realpath(config.output)
  @fs.write_file(output + "/kernels.cu", lowered.source, create_mode=CreateNew)
  for path, bytes in snapshots {
    write_nested(output, path, bytes)
  }
  let backend = open_raw(text(library))
  defer close_raw(backend)
  checked(backend, 1)
  let mathdx_version = @utf8.decode_lossy(mathdx_version_raw(backend))
  let ltoirs = []
  let functions = []
  let mut fatbin : Bytes? = None
  let symbols = [(lowered.potrf_symbol, false)]
  if lowered.potrs_symbol is Some(symbol) {
    symbols.push((symbol, true))
  }
  for (symbol, solve) in symbols {
    let name = if solve { "potrs" } else { "potrf" }
    let lto_path = name + ".ltoir"
    let fatbin_path = name + ".fatbin"
    checked(
      backend,
      solver_raw(
        backend,
        text(output + "/" + fatbin_path),
        text(output + "/" + lto_path),
        text(symbol),
        config.request.architecture,
        config.request.tile_size,
        if solve {
          config.request.rhs_columns
        } else {
          1
        },
        if solve {
          1
        } else {
          0
        },
        if config.request.dtype == "float32" {
          5
        } else {
          6
        },
        config.request.block_dim,
      ),
    )
    let lto = @fs.read_file(output + "/" + lto_path).binary()
    let universal = @fs.read_file(output + "/" + fatbin_path).binary()
    guard !lto.is_empty() &&
      !universal.is_empty() &&
      lto.length() <= 268435456 &&
      universal.length() <= 268435456 else {
      raise Invalid("MathDx produced empty/oversized link data")
    }
    match fatbin {
      Some(previous) => {
        guard previous == universal else {
          raise Invalid(
            "cuSolverDx universal FATBIN differs across POTRF/POTRS",
          )
        }
      }
      None => fatbin = Some(universal)
    }
    ltoirs.push(lto)
    functions.push({
      "function": Json(name),
      "symbol": Json(symbol),
      "function_enum": Json(if solve { 3 } else { 2 }),
      "ltoir_path": Json(lto_path),
      "ltoir_sha256": Json(@artifacts.sha256(lto)),
      "fatbin_path": Json(fatbin_path),
      "fatbin_sha256": Json(@artifacts.sha256(universal)),
      "M": Json(config.request.tile_size),
      "N": Json(config.request.tile_size),
      "K": Json(if solve { config.request.rhs_columns } else { 1 }),
      "precision": Json(if config.request.dtype == "float32" { 5 } else { 6 }),
      "arrangement_A": 1,
      "arrangement_B": 1,
      "fill_mode": 0,
      "side": -1,
      "diag": -1,
    })
  }
  guard fatbin is Some(universal) else {
    raise Invalid("missing actual universal FATBIN")
  }
  let includes = include_paths.map(text)
  checked(
    backend,
    program_raw(
      backend,
      text(lowered.source),
      text(output + "/headers"),
      FixedArray::makei(includes.length(), i => includes[i]),
      text(output + "/module.cubin"),
      config.request.architecture,
      FixedArray::makei(ltoirs.length(), i => ltoirs[i]),
      universal,
    ),
  )
  let image = @fs.read_file(output + "/module.cubin").binary()
  guard !image.is_empty() && image.length() <= 268435456 else {
    raise Invalid("empty/oversized linked CUBIN")
  }
  let manifest : Json = {
    "format": "moonrobo-mathdx-tile-module-v1",
    "producer": "moonbit-warp-mathdx-c-abi",
    "request": Json(config.request),
    "source_path": "kernels.cu",
    "source_sha256": Json(lowered.source_sha256),
    "specialization_sha256": Json(lowered.specialization_sha256),
    "entries": Json(lowered.entries),
    "image": {
      "kind": "cubin",
      "path": "module.cubin",
      "sha256": Json(@artifacts.sha256(image)),
    },
    "warp_version": "1.17.0",
    "mathdx_version": Json(mathdx_version),
    "upstream_sources": Json(evidence),
    "headers": Json(inventory),
    "all_supplied_warp_header_bytes_snapshotted": true,
    "all_headers_attested_against_upstream": false,
    "external_include_bytes_attested": false,
    "compiler": {
      "library_path": Json(library),
      "library_sha256": Json(library_sha),
      "api": "wp_cuda_compile_solver+wp_cuda_compile_program",
      "cuda_include_dirs": Json(include_paths),
      "warp_include_dir": "headers",
      "optimization_level": 3,
      "debug": false,
      "fast_math": false,
      "fuse_fp": false,
      "precompiled_headers": false,
      "stderr_diagnostics_captured": false,
      "transitive_native_dependencies_attested": false,
    },
    "mathdx_functions": Json(functions),
    "universal_fatbin_linked_once": true,
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "launch_coord_mult": 1,
    "launch_policy": Json(lowered.launch_policy),
    "body_static_shared_bytes": Json(lowered.static_shared_bytes),
    "mathdx_internal_shared_memory_budget_verified": false,
    "publication_requires_status_zero": true,
    "required_status_parameter": "status",
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "physics_solver_closure_generated": false,
    "mixed_sparse_gather_closure_generated": false,
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
