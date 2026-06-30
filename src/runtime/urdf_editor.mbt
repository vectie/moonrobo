///|
pub(all) struct ActiveUrdfDocument {
  model_primary : String
  model_path : String
  document : @urdf_editor.UrdfDocument
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorEditRequest {
  command : String
  joint_name : String?
  link_name : String?
  visual_index : Int?
  origin : @urdf_editor.UrdfOriginPatch?
  limit : @urdf_editor.UrdfLimitPatch?
  save : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorEditReceipt {
  edit_id : String
  command : String
  target : String
  model_primary : String
  model_path : String
  changed : Bool
  status : String
  issue_count : Int
  receipt_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorApplyResult {
  persisted : Bool
  model_primary : String
  model_path : String
  receipt_path : String
  edit : @urdf_editor.UrdfEditResult
  receipt : UrdfEditorEditReceipt?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn active_urdf_model_path(
  root : String,
) -> Result[(String, String), RuntimeIssue] {
  let profile = match load_robot_profile(root) {
    Ok(profile) => profile
    Err(error) => return Err(error)
  }
  let primary = profile.model.primary
  if primary == "" || !primary.has_suffix(".urdf") {
    return Err(
      issue(
        "active-urdf-missing", primary, "selected RoboBook model is not a URDF artifact",
      ),
    )
  }
  Ok((primary, robobook_path(root, primary)))
}

///|
pub fn read_active_urdf_document(
  root : String,
) -> Result[ActiveUrdfDocument, RuntimeIssue] {
  let (primary, path) = match active_urdf_model_path(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-urdf-editor-source", path, "failed to read active URDF"),
      )
  }
  Ok({
    model_primary: primary,
    model_path: path,
    document: @urdf_editor.parse_document(source),
  })
}

///|
fn sanitize_edit_id_part(raw : String) -> String {
  let clean = raw
    .trim()
    .to_owned()
    .replace(old="/", new="-")
    .replace(old="\\", new="-")
    .replace(old=":", new="-")
    .replace(old=" ", new="-")
    .replace(old=".", new="-")
  if clean == "" {
    "target"
  } else {
    clean
  }
}

///|
fn edit_status(edit : @urdf_editor.UrdfEditResult) -> String {
  if edit.issues.any(fn(item) { item.severity == @urdf_editor.Error }) {
    "diagnostic"
  } else {
    "ready"
  }
}

///|
fn write_urdf_editor_receipt(
  root : String,
  primary : String,
  path : String,
  edit : @urdf_editor.UrdfEditResult,
) -> Result[UrdfEditorEditReceipt, RuntimeIssue] {
  match ensure_dir(root, "runs") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/model-edits") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let edit_id = "urdf-edit-\{sanitize_edit_id_part(edit.command)}-\{sanitize_edit_id_part(edit.target)}-\{edit.source.length()}"
  let receipt_path = robobook_path(root, "runs/model-edits/\{edit_id}.json")
  let receipt = {
    edit_id,
    command: edit.command,
    target: edit.target,
    model_primary: primary,
    model_path: path,
    changed: edit.changed,
    status: edit_status(edit),
    issue_count: edit.issues.length(),
    receipt_path,
  }
  let body = receipt.to_json().stringify(indent=2)
  @fsx.write_string_to_file(receipt_path, body) catch {
    _ =>
      return Err(
        issue(
          "write-urdf-editor-receipt", receipt_path, "failed to write URDF editor receipt",
        ),
      )
  }
  @fsx.write_string_to_file(
    robobook_path(root, "runs/model-edits/latest.json"),
    body,
  ) catch {
    _ =>
      return Err(
        issue(
          "write-urdf-editor-latest", receipt_path, "failed to write latest URDF editor receipt",
        ),
      )
  }
  Ok(receipt)
}

///|
fn required_joint_name(
  request : UrdfEditorEditRequest,
) -> Result[String, @urdf_editor.UrdfEditError] {
  match request.joint_name {
    Some(name) if name.trim() != "" => Ok(name)
    _ =>
      Err(@urdf_editor.UrdfEditError::{
        code: "joint-name-required",
        target: request.command,
        message: "URDF editor command requires joint_name",
        issues: [],
      })
  }
}

///|
fn required_origin(
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfOriginPatch, @urdf_editor.UrdfEditError] {
  match request.origin {
    Some(origin) => Ok(origin)
    None =>
      Err(@urdf_editor.UrdfEditError::{
        code: "origin-required",
        target: request.command,
        message: "URDF editor command requires origin",
        issues: [],
      })
  }
}

///|
fn required_limit(
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfLimitPatch, @urdf_editor.UrdfEditError] {
  match request.limit {
    Some(limit) => Ok(limit)
    None =>
      Err(@urdf_editor.UrdfEditError::{
        code: "limit-required",
        target: request.command,
        message: "URDF editor command requires limit",
        issues: [],
      })
  }
}

///|
fn apply_urdf_editor_command(
  source : String,
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfEditResult, @urdf_editor.UrdfEditError] {
  match request.command {
    "update-joint-limit" => {
      let joint_name = match required_joint_name(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let limit = match required_limit(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_joint_limit(source, joint_name, limit)
    }
    "update-joint-origin" => {
      let joint_name = match required_joint_name(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let origin = match required_origin(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_joint_origin(source, joint_name, origin)
    }
    "update-visual-origin" => {
      let link_name = match request.link_name {
        Some(value) if value.trim() != "" => value
        _ =>
          return Err(@urdf_editor.UrdfEditError::{
            code: "link-name-required",
            target: request.command,
            message: "URDF editor command requires link_name",
            issues: [],
          })
      }
      let visual_index = match request.visual_index {
        Some(value) => value
        None =>
          return Err(@urdf_editor.UrdfEditError::{
            code: "visual-index-required",
            target: request.command,
            message: "URDF editor command requires visual_index",
            issues: [],
          })
      }
      let origin = match required_origin(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_visual_origin(source, link_name, visual_index, origin)
    }
    _ =>
      Err(@urdf_editor.UrdfEditError::{
        code: "urdf-editor-command-unknown",
        target: request.command,
        message: "unknown URDF editor command `\{request.command}`",
        issues: [],
      })
  }
}

///|
pub fn apply_active_urdf_edit(
  root : String,
  request : UrdfEditorEditRequest,
) -> Result[UrdfEditorApplyResult, RuntimeIssue] {
  let (primary, path) = match active_urdf_model_path(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-urdf-editor-source", path, "failed to read active URDF"),
      )
  }
  let edit = match apply_urdf_editor_command(source, request) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.target, error.message))
  }
  let mut receipt_path = ""
  let mut receipt : UrdfEditorEditReceipt? = None
  if request.save && edit.changed {
    @fsx.write_string_to_file(path, edit.source) catch {
      _ =>
        return Err(
          issue("write-urdf-editor-source", path, "failed to write active URDF"),
        )
    }
    let persisted = match write_urdf_editor_receipt(root, primary, path, edit) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    receipt_path = persisted.receipt_path
    receipt = Some(persisted)
  }
  Ok({
    persisted: request.save && edit.changed,
    model_primary: primary,
    model_path: path,
    receipt_path,
    edit,
    receipt,
  })
}
