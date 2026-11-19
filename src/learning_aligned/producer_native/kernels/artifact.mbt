///|
/// Hash the exact decorated top-level definition from a previously SHA-verified
/// source file. This is passive text inspection, never Python parsing/execution.
fn definition(source : String, name : String) -> String raise {
  let lines = source.split("\n").map(s => s.to_owned()).collect()
  let mut found = -1
  for index, line in lines {
    if line.has_prefix("def " + name + "(") {
      guard found == -1 else {
        raise LowerError::Invalid("duplicate pinned kernel definition")
      }
      found = index
    }
  }
  guard found >= 0 else {
    raise LowerError::Invalid("pinned kernel definition missing: " + name)
  }
  let start = if found > 0 && lines[found - 1].has_prefix("@wp.kernel") {
    found - 1
  } else {
    found
  }
  let mut end = lines.length()
  let mut signature_done = lines[found].trim().has_suffix(":")
  for index in (found + 1)..<lines.length() {
    let line = lines[index]
    if !signature_done {
      if line.trim().has_suffix(":") {
        signature_done = true
      }
      continue
    }
    if line.trim().is_empty() {
      continue
    }
    if !line.has_prefix(" ") && !line.has_prefix("\t") {
      end = index
      break
    }
  }
  guard signature_done else {
    raise LowerError::Invalid("unterminated pinned kernel signature")
  }
  while end > start && lines[end - 1].trim().is_empty() {
    end -= 1
  }
  lines[start:end].to_array().join("\n") + "\n"
}

///|
async fn headers_in(
  root : String,
  relative : String,
  result : Array[String],
) -> Unit {
  guard result.length() < 4096 else {
    raise LowerError::Invalid("too many native header files")
  }
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => headers_in(root, path, result)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          result.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          raise LowerError::Invalid(
            "header symlinks/special files are not accepted",
          )
        }
    }
  }
}

