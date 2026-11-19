///|
pub fn HostLayout::metadata(self : HostLayout) -> Json raise {
  let arrays : Array[Json] = []
  let aliases : Array[Json] = []
  for name in self.array_names() {
    arrays.push({ "name": Json(name), "array": self.arrays[name].metadata() })
  }
  for name in self.view_names() {
    if self.aliases.contains(name) {
      let (base, shape, components, offset, size) = self.resolve(name)
      aliases.push({
        "name": Json(name),
        "base": Json(base),
        "offset_bytes": Json(offset),
        "shape": Json(shape),
        "components": Json(components),
        "byte_length": Json(size),
        "separate_allocation": false,
      })
    }
  }
  {
    "format": "moonrobo.rigid-tree-host-layout.v1",
    "body_count": Json(self.body_count),
    "joint_count": Json(self.joint_count),
    "coord_count": Json(self.coord_count),
    "dof_count": Json(self.dof_count),
    "world_count": Json(self.world_count),
    "scalar_type": Json(self.scalar_type),
    "target_layout": Json(self.target_layout),
    "mass_properties_complete": Json(self.mass_properties_complete),
    "arrays": Json(arrays),
    "aliases": Json(aliases),
    "storage_scope": self.storage_scope,
    "unresolved_semantics": Json(self.unresolved_semantics),
    "full_finalize_complete": false,
    "newton_model_constructed": false,
    "device_state_created": false,
    "numerical_equivalence_verified": false,
  }
}

///|
/// Explicit host-only artifact preparation. No library loading, SDK, CUDA
/// initialization, JIT, model conversion or upload is hidden in this command.
pub async fn finalize_artifact(
  request : CommandRequest,
  output : String,
) -> Json {
  let layout = prepare(request)
  write_host_artifact(
    layout,
    command_json(request),
    output,
    "moonrobo.rigid-tree-host-artifact.v1",
  )
}

///|
fn command_json(request : CommandRequest) -> Json {
  {
    "builder_request": {
      "usd_receipt": request.builder_request.usd_receipt,
      "num_envs": Json(request.builder_request.num_envs),
      "self_collisions": Json(request.builder_request.self_collisions),
      "placements": Json(request.builder_request.placements),
    },
    "scalar_type": Json(request.scalar_type),
    "target_layout": Json(request.target_layout),
  }
}

///|
/// Explicit host-only shape/contact initialization. Only physical owners are
/// written; alias metadata references those same bytes and SHA identities.
pub async fn collision_artifact(
  request : CollisionRequest,
  output : String,
) -> Json {
  let layout = prepare_collision(request)
  let input : Json = {
    "base": command_json(request.base),
    "shapes": Json(request.shapes),
    "filters": Json(request.filters),
    "candidate_limit": Json(request.candidate_limit),
    "contacts": Json(request.contacts),
  }
  write_host_artifact(
    layout, input, output, "moonrobo.primitive-collision-host-artifact.v1",
  )
}

///|
async fn write_host_artifact(
  layout : HostLayout,
  input : Json,
  output : String,
  format : String,
) -> Json {
  guard !output.is_empty() && !@fs.exists(output) else {
    fail("fresh nonexistent host-layout output directory required")
  }
  let input_bytes = @utf8.encode(input.stringify(indent=2))
  let names = layout.array_names()
  for name in names {
    guard !name.is_empty() &&
      !name.has_prefix(".") &&
      !name.contains("/") &&
      !name.contains("\\") &&
      !name.contains("\u{0}") else {
      fail("unsafe typed array artifact name")
    }
  }
  @fs.mkdir(output, recursive=true)
  @fs.write_file(output + "/request.json", input_bytes, create_mode=CreateNew)
  let files : Array[Json] = []
  for name in names {
    let array = layout.arrays[name]
    let path = name + ".bin"
    @fs.write_file(output + "/" + path, array.bytes, create_mode=CreateNew)
    files.push({
      "path": Json(path),
      "name": Json(name),
      "array": array.metadata(),
    })
  }
  let result : Json = {
    "format": Json(format),
    "request_path": "request.json",
    "request_sha256": Json(@artifacts.sha256(input_bytes)),
    "layout": layout.metadata(),
    "files": Json(files),
    "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    "full_finalize_complete": false,
    "newton_model_constructed": false,
    "python_runtime_required": false,
    "cuda_context_created": false,
    "gpu_upload_performed": false,
    "numerical_equivalence_verified": false,
  }
  @fs.write_file(
    output + "/layout.json",
    result.stringify(indent=2),
    create_mode=CreateNew,
  )
  result
}
