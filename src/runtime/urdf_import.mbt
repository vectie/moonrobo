///|
pub(all) struct UrdfImportRequest {
  source_path : String
  import_id : String
  activate : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfImportResult {
  imported : Bool
  activated : Bool
  source_path : String
  import_id : String
  import_root : String
  urdf_source_path : String
  urdf_path : String
  model_primary : String
  mesh_count : Int
  copied_file_count : Int
  joint_count : Int
  link_count : Int
  visual_count : Int
  robot_name : String
  profile_path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

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
fn path_join(left : String, right : String) -> String {
  if left.has_suffix("/") {
    left + right
  } else {
    left + "/" + right
  }
}

///|
fn is_directory(path : String) -> Bool {
  @fsx.is_dir(path) catch {
    _ => false
  }
}

///|
fn sanitize_import_id(raw : String, fallback : String) -> String {
  let base = if raw.trim() == "" { fallback } else { path_basename(raw) }
  let clean = base
    .trim()
    .to_owned()
    .replace(old=".tar.gz", new="")
    .replace(old=".urdf", new="")
    .replace(old=" ", new="-")
    .replace(old="/", new="-")
    .replace(old="\\", new="-")
    .replace(old=":", new="-")
    .replace(old=".", new="-")
  if clean == "" || clean == "-" {
    "imported-urdf"
  } else {
    clean
  }
}

///|
fn ensure_import_dirs(
  root : String,
  import_id : String,
) -> Result[Unit, RuntimeIssue] {
  match ensure_robobook_root(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for
    relative in [
      "model",
      "model/imports",
      "model/imports/\{import_id}",
      "model/imports/\{import_id}/meshes",
    ] {
    match ensure_dir(root, relative) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  Ok(())
}

///|
fn urdf_candidate_score(path : String) -> Int {
  if path.contains("/urdf/") {
    0
  } else if path.has_suffix("/robot.urdf") {
    1
  } else if path.contains("/meshes/") {
    3
  } else {
    2
  }
}

///|
fn better_urdf_candidate(candidate : String, current : String?) -> String {
  match current {
    None => candidate
    Some(value) =>
      if urdf_candidate_score(candidate) < urdf_candidate_score(value) {
        candidate
      } else {
        value
      }
  }
}

///|
fn find_urdf_file(dir : String) -> String? {
  let mut found : String? = None
  let names = @fsx.read_dir(dir) catch { _ => return found }
  for name in names {
    let path = path_join(dir, name)
    if is_directory(path) {
      match find_urdf_file(path) {
        Some(candidate) => found = Some(better_urdf_candidate(candidate, found))
        None => ()
      }
    } else if name.has_suffix(".urdf") {
      found = Some(better_urdf_candidate(path, found))
    }
  }
  found
}

///|
fn copy_file(source : String, target : String) -> Result[Unit, RuntimeIssue] {
  let bytes = @fsx.read_file_to_bytes(source) catch {
    _ =>
      return Err(
        issue("read-import-file", source, "failed to read import file"),
      )
  }
  @fsx.write_bytes_to_file(target, bytes) catch {
    _ =>
      return Err(
        issue("write-import-file", target, "failed to write import file"),
      )
  }
  Ok(())
}

///|
fn copy_dir_contents(
  source : String,
  target : String,
) -> Result[Int, RuntimeIssue] {
  let mut copied = 0
  let names = @fsx.read_dir(source) catch {
    _ =>
      return Err(
        issue("read-import-dir", source, "failed to read import directory"),
      )
  }
  for name in names {
    let source_path = path_join(source, name)
    let target_path = path_join(target, name)
    if is_directory(source_path) {
      if !@fsx.path_exists(target_path) {
        @fsx.create_dir(target_path) catch {
          _ =>
            return Err(
              issue(
                "create-import-dir", target_path, "failed to create import directory",
              ),
            )
        }
      }
      match copy_dir_contents(source_path, target_path) {
        Ok(count) => copied += count
        Err(error) => return Err(error)
      }
    } else {
      match copy_file(source_path, target_path) {
        Ok(_) => copied += 1
        Err(error) => return Err(error)
      }
    }
  }
  Ok(copied)
}

///|
fn copy_meshes(
  source_root : String,
  target_root : String,
) -> Result[(Int, Int), RuntimeIssue] {
  let source_meshes = path_join(source_root, "meshes")
  if !@fsx.path_exists(source_meshes) || !is_directory(source_meshes) {
    Ok((0, 0))
  } else {
    let target_meshes = path_join(target_root, "meshes")
    let copied = match copy_dir_contents(source_meshes, target_meshes) {
      Ok(count) => count
      Err(error) => return Err(error)
    }
    Ok((copied, copied))
  }
}

///|
fn rewrite_package_uris(text : String) -> String {
  let mut output = text
  for _ in 0..<4096 {
    match output.split_once("package://") {
      Some((_, rest)) =>
        match rest.split_once("/") {
          Some((package_name, _)) =>
            output = output.replace(old="package://\{package_name}/", new="")
          None => return output
        }
      None => return output
    }
  }
  output
}

///|
fn joints_from_urdf(model : @urdf.UrdfModel) -> Array[@core.JointSpec] {
  let joints : Array[@core.JointSpec] = []
  let mut index = 0
  for joint in model.joints {
    if joint.joint_type != "fixed" {
      let min_position = match joint.limit {
        Some(limit) => limit.lower
        None => None
      }
      let max_position = match joint.limit {
        Some(limit) => limit.upper
        None => None
      }
      joints.push({ name: joint.name, index, min_position, max_position })
      index += 1
    }
  }
  joints
}

///|
pub fn import_urdf_model(
  root : String,
  request : UrdfImportRequest,
) -> Result[UrdfImportResult, RuntimeIssue] {
  let source = request.source_path.trim().to_owned()
  if source == "" {
    return Err(
      issue("missing-urdf-source", source, "URDF import source is required"),
    )
  }
  if source.has_suffix(".tar.gz") || source.has_suffix(".tgz") {
    return Err(
      issue(
        "extract-urdf-archive", source, "URDF archive must be extracted before import",
      ),
    )
  }
  if !@fsx.path_exists(source) || !is_directory(source) {
    return Err(
      issue(
        "missing-urdf-source", source, "URDF import source is not a directory",
      ),
    )
  }
  let source_urdf = match find_urdf_file(source) {
    Some(path) => path
    None =>
      return Err(
        issue(
          "missing-urdf-file", source, "URDF import source does not contain a .urdf file",
        ),
      )
  }
  let raw_text = @fsx.read_file_to_string(source_urdf) catch {
    _ => return Err(issue("read-urdf", source_urdf, "failed to read URDF file"))
  }
  let rewritten = rewrite_package_uris(raw_text)
  let model = @urdf.parse(rewritten)
  let fallback_id = if model.robot_name == "" {
    path_basename(source)
  } else {
    model.robot_name
  }
  let import_id = sanitize_import_id(request.import_id, fallback_id)
  match ensure_import_dirs(root, import_id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let import_relative = "model/imports/\{import_id}"
  let import_root = robobook_path(root, import_relative)
  let target_urdf = path_join(import_root, "robot.urdf")
  @fsx.write_string_to_file(target_urdf, rewritten) catch {
    _ =>
      return Err(
        issue("write-urdf", target_urdf, "failed to write imported URDF"),
      )
  }
  let (mesh_count, copied_count) = match copy_meshes(source, import_root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let model_primary = "\{import_relative}/robot.urdf"
  let mut profile_path = ""
  if request.activate {
    let profile = match load_robot_profile(root) {
      Ok(profile) => profile
      Err(error) => return Err(error)
    }
    let joints = joints_from_urdf(model)
    let activated_profile = {
      ..profile,
      model: { ..profile.model, primary: model_primary },
      joints,
    }
    profile_path = match write_robot_profile(root, activated_profile) {
      Ok(path) => path
      Err(error) => return Err(error)
    }
  }
  Ok({
    imported: true,
    activated: request.activate,
    source_path: source,
    import_id,
    import_root,
    urdf_source_path: source_urdf,
    urdf_path: target_urdf,
    model_primary,
    mesh_count,
    copied_file_count: copied_count + 1,
    joint_count: model.joint_count,
    link_count: model.link_count,
    visual_count: model.visual_count,
    robot_name: model.robot_name,
    profile_path,
    message: "Imported URDF `\{model.robot_name}` with \{model.link_count} links and \{model.joint_count} joints",
  })
}