///|
/// Compile only the selected concrete hooks. The receipt includes real source,
/// pinned upstream definitions, all supplied native headers, native compiler,
/// options, typed entry metadata and compiled-image identities.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.specialization)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    raise LowerError::Invalid("fresh output directory required")
  }
  let image_kind = match config.kind {
    "ptx" => @compiler.ImageKind::Ptx
    "cubin" => @compiler.ImageKind::Cubin
    _ => raise LowerError::Invalid("kind must be ptx or cubin")
  }
  let isaaclab = @fs.realpath(config.isaaclab_root)
  let native = @fs.realpath(config.warp_native)
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let source_files : Map[String, Bytes] = {}
  let functions : Array[Json] = []
  for e in lowered.entries {
    if !source_files.contains(e.upstream_file) {
      let bytes = @fs.read_file(isaaclab + "/" + e.upstream_file).binary()
      guard @artifacts.sha256(bytes) == e.upstream_file_sha256 else {
        raise LowerError::Invalid(
          "pinned IsaacLab kernel source differs: " + e.upstream_file,
        )
      }
      source_files[e.upstream_file] = bytes
    }
    let bytes = source_files[e.upstream_file]
    let body = definition(@utf8.decode(bytes), e.upstream_function)
    functions.push({
      "key": e.key.to_json(),
      "upstream_file": e.upstream_file.to_json(),
      "upstream_function": e.upstream_function.to_json(),
      "upstream_file_sha256": e.upstream_file_sha256.to_json(),
      "decorated_definition_sha256": @artifacts.sha256(@utf8.encode(body)).to_json(),
    })
  }
  let header_paths : Array[String] = []
  headers_in(native, "", header_paths)
  let headers : Array[@compiler.Header] = []
  let header_bytes : Map[String, Bytes] = {}
  let header_inventory : Array[Json] = []
  let mut total = 0
  for name in header_paths {
    let bytes = @fs.read_file(native + "/" + name).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise LowerError::Invalid("native header inventory exceeds 128 MiB limit")
    }
    total += bytes.length()
    headers.push({ include_name: name, source: @utf8.decode(bytes), })
    header_bytes[name] = bytes
    header_inventory.push({
      "include_name": name.to_json(),
      "stored_path": ("headers/" + name).to_json(),
      "sha256": @artifacts.sha256(bytes).to_json(),
    })
  }
  for
    (name, expected) in [
      (
        "builtin.h", "9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf",
      ),
      (
        "array.h", "f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a",
      ),
    ] {
    guard header_bytes.get(name) is Some(bytes) &&
      @artifacts.sha256(bytes) == expected else {
      raise LowerError::Invalid(
        "genuine pinned Warp 1.17 ABI header differs: " + name,
      )
    }
  }
  guard header_bytes.get("version.h") is Some(version) &&
    @utf8.decode(version).contains("#define WP_VERSION_STRING \"1.17.0\"") else {
    raise LowerError::Invalid("Warp 1.17 native header version required")
  }
  let options = effective_options(config.options, config.kind)
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let compiler = @compiler.Compiler::open(nvrtc)
  let compiled = compiler.compile({
    source: lowered.source,
    program_name: "moonrobo-g1-kernels.cu",
    headers,
    options,
    kind: image_kind,
  })
  let image_path = "module." + config.kind
  let manifest : Json = {
    "format": "moonrobo-g1-concrete-kernel-module-v1",
    "producer": "moonbit-typed-g1-lowerer",
    "request": config.specialization.to_json(),
    "specialization_sha256": lowered.specialization_sha256.to_json(),
    "source_path": "kernels.cu",
    "source_sha256": lowered.source_sha256.to_json(),
    "entries": lowered.entries.to_json(),
    "upstream_definitions": functions.to_json(),
    "isaaclab_revision": isaaclab_revision().to_json(),
    "warp_version": "1.17.0",
    "headers": header_inventory.to_json(),
    "all_supplied_warp_header_bytes_snapshotted": true,
    "external_include_bytes_attested": false,
    "all_headers_attested_against_upstream": false,
    "abi_headers_attested_against_upstream": ["builtin.h", "array.h"],
    "compiler": {
      "library_path": nvrtc.to_json(),
      "library_sha256": compiler_sha.to_json(),
      "version": compiled.version.to_json(),
      "options": options.to_json(),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "kind": config.kind.to_json(),
      "path": image_path.to_json(),
      "sha256": @artifacts.sha256(compiled.image).to_json(),
    },
    "log_path": "compile.log",
    "log_sha256": @artifacts.sha256(@utf8.encode(compiled.log)).to_json(),
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
    "physics_solver_closure_generated": false,
    "apic_capture_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(folder + "kernels.cu", lowered.source, create_mode=CreateNew)
  @fs.write_file(folder + image_path, compiled.image, create_mode=CreateNew)
  @fs.write_file(folder + "compile.log", compiled.log, create_mode=CreateNew)
  for name in header_paths {
    write_nested(folder + "headers/", name, header_bytes[name])
  }
  for path, bytes in source_files {
    write_nested(folder + "upstream/", path + ".source", bytes)
  }
  @fs.write_file(folder + "NOTICE", notice(), create_mode=CreateNew)
  @fs.write_file(
    folder + "manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}

///|
async fn write_nested(root : String, relative : String, bytes : Bytes) -> Unit {
  let parts = relative.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    raise LowerError::Invalid("invalid snapshot relative path")
  }
  let mut folder = root
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  for index in 0..<(parts.length() - 1) {
    folder += parts[index] + "/"
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + relative, bytes, create_mode=CreateNew)
}

///|
fn effective_options(
  requested : Array[String],
  kind : String,
) -> Array[String] raise {
  let architecture = requested.filter(o => {
    o.has_prefix("--gpu-architecture=") || o.has_prefix("-arch=")
  })
  guard architecture.length() == 1 else {
    raise LowerError::Invalid(
      "one explicit --gpu-architecture= or -arch= option required",
    )
  }
  let real = architecture[0].contains("=sm_")
  guard (kind == "ptx" && architecture[0].contains("=compute_")) ||
    (kind == "cubin" && real) else {
    raise LowerError::Invalid(
      "PTX requires compute_ and CUBIN requires sm_ architecture",
    )
  }
  // Fixed module types require C++17. Options affecting numerical behavior are
  // explicit and retained; no optimization/fast-math equivalence is claimed.
  guard !requested.any(o => {
    (o.has_prefix("--std=") || o.has_prefix("-std=")) &&
    o != "--std=c++17" &&
    o != "-std=c++17"
  }) else {
    raise LowerError::Invalid("concrete module requires C++17")
  }
  let options = requested.copy()
  if !options.contains("--std=c++17") && !options.contains("-std=c++17") {
    options.push("--std=c++17")
  }
  if !options.contains("--device-as-default-execution-space") {
    options.push("--device-as-default-execution-space")
  }
  options
}
