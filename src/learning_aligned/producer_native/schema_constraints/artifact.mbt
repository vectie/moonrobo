///|
pub fn decode_artifact(value : Json) -> (Json, String) raise {
  strict(value, ["request", "output"])
  guard value is { "request": request, "output": String(output), .. } else {
    fail("expected request/output artifact config")
  }
  (request, output)
}

///|
/// Explicit CPU preparation only; never calls native cooking/compilation/SDK.
pub async fn schema_artifact(request : SchemaRequest, output : String) -> Json {
  guard !output.is_empty() && !@fs.exists(output) else {
    fail("fresh schema output directory required")
  }
  let result = resolve_schema(request)
  let input = @utf8.encode(request.to_json().stringify(indent=2))
  let bytes = @utf8.encode(result.stringify(indent=2))
  let receipt : Json = {
    "format": "moonrobo-schema-resolution-artifact-v1",
    "request": {
      "path": "request.json",
      "sha256": Json(@artifacts.sha256(input)),
    },
    "result": {
      "path": "resolved.json",
      "sha256": Json(@artifacts.sha256(bytes)),
    },
    "python_runtime_required": false,
    "sdk_initialized": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(output, recursive=true)
  @fs.write_file(output + "/request.json", input, create_mode=CreateNew)
  @fs.write_file(output + "/resolved.json", bytes, create_mode=CreateNew)
  @fs.write_file(
    output + "/manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}

///|
/// Writes true typed equality-frequency arrays plus an MJCF include for a
/// subsequent native MuJoCo model compiler. No model compiler is called here.
pub async fn equality_artifact(
  request : EqualityRequest,
  output : String,
) -> Json {
  guard !output.is_empty() && !@fs.exists(output) else {
    fail("fresh equality output directory required")
  }
  let prepared = prepare_equalities(request)
  let input = @utf8.encode(request.to_json().stringify(indent=2))
  let mjcf = @utf8.encode(prepared.mjcf)
  @fs.mkdir(output, recursive=true)
  @fs.write_file(output + "/request.json", input, create_mode=CreateNew)
  @fs.write_file(output + "/equalities.xml", mjcf, create_mode=CreateNew)
  let files = []
  for array in prepared.arrays {
    let path = array.name + ".bin"
    @fs.write_file(output + "/" + path, array.bytes, create_mode=CreateNew)
    files.push({ "path": Json(path), "array": array.metadata() })
  }
  let receipt : Json = {
    "format": "moonrobo-newton-equality-artifact-v1",
    "layout": prepared.metadata,
    "request": {
      "path": "request.json",
      "sha256": Json(@artifacts.sha256(input)),
    },
    "mjcf_include": {
      "path": "equalities.xml",
      "sha256": Json(@artifacts.sha256(mjcf)),
    },
    "files": Json(files),
    "python_runtime_required": false,
    "model_compiler_executed": false,
    "gpu_upload_performed": false,
    "full_constraint_solver_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.write_file(
    output + "/manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
