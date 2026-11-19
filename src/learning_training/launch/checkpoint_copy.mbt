///|
/// Resolve an existing input without changing its extension or bytes.
pub async fn checkpoint_input(path : String) -> String {
  if @fs.exists(path) {
    return path
  }
  if path.has_suffix(".moon.json") {
    let legacy = path[:path.length() - 10].to_owned() + ".pt"
    if @fs.exists(legacy) {
      return legacy
    }
  }
  fail("checkpoint input does not exist: " + path)
}

///|
/// Native JSON inputs retain byte identity. Torch ZIP inputs are converted by
/// the restricted numeric loader before any .moon.json output is written.
/// Optimizer/RNG restoration is not implied by this inference conversion.
pub async fn copy_checkpoint(
  source : String,
  destination : String,
  kind : String,
) -> Json {
  guard destination.has_suffix(".moon.json") else {
    fail("native checkpoint copy requires an explicit .moon.json destination")
  }
  guard ["residual-dynamics", "g1-actor"].contains(kind) else {
    fail("checkpoint copy kind is not supported")
  }
  let actual = checkpoint_input(source)
  let bytes = @fs.read_file(actual).binary()
  let checkpoint = @training.load_learning_checkpoint(actual, kind)
  let converted = bytes.length() >= 4 && bytes[0:4] == b"PK\x03\x04"
  let legacy_copy = destination[:destination.length() - 10].to_owned() + ".pt"
  if converted && @fs.exists(legacy_copy) {
    guard @fs.read_file(legacy_copy).binary() == bytes else {
      fail("legacy checkpoint companion already exists with different bytes")
    }
  }
  let output_sha = if converted {
    @artifacts.save_checkpoint(destination, checkpoint)
  } else {
    @fs.write_file(destination, bytes, create_mode=CreateOrTruncate)
    @artifacts.sha256(bytes)
  }
  if converted && !@fs.exists(legacy_copy) {
    // A copied historical report can still name its original .pt artifact.
    // Preserve those exact bytes under their real format as a companion.
    @fs.write_file(legacy_copy, bytes, create_mode=CreateNew)
  }
  let report : Json = {
    "format": "moonrobo.checkpoint-copy.v1",
    "source": actual.to_json(),
    "source_sha256": @artifacts.sha256(bytes).to_json(),
    "destination": destination.to_json(),
    "destination_sha256": output_sha.to_json(),
    "model_kind": kind.to_json(),
    "converted_from_torch": converted.to_json(),
    "byte_identical": (!converted).to_json(),
    "optimizer_state_restored": false,
    "legacy_companion": (if converted { Some(legacy_copy) } else { None }).to_json(),
  }
  ignore(@artifacts.save_json(destination + ".source.json", report))
  report
}
