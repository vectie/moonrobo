///|
pub(all) struct HeaderFile {
  include_name : String
  path : String
} derive(Debug, FromJson, ToJson)

///|
/// All paths are explicit. options are passed verbatim to NVRTC without a shell.
/// kind is exactly "ptx" or "cubin"; no architecture is silently substituted.
pub(all) struct ArtifactRequest {
  nvrtc_library : String
  source_path : String
  program_name : String
  headers : Array[HeaderFile]
  options : Array[String]
  kind : String
  output : String
} derive(Debug, FromJson, ToJson)

///|
/// Compiles a source-only module into a fresh artifact folder. This is not a
/// complete Warp/APIC capture producer and does not synthesize kernel metadata.
pub async fn compile_artifact(request : ArtifactRequest) -> Json {
  let kind = match request.kind {
    "ptx" => ImageKind::Ptx
    "cubin" => ImageKind::Cubin
    _ => raise CompileError::Invalid("kind must be ptx or cubin")
  }
  guard !request.output.is_empty() && !@fs.exists(request.output) else {
    raise CompileError::Invalid(
      "a fresh, nonexistent output directory is required",
    )
  }
  let source_path = @fs.realpath(request.source_path)
  let compiler_path = @fs.realpath(request.nvrtc_library)
  let source = @fs.read_file(source_path).binary()
  let compiler_sha = @artifacts.sha256(@fs.read_file(compiler_path).binary())
  let headers : Array[Header] = []
  let header_bytes : Array[Bytes] = []
  let header_inventory : Array[Json] = []
  for index, header in request.headers {
    let path = @fs.realpath(header.path)
    let bytes = @fs.read_file(path).binary()
    headers.push({
      include_name: header.include_name,
      source: @utf8.decode(bytes),
    })
    header_bytes.push(bytes)
    header_inventory.push({
      "include_name": header.include_name.to_json(),
      "source_path": path.to_json(),
      "stored_path": "header-\{index}.h".to_json(),
      "sha256": @artifacts.sha256(bytes).to_json(),
    })
  }
  let compiler = Compiler::open(compiler_path)
  let result = compiler.compile({
    source: @utf8.decode(source),
    program_name: request.program_name,
    headers,
    options: request.options,
    kind,
  })
  let image_path = "module." + request.kind
  let manifest : Json = {
    "schema": "moonrobo-nvrtc-module-v1",
    "producer": "moonbit-native-nvrtc",
    "scope": "pregenerated-cuda-source-to-module",
    "python_runtime_required": false,
    "cuda_context_created": false,
    "apic_capture_complete": false,
    "kernel_metadata_generated": false,
    "source": {
      "source_path": source_path.to_json(),
      "program_name": request.program_name.to_json(),
      "stored_path": "source.cu",
      "sha256": @artifacts.sha256(source).to_json(),
    },
    "headers": header_inventory.to_json(),
    "compiler": {
      "library_path": compiler_path.to_json(),
      "library_sha256": compiler_sha.to_json(),
      "version": result.version.to_json(),
      "options": request.options.to_json(),
      "transitive_dependency_hashes_recorded": false,
      "external_include_bytes_recorded": false,
    },
    "image": {
      "kind": request.kind.to_json(),
      "stored_path": image_path.to_json(),
      "sha256": @artifacts.sha256(result.image).to_json(),
      "byte_length": result.image.length().to_json(),
    },
    "log_path": "compile.log",
    "log_sha256": @artifacts.sha256(@utf8.encode(result.log)).to_json(),
  }
  // Create only after successful compilation. CreateNew prevents overwriting
  // concurrently created files. A failed write deliberately leaves partial
  // evidence and cannot be mistaken for a complete manifest.
  @fs.mkdir(request.output, recursive=true)
  let folder = request.output + "/"
  @fs.write_file(folder + "source.cu", source, create_mode=CreateNew)
  for index, bytes in header_bytes {
    @fs.write_file(folder + "header-\{index}.h", bytes, create_mode=CreateNew)
  }
  @fs.write_file(folder + image_path, result.image, create_mode=CreateNew)
  @fs.write_file(folder + "compile.log", result.log, create_mode=CreateNew)
  @fs.write_file(
    folder + "manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
