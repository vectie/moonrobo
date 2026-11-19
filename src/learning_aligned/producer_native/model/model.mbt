///|
/// Metadata and complete version-specific MuJoCo binary. This is not a Newton
/// model, does not allocate mjData, and does not establish solver equivalence.
pub struct CompiledModel {
  descriptor : Json
  mjb : Bytes
  receipt : Json
}

///|
/// Explicit offline model compilation through a native C ABI. The source MJCF
/// root, adapter and runtime library are hashed before/after compilation. Asset
/// closure provenance remains a separate responsibility of the caller.
pub async fn prepare_model(
  model_adapter : String,
  mujoco_library : String,
  source_mjcf : String,
) -> CompiledModel {
  let adapter = explicit_file(model_adapter)
  let library = explicit_file(mujoco_library)
  let source = explicit_file(source_mjcf)
  let adapter_sha = file_sha(adapter)
  let library_sha = file_sha(library)
  let source_sha = file_sha(source)
  let handle = open_model(
    @utf8.encode(adapter),
    @utf8.encode(library),
    @utf8.encode(source),
  )
  defer preparation_close(handle)
  let descriptor = handle.json("moonrobo.aligned-compiled-mujoco-model.v1")
  let mjb = preparation_mjb(handle)
  handle.check()
  guard mjb.length() > 0 else { fail("native preparation returned empty MJB") }
  guard file_sha(adapter) == adapter_sha &&
    file_sha(library) == library_sha &&
    file_sha(source) == source_sha else {
    fail("model preparation inputs changed during compilation")
  }
  let receipt : Json = {
    "format": "moonrobo.aligned-native-model-receipt.v1",
    "model_adapter": Json(adapter),
    "model_adapter_sha256": Json(adapter_sha),
    "mujoco_library": Json(library),
    "mujoco_library_sha256": Json(library_sha),
    "source_mjcf": Json(source),
    "source_mjcf_sha256": Json(source_sha),
    "compiled_mjb_sha256": Json(@artifacts.sha256(mjb)),
    "compiled_mjb_bytes": Json(mjb.length()),
    "descriptor_sha256": Json(
      @artifacts.sha256(@utf8.encode(descriptor.stringify())),
    ),
    "input_hash_scope": "adapter, MuJoCo library and root MJCF only; referenced asset closure not included",
    "python_used": false,
    "simulation_executed": false,
    "newton_model_constructed": false,
    "physical_equivalence_verified": false,
  }
  { descriptor, mjb, receipt, }
}
