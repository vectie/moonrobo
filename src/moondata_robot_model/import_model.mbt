///|
pub(all) struct RobotModelImportRequest {
  root : String
  source_dir : String
  model_id : @moondata_core.RobotModelId
  robot_id : String
  imported_at_ms : Int64
  package_name : String
  source_label : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ImportedRobotModelAsset {
  source_path : String
  stored_path : String
  relative_path : String
  data_ref : @moondata_core.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotModelImportResult {
  root : String
  source_dir : String
  model_id : @moondata_core.RobotModelId
  robot_id : String
  urdf_source_path : String
  urdf_path : String
  asset_count : Int
  mesh_count : Int
  material_count : Int
  catalog_path : String
  catalog_entry_count : Int
  model : @moondata_core.RobotModelManifest
  assets : Array[ImportedRobotModelAsset]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robot_model_import_request(
  root : String,
  source_dir : String,
  model_id : @moondata_core.RobotModelId,
  robot_id : String,
  imported_at_ms : Int64,
  package_name? : String = "",
  source_label? : String = "MoonData robot model import",
) -> RobotModelImportRequest {
  {
    root,
    source_dir,
    model_id,
    robot_id,
    imported_at_ms,
    package_name,
    source_label,
  }
}

///|
fn issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn is_directory(path : String) -> Bool {
  @fsx.is_dir(path) catch {
    _ => false
  }
}

///|
fn path_basename(path : String) -> String {
  let clean = path.trim(chars=['/']).to_owned()
  if clean == "" {
    ""
  } else {
    let parts = clean.split("/").to_array()
    match parts.get(parts.length() - 1) {
      Some(value) => value.to_owned()
      None => clean
    }
  }
}

///|
fn ensure_dir(
  path : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  if @fsx.path_exists(path) {
    return Ok(())
  }
  @fsx.create_dir(path) catch {
    _ =>
      return Err(
        issue(
          "create-robot-model-dir", path, "failed to create robot model import directory",
        ),
      )
  }
  Ok(())
}

///|
fn safe_ref_id(path : String) -> String {
  let out = StringBuilder()
  for char in path {
    if char.is_ascii_alphabetic() ||
      char.is_ascii_digit() ||
      char == '-' ||
      char == '_' {
      out.write_char(char)
    } else {
      out.write_char('-')
    }
  }
  let value = out.to_string()
  if value == "" {
    "asset"
  } else {
    value
  }
}

///|
fn validate_model_id(
  model_id : @moondata_core.RobotModelId,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  if model_id == "" || model_id.contains("/") || model_id.contains("\\") {
    Err(
      issue(
        "invalid-model-id", model_id, "robot model id must be non-empty and path-safe",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn read_names(
  dir : String,
) -> Result[Array[String], @moondata_store.MoonDataStoreIssue] {
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-robot-model-dir", dir, "failed to read robot model source directory",
        ),
      )
  }
  names.sort()
  Ok(names)
}

///|
fn collect_files(
  source_dir : String,
  relative_dir : String,
  files : Array[(String, String)],
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let dir = if relative_dir == "" {
    source_dir
  } else {
    join(source_dir, relative_dir)
  }
  let names = match read_names(dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for name in names {
    let relative = if relative_dir == "" {
      name
    } else {
      relative_dir + "/" + name
    }
    let path = join(source_dir, relative)
    if is_directory(path) {
      match collect_files(source_dir, relative, files) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    } else {
      files.push((path, relative))
    }
  }
  Ok(())
}

///|
fn urdf_score(relative_path : String) -> Int {
  if relative_path.contains("/urdf/") {
    0
  } else if relative_path.has_suffix("robot.urdf") {
    1
  } else {
    2
  }
}

///|
fn find_urdf_asset(files : Array[(String, String)]) -> (String, String)? {
  let mut best : (String, String)? = None
  for file in files {
    let (_, relative) = file
    if relative.has_suffix(".urdf") {
      best = match best {
        None => Some(file)
        Some(current) => {
          let (_, current_relative) = current
          if urdf_score(relative) < urdf_score(current_relative) {
            Some(file)
          } else {
            Some(current)
          }
        }
      }
    }
  }
  best
}

///|
fn model_media_dir(
  root : String,
  model_id : @moondata_core.RobotModelId,
) -> String {
  join(root, "media/robot_models/\{model_id}")
}

///|
fn model_asset_uri(
  model_id : @moondata_core.RobotModelId,
  relative_path : String,
) -> String {
  "moondata://media/robot_models/\{model_id}/\{relative_path}"
}

///|
fn asset_kind(relative_path : String) -> String {
  if relative_path.has_suffix(".urdf") {
    "urdf"
  } else if relative_path.has_suffix(".stl") {
    "stl"
  } else if relative_path.has_suffix(".dae") {
    "dae"
  } else if relative_path.has_suffix(".obj") {
    "obj"
  } else if relative_path.has_suffix(".glb") {
    "glb"
  } else if relative_path.has_suffix(".gltf") {
    "gltf"
  } else if relative_path.has_suffix(".mtl") {
    "material"
  } else if relative_path.has_suffix(".png") {
    "texture"
  } else if relative_path.has_suffix(".jpg") ||
    relative_path.has_suffix(".jpeg") {
    "texture"
  } else if relative_path.has_suffix(".json") {
    "material"
  } else {
    "asset"
  }
}

///|
fn content_type(relative_path : String) -> String {
  if relative_path.has_suffix(".urdf") {
    "application/xml"
  } else if relative_path.has_suffix(".json") {
    "application/json"
  } else if relative_path.has_suffix(".stl") {
    "model/stl"
  } else if relative_path.has_suffix(".dae") {
    "model/vnd.collada+xml"
  } else if relative_path.has_suffix(".obj") {
    "model/obj"
  } else if relative_path.has_suffix(".png") {
    "image/png"
  } else if relative_path.has_suffix(".jpg") ||
    relative_path.has_suffix(".jpeg") {
    "image/jpeg"
  } else {
    "application/octet-stream"
  }
}

///|
fn is_mesh_ref(data_ref : @moondata_core.DataRef) -> Bool {
  data_ref.kind == "stl" ||
  data_ref.kind == "dae" ||
  data_ref.kind == "obj" ||
  data_ref.kind == "glb" ||
  data_ref.kind == "gltf"
}

///|
fn is_material_ref(data_ref : @moondata_core.DataRef) -> Bool {
  data_ref.kind == "material" || data_ref.kind == "texture"
}

///|
fn ensure_relative_dirs(
  root : String,
  model_id : @moondata_core.RobotModelId,
  relative_path : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let mut current = model_media_dir(root, model_id)
  match ensure_dir(join(root, "media")) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match ensure_dir(join(root, "media/robot_models")) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match ensure_dir(current) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let parts = relative_path.split("/").to_array()
  if parts.length() <= 1 {
    return Ok(())
  }
  for index in 0..<(parts.length() - 1) {
    current = join(current, parts[index].to_owned())
    match ensure_dir(current) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
fn rewrite_package_uris(
  text : String,
  model_id : @moondata_core.RobotModelId,
  package_name : String,
) -> String {
  let mut output = text
  if package_name != "" {
    output = output.replace(
      old="package://\{package_name}/",
      new="moondata://media/robot_models/\{model_id}/",
    )
  }
  for _ in 0..<4096 {
    match output.split_once("package://") {
      Some((_, rest)) =>
        match rest.split_once("/") {
          Some((current_package, _)) =>
            output = output.replace(
              old="package://\{current_package}/",
              new="moondata://media/robot_models/\{model_id}/",
            )
          None => return output
        }
      None => return output
    }
  }
  output
}

///|
fn copy_asset(
  root : String,
  model_id : @moondata_core.RobotModelId,
  source_path : String,
  relative_path : String,
  urdf_relative_path : String,
  rewritten_urdf : String,
) -> Result[ImportedRobotModelAsset, @moondata_store.MoonDataStoreIssue] {
  match ensure_relative_dirs(root, model_id, relative_path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stored_path = join(model_media_dir(root, model_id), relative_path)
  let mut byte_count = 0L
  let mut checksum = ""
  if relative_path == urdf_relative_path {
    @fsx.write_string_to_file(stored_path, rewritten_urdf) catch {
      _ =>
        return Err(
          issue(
            "write-robot-model-urdf", stored_path, "failed to write MoonData URDF",
          ),
        )
    }
    byte_count = rewritten_urdf.length().to_int64()
    checksum = @moondata_core.text_checksum(rewritten_urdf)
  } else {
    let bytes = @fsx.read_file_to_bytes(source_path) catch {
      _ =>
        return Err(
          issue(
            "read-robot-model-asset", source_path, "failed to read robot model asset",
          ),
        )
    }
    @fsx.write_bytes_to_file(stored_path, bytes) catch {
      _ =>
        return Err(
          issue(
            "write-robot-model-asset", stored_path, "failed to write MoonData robot model asset",
          ),
        )
    }
    byte_count = bytes.length().to_int64()
    checksum = @moondata_core.bytes_checksum(bytes)
  }
  Ok({
    source_path,
    stored_path,
    relative_path,
    data_ref: @moondata_core.data_ref(
      "asset-\{model_id}-\{safe_ref_id(relative_path)}",
      asset_kind(relative_path),
      model_asset_uri(model_id, relative_path),
      content_type=content_type(relative_path),
      byte_count~,
      checksum~,
    ),
  })
}

///|
fn extract_named_tags(text : String, tag : String) -> Array[String] {
  let names : Array[String] = []
  let parts = text.split("<\{tag}").to_array()
  for index in 1..<parts.length() {
    let fragment = parts[index]
    match fragment.split_once("name=\"") {
      Some((_, rest)) =>
        match rest.split_once("\"") {
          Some((name, _)) => if name != "" { names.push(name.to_owned()) }
          None => ()
        }
      None =>
        match fragment.split_once("name='") {
          Some((_, rest)) =>
            match rest.split_once("'") {
              Some((name, _)) => if name != "" { names.push(name.to_owned()) }
              None => ()
            }
          None => ()
        }
    }
  }
  names
}

///|
fn mesh_refs(
  assets : Array[ImportedRobotModelAsset],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for asset in assets {
    if is_mesh_ref(asset.data_ref) {
      refs.push(asset.data_ref)
    }
  }
  refs
}

///|
fn material_refs(
  assets : Array[ImportedRobotModelAsset],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for asset in assets {
    if is_material_ref(asset.data_ref) {
      refs.push(asset.data_ref)
    }
  }
  refs
}

///|
pub fn import_robot_model(
  request : RobotModelImportRequest,
) -> Result[RobotModelImportResult, @moondata_store.MoonDataStoreIssue] {
  match validate_model_id(request.model_id) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if request.robot_id == "" {
    return Err(
      issue(
        "robot-id-required",
        request.model_id,
        "robot model import requires a robot id",
      ),
    )
  }
  let source_dir = request.source_dir.trim().to_owned()
  if !@fsx.path_exists(source_dir) || !is_directory(source_dir) {
    return Err(
      issue(
        "source-dir-missing", source_dir, "robot model source directory is missing or not a directory",
      ),
    )
  }
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let files : Array[(String, String)] = []
  match collect_files(source_dir, "", files) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (urdf_source_path, urdf_relative_path) = match find_urdf_asset(files) {
    Some(value) => value
    None =>
      return Err(
        issue(
          "urdf-missing", source_dir, "robot model source has no .urdf file",
        ),
      )
  }
  let raw_urdf = @fsx.read_file_to_string(urdf_source_path) catch {
    _ =>
      return Err(
        issue("read-urdf", urdf_source_path, "failed to read robot model URDF"),
      )
  }
  let package_name = if request.package_name == "" {
    path_basename(source_dir)
  } else {
    request.package_name
  }
  let rewritten_urdf = rewrite_package_uris(
    raw_urdf,
    request.model_id,
    package_name,
  )
  let assets : Array[ImportedRobotModelAsset] = []
  for file in files {
    let (source_path, relative_path) = file
    let asset = match
      copy_asset(
        request.root,
        request.model_id,
        source_path,
        relative_path,
        urdf_relative_path,
        rewritten_urdf,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    assets.push(asset)
  }
  let urdf_asset = match assets.get(0) {
    Some(value) => {
      let mut selected = value
      for asset in assets {
        if asset.relative_path == urdf_relative_path {
          selected = asset
        }
      }
      selected
    }
    None =>
      return Err(
        issue(
          "robot-model-empty", source_dir, "robot model source has no files",
        ),
      )
  }
  let mesh_values = mesh_refs(assets)
  let material_values = material_refs(assets)
  let model = @moondata_core.robot_model_manifest(
    request.model_id,
    request.robot_id,
    "urdf",
    "active",
    urdf_asset.data_ref,
    request.imported_at_ms,
    mesh_refs=mesh_values,
    material_refs=material_values,
    link_names=extract_named_tags(rewritten_urdf, "link"),
    joint_names=extract_named_tags(rewritten_urdf, "joint"),
    provenance="\{request.source_label}: file://\{source_dir}",
    validation_status="pending",
    summary="Imported URDF robot model \{request.model_id} for \{request.robot_id}",
  )
  match @moondata_store.write_robot_model(request.root, model) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.imported_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    source_dir,
    model_id: request.model_id,
    robot_id: request.robot_id,
    urdf_source_path,
    urdf_path: urdf_asset.stored_path,
    asset_count: assets.length(),
    mesh_count: mesh_values.length(),
    material_count: material_values.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    model,
    assets,
  })
}
