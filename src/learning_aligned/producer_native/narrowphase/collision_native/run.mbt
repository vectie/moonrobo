///|
pub(all) struct Config {
  adapter : String
  mujoco_library : String
  mjb : String
  qpos : Array[Double]
  contact_capacity : Int32
  output : String
} derive(Debug, FromJson, ToJson)

///|
async fn explicit_file(path : String) -> String {
  guard !path.is_empty() && !path.contains("\u{0}") else {
    fail("explicit NUL-free collision file path required")
  }
  let path = @fs.realpath(path)
  guard @fs.kind(path) is Regular else {
    fail("native collision input must be a regular file")
  }
  path
}

///|
async fn file_sha(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
/// Explicit independent native collision command. Preserve source files and
/// publish a fresh receipt only after a complete, capacity-checked C result.
pub async fn run(config : Config) -> Json {
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    fail("fresh native collision output directory required")
  }
  guard config.contact_capacity >= 0 else { fail("negative contact capacity") }
  let adapter = explicit_file(config.adapter)
  let library = explicit_file(config.mujoco_library)
  let mjb = explicit_file(config.mjb)
  let adapter_sha = file_sha(adapter)
  let library_sha = file_sha(library)
  let mjb_sha = file_sha(mjb)
  let input = config.qpos.to_json().stringify(indent=2)
  let session = Session::open(adapter, library, mjb, config.contact_capacity)
  let contacts = {
    defer session.close()
    session.collide(config.qpos)
  }
  guard adapter_sha == file_sha(adapter) &&
    library_sha == file_sha(library) &&
    mjb_sha == file_sha(mjb) else {
    fail("native collision input changed during operation")
  }
  let output = contacts.stringify(indent=2)
  let receipt : Json = {
    "format": "moonrobo-mujoco-native-collision-receipt-v1",
    "backend": "mujoco-3.3.7-native-cpu-collision",
    "inputs": {
      "adapter": { "path": adapter.to_json(), "sha256": adapter_sha.to_json() },
      "mujoco_library": {
        "path": library.to_json(),
        "sha256": library_sha.to_json(),
      },
      "mjb": { "path": mjb.to_json(), "sha256": mjb_sha.to_json() },
      "qpos": {
        "path": "input-qpos.json",
        "sha256": @artifacts.sha256(@utf8.encode(input)).to_json(),
      },
    },
    "contacts": {
      "path": "contacts.json",
      "sha256": @artifacts.sha256(@utf8.encode(output)).to_json(),
    },
    "header_version": 337,
    "contact_capacity": config.contact_capacity.to_json(),
    "input_kind": "precompiled-mjb",
    "model_compilation_executed": false,
    "python_initialized": false,
    "gpu_initialized": false,
    "newton_backend_replaced": false,
    "warp_capture_generated": false,
    "cross_solver_equivalence_verified": false,
    "transitive_native_dependencies_attested": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(folder + "input-qpos.json", input, create_mode=CreateNew)
  @fs.write_file(folder + "contacts.json", output, create_mode=CreateNew)
  @fs.write_file(
    folder + "receipt.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
