///|
#borrow(library, source, output)
extern "c" fn convert_native(
  library : Bytes,
  source : Bytes,
  output : Bytes,
  self_collision : Bool,
) -> Bytes = "moonrobo_aligned_convert_usd"

///|
/// Genuine C++ MuJoCo-model -> standard USDA conversion, without Python or Kit.
pub async fn convert_usd(
  converter_library : String,
  source : String,
  output : String,
  self_collisions~ : Bool = true,
) -> Json {
  guard output.has_suffix(".usda") && !@fs.exists(output) else {
    fail("USD conversion needs a new explicit .usda destination")
  }
  let source_digest = @artifacts.sha256(@fs.read_file(source).binary())
  let converter_digest = @artifacts.sha256(
    @fs.read_file(converter_library).binary(),
  )
  let error = @utf8.decode(
    convert_native(
      @utf8.encode(converter_library),
      @utf8.encode(source),
      @utf8.encode(output),
      self_collisions,
    ),
  )
  guard error == "" else { fail("native USD conversion failed: " + error) }
  let receipt : Json = {
    "format": "moonrobo.aligned-native-usd-conversion.v1",
    "source_mjcf": source.to_json(),
    "source_sha256": source_digest.to_json(),
    "output_usda": output.to_json(),
    "output_sha256": @artifacts.sha256(@fs.read_file(output).binary()).to_json(),
    "converter_library_sha256": converter_digest.to_json(),
    "self_collisions": self_collisions.to_json(),
    "representation": "standard UsdGeom/UsdPhysics, compiled MuJoCo geometry/inertias",
    "python_used": false,
    "simulation_executed": false,
    "isaac_importer_bitwise_equivalence": false,
    "openusd_validation_executed": false,
    "gpu_validation_executed": false,
  }
  ignore(@artifacts.save_json(output + ".receipt.json", receipt))
  receipt
}
