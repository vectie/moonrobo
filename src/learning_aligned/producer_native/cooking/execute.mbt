///|
async fn explicit_file(path : String) -> String {
  guard !path.is_empty() && !path.contains("\u{0}") else {
    fail("explicit NUL-free native file path required")
  }
  let resolved = @fs.realpath(path)
  guard @fs.kind(resolved) is Regular else {
    fail("native cooking input must be a regular file")
  }
  resolved
}

///|
/// Explicit future execution: creates and closes an actual CPU Warp Mesh/BVH,
/// records its resource receipt, and writes host geometry bytes. A serialized
/// resource ID cannot be reused. This is never called during check/info/fmt.
pub async fn execute_cook(config : ExecuteRequest) -> Json {
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    fail("fresh nonexistent cooking output directory required")
  }
  let prepared = prepare_mesh(config.request)
  let adapter = explicit_file(config.adapter)
  let library = explicit_file(config.warp_library)
  let adapter_sha = @artifacts.sha256(@fs.read_file(adapter).binary())
  let library_sha = @artifacts.sha256(@fs.read_file(library).binary())
  let mesh = open_host_mesh(adapter, library, prepared)
  defer mesh.close()
  let receipt = mesh.metadata()
  mesh.close()
  guard @artifacts.sha256(@fs.read_file(adapter).binary()) == adapter_sha &&
    @artifacts.sha256(@fs.read_file(library).binary()) == library_sha else {
    fail("native cooking adapter/runtime changed during construction")
  }
  write_mesh_artifact(prepared, config.request, config.output, {
    "native_execution_performed": true,
    "adapter": Json(adapter),
    "adapter_sha256": Json(adapter_sha),
    "warp_library": Json(library),
    "warp_library_sha256": Json(library_sha),
    "receipt": receipt,
    "resource_closed_before_return": true,
    "resource_live_after_command": false,
    "wp_init_called": false,
    "cuda_initialized_by_adapter": false,
    "python_used": false,
    "runtime_dependency_hash_scope": "adapter and root Warp library only; transitive native dependencies are not hashed",
  })
}
