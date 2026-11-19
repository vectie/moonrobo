///|
async fn write_mesh_artifact(
  mesh : PreparedMesh,
  request : MeshRequest,
  output : String,
  execution : Json,
) -> Json {
  guard !output.is_empty() && !@fs.exists(output) else {
    fail("fresh nonexistent cooking artifact directory required")
  }
  let input = @utf8.encode(request.to_json().stringify(indent=2))
  let files : Array[Json] = []
  for
    (name, bytes, dtype, shape, components) in [
      ("points.bin", mesh.points, "f32", [mesh.vertex_count], 3),
      ("velocities.bin", mesh.velocities, "f32", [mesh.vertex_count], 3),
      ("indices.bin", mesh.indices, "i32", [mesh.triangle_count * 3], 1),
      ("groups.bin", mesh.groups, "i32", [mesh.groups.length() / 4], 1),
    ] {
    files.push({
      "path": Json(name),
      "byte_length": Json(bytes.length()),
      "sha256": Json(@artifacts.sha256(bytes)),
      "scalar_type": Json(dtype),
      "shape": Json(shape),
      "components": Json(components),
      "byte_order": "little",
    })
  }
  let result : Json = {
    "format": "moonrobo.triangle-mesh-cooking-artifact.v1",
    "request_path": "request.json",
    "request_sha256": Json(@artifacts.sha256(input)),
    "prepared": mesh.metadata(),
    "files": Json(files),
    "execution": execution,
    "full_newton_cooking_complete": false,
    "physical_equivalence_verified": false,
  }
  @fs.mkdir(output, recursive=true)
  @fs.write_file(output + "/request.json", input, create_mode=CreateNew)
  for
    (name, bytes) in [
      ("points.bin", mesh.points),
      ("velocities.bin", mesh.velocities),
      ("indices.bin", mesh.indices),
      ("groups.bin", mesh.groups),
    ] {
    @fs.write_file(output + "/" + name, bytes, create_mode=CreateNew)
  }
  @fs.write_file(
    output + "/manifest.json",
    result.stringify(indent=2),
    create_mode=CreateNew,
  )
  result
}

///|
/// Explicit host-byte preparation only. Never loads a library or cooks a BVH.
pub async fn mesh_artifact(request : MeshRequest, output : String) -> Json {
  let mesh = prepare_mesh(request)
  write_mesh_artifact(mesh, request, output, {
    "native_execution_performed": false,
    "resource_live_after_command": false,
    "cuda_initialized": false,
    "python_used": false,
  })
}
