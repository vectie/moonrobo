///|
pub(all) struct ActiveUrdfDocument {
  model_primary : String
  model_path : String
  document : @urdf_editor.UrdfDocument
  components : Array[@urdf_editor.UrdfEditorComponentRow]
  session : @urdf_editor.UrdfEditorSession
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorEditRequest {
  command : String
  joint_name : String?
  link_name : String?
  new_name : String?
  selected_node_id : String?
  session : @urdf_editor.UrdfEditorSession?
  material_node_id : String?
  visual_index : Int?
  collision_index : Int?
  origin : @urdf_editor.UrdfOriginPatch?
  limit : @urdf_editor.UrdfLimitPatch?
  inertial : @urdf_editor.UrdfInertialPatch?
  material : @urdf_editor.UrdfMaterialPatch?
  geometry : @urdf_editor.UrdfGeometryPatch?
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
  before_digest : String
  after_digest : String
  before_source_path : String
  after_source_path : String
  diff_summary : String
  receipt_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorHistoryResult {
  model_primary : String
  model_path : String
  receipt_count : Int
  receipts : Array[UrdfEditorEditReceipt]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorApplyResult {
  persisted : Bool
  model_primary : String
  model_path : String
  receipt_path : String
  edit : @urdf_editor.UrdfEditResult
  session : @urdf_editor.UrdfEditorSession
  receipt : UrdfEditorEditReceipt?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorRevertResult {
  reverted : Bool
  model_primary : String
  model_path : String
  receipt_path : String
  source_path : String
  before_digest : String
  after_digest : String
  message : String
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
fn model_edit_receipts_dir(root : String) -> String {
  robobook_path(root, "runs/model-edits")
}

///|
fn read_urdf_editor_receipt_file(
  path : String,
) -> Result[UrdfEditorEditReceipt, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-urdf-editor-receipt", path, "failed to read URDF editor receipt",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-urdf-editor-receipt", path, "failed to parse URDF editor receipt JSON",
        ),
      )
  }
  let receipt : UrdfEditorEditReceipt = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-urdf-editor-receipt", path, "failed to decode URDF editor receipt",
        ),
      )
  }
  Ok(receipt)
}

///|
pub fn list_urdf_editor_history(
  root : String,
) -> Result[UrdfEditorHistoryResult, RuntimeIssue] {
  let (primary, path) = match active_urdf_model_path(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dir = model_edit_receipts_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok({
      model_primary: primary,
      model_path: path,
      receipt_count: 0,
      receipts: [],
    })
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-urdf-editor-history", dir, "failed to read URDF editor history directory",
        ),
      )
  }
  names.sort()
  let receipts : Array[UrdfEditorEditReceipt] = []
  let mut index = names.length()
  while index > 0 {
    index -= 1
    let name = names[index]
    if name.has_suffix(".json") &&
      name != "latest.json" &&
      name != "latest-revert.json" {
      let receipt_path = model_edit_receipts_dir(root) + "/\{name}"
      let receipt = match read_urdf_editor_receipt_file(receipt_path) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if receipt.model_primary == primary && receipt.model_path == path {
        receipts.push(receipt)
      }
    }
  }
  Ok({
    model_primary: primary,
    model_path: path,
    receipt_count: receipts.length(),
    receipts,
  })
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
  let document = @urdf_editor.parse_document(source)
  Ok({
    model_primary: primary,
    model_path: path,
    document,
    components: @urdf_editor.component_tree(document),
    session: @urdf_editor.start_session(source),
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
    .replace(old=";", new="-")
    .replace(old="=", new="-")
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
fn source_line_count(source : String) -> Int {
  if source == "" {
    0
  } else {
    source.split("\n").length()
  }
}

///|
fn source_digest(source : String) -> String {
  let mut hash = 5381
  for index in 0..<source.length() {
    hash = hash * 33 + source.unsafe_get(index).to_int()
    while hash >= 1000000 {
      hash -= 1000000
    }
  }
  "bytes=\{source.length()};lines=\{source_line_count(source)};sum=\{hash}"
}

///|
fn first_source_diff(before : String, after : String) -> Int {
  let limit = if before.length() < after.length() {
    before.length()
  } else {
    after.length()
  }
  for index in 0..<limit {
    if before[index:index + 1] != after[index:index + 1] {
      return index
    }
  }
  limit
}

///|
fn source_diff_summary(before : String, after : String) -> String {
  if before == after {
    "unchanged; \{before.length()} bytes; \{source_line_count(before)} lines"
  } else {
    let at = first_source_diff(before, after)
    "changed at byte \{at}; before \{before.length()} bytes/\{source_line_count(before)} lines; after \{after.length()} bytes/\{source_line_count(after)} lines"
  }
}

///|
fn write_urdf_editor_receipt(
  root : String,
  primary : String,
  path : String,
  before_source : String,
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
  match ensure_dir(root, "runs/model-edits/sources") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let before_digest = source_digest(before_source)
  let after_digest = source_digest(edit.source)
  let edit_id = "urdf-edit-\{sanitize_edit_id_part(edit.command)}-\{sanitize_edit_id_part(edit.target)}-\{edit.source.length()}-\{sanitize_edit_id_part(after_digest)}"
  let before_source_path = robobook_path(
    root,
    "runs/model-edits/sources/\{edit_id}-before.urdf",
  )
  let after_source_path = robobook_path(
    root,
    "runs/model-edits/sources/\{edit_id}-after.urdf",
  )
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
    before_digest,
    after_digest,
    before_source_path,
    after_source_path,
    diff_summary: source_diff_summary(before_source, edit.source),
    receipt_path,
  }
  @fsx.write_string_to_file(before_source_path, before_source) catch {
    _ =>
      return Err(
        issue(
          "write-urdf-editor-before-source", before_source_path, "failed to write URDF editor before-source snapshot",
        ),
      )
  }
  @fsx.write_string_to_file(after_source_path, edit.source) catch {
    _ =>
      return Err(
        issue(
          "write-urdf-editor-after-source", after_source_path, "failed to write URDF editor after-source snapshot",
        ),
      )
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
fn required_inertial(
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfInertialPatch, @urdf_editor.UrdfEditError] {
  match request.inertial {
    Some(inertial) => Ok(inertial)
    None =>
      Err(@urdf_editor.UrdfEditError::{
        code: "inertial-required",
        target: request.command,
        message: "URDF editor command requires inertial",
        issues: [],
      })
  }
}

///|
fn required_material(
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfMaterialPatch, @urdf_editor.UrdfEditError] {
  match request.material {
    Some(material) => Ok(material)
    None =>
      Err(@urdf_editor.UrdfEditError::{
        code: "material-required",
        target: request.command,
        message: "URDF editor command requires material",
        issues: [],
      })
  }
}

///|
fn required_geometry(
  request : UrdfEditorEditRequest,
) -> Result[@urdf_editor.UrdfGeometryPatch, @urdf_editor.UrdfEditError] {
  match request.geometry {
    Some(geometry) => Ok(geometry)
    None =>
      Err(@urdf_editor.UrdfEditError::{
        code: "geometry-required",
        target: request.command,
        message: "URDF editor command requires geometry",
        issues: [],
      })
  }
}

///|
fn required_new_name(
  request : UrdfEditorEditRequest,
) -> Result[String, @urdf_editor.UrdfEditError] {
  match request.new_name {
    Some(value) if value.trim() != "" => Ok(value)
    _ =>
      Err(@urdf_editor.UrdfEditError::{
        code: "new-name-required",
        target: request.command,
        message: "URDF editor command requires new_name",
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
    "rename-link" => {
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
      let new_name = match required_new_name(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.rename_link(source, link_name, new_name)
    }
    "rename-joint" => {
      let joint_name = match required_joint_name(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let new_name = match required_new_name(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.rename_joint(source, joint_name, new_name)
    }
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
    "update-visual-geometry" => {
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
      let geometry = match required_geometry(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_visual_geometry(
        source, link_name, visual_index, geometry,
      )
    }
    "update-collision-origin" => {
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
      let collision_index = match request.collision_index {
        Some(value) => value
        None =>
          return Err(@urdf_editor.UrdfEditError::{
            code: "collision-index-required",
            target: request.command,
            message: "URDF editor command requires collision_index",
            issues: [],
          })
      }
      let origin = match required_origin(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_collision_origin(
        source, link_name, collision_index, origin,
      )
    }
    "update-collision-geometry" => {
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
      let collision_index = match request.collision_index {
        Some(value) => value
        None =>
          return Err(@urdf_editor.UrdfEditError::{
            code: "collision-index-required",
            target: request.command,
            message: "URDF editor command requires collision_index",
            issues: [],
          })
      }
      let geometry = match required_geometry(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_collision_geometry(
        source, link_name, collision_index, geometry,
      )
    }
    "update-inertial" => {
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
      let inertial = match required_inertial(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_inertial(source, link_name, inertial)
    }
    "update-material" => {
      let material_node_id = match request.material_node_id {
        Some(value) if value.trim() != "" => value
        _ =>
          return Err(@urdf_editor.UrdfEditError::{
            code: "material-node-id-required",
            target: request.command,
            message: "URDF editor command requires material_node_id",
            issues: [],
          })
      }
      let material = match required_material(request) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @urdf_editor.update_material(source, material_node_id, material)
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
fn save_session_edit(
  persisted_source : String,
  session_source : String,
  selected_node_id : String,
) -> @urdf_editor.UrdfEditResult {
  let document = @urdf_editor.parse_document(session_source)
  let changed = persisted_source != session_source
  {
    changed,
    command: "save-session",
    target: if selected_node_id.trim() == "" {
      "robot"
    } else {
      selected_node_id
    },
    source: session_source,
    message: if changed {
      "saved URDF editor session"
    } else {
      "URDF editor session unchanged"
    },
    issues: document.issues,
  }
}

///|
fn request_selected_node_id(request : UrdfEditorEditRequest) -> String {
  match request.selected_node_id {
    Some(node_id) if node_id.trim() != "" => return node_id
    _ => ()
  }
  match request.command {
    "rename-joint" | "update-joint-origin" | "update-joint-limit" =>
      match request.joint_name {
        Some(name) if name.trim() != "" => "joint:\{name}"
        _ => "robot"
      }
    "rename-link" | "update-inertial" =>
      match request.link_name {
        Some(name) if name.trim() != "" =>
          if request.command == "update-inertial" {
            "inertial:\{name}"
          } else {
            "link:\{name}"
          }
        _ => "robot"
      }
    "update-visual-origin" | "update-visual-geometry" =>
      match (request.link_name, request.visual_index) {
        (Some(name), Some(index)) if name.trim() != "" =>
          "visual:\{name}:\{index}"
        _ => "robot"
      }
    "update-collision-origin" | "update-collision-geometry" =>
      match (request.link_name, request.collision_index) {
        (Some(name), Some(index)) if name.trim() != "" =>
          "collision:\{name}:\{index}"
        _ => "robot"
      }
    "update-material" =>
      match request.material_node_id {
        Some(node_id) if node_id.trim() != "" => node_id
        _ => "robot"
      }
    _ => "robot"
  }
}

///|
fn request_session(
  persisted_source : String,
  request : UrdfEditorEditRequest,
) -> @urdf_editor.UrdfEditorSession {
  let selected_node_id = request_selected_node_id(request)
  match request.session {
    Some(session) =>
      @urdf_editor.select_session_component(session, selected_node_id)
    None => @urdf_editor.start_session(persisted_source, selected_node_id~)
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
  let persisted_source = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-urdf-editor-source", path, "failed to read active URDF"),
      )
  }
  let base_session = request_session(persisted_source, request)
  let edit = if request.command == "save-session" {
    save_session_edit(
      persisted_source,
      base_session.source,
      base_session.selected_node_id,
    )
  } else {
    match apply_urdf_editor_command(base_session.source, request) {
      Ok(value) => value
      Err(error) => return Err(issue(error.code, error.target, error.message))
    }
  }
  let edited_session = if request.command == "save-session" {
    base_session
  } else {
    @urdf_editor.push_session_edit(base_session, edit)
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
    let persisted = match
      write_urdf_editor_receipt(root, primary, path, persisted_source, edit) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    receipt_path = persisted.receipt_path
    receipt = Some(persisted)
  }
  let session = if request.save && edit.changed {
    @urdf_editor.commit_session(edited_session)
  } else {
    edited_session
  }
  Ok({
    persisted: request.save && edit.changed,
    model_primary: primary,
    model_path: path,
    receipt_path,
    edit,
    session,
    receipt,
  })
}

///|
pub fn revert_latest_urdf_edit(
  root : String,
) -> Result[UrdfEditorRevertResult, RuntimeIssue] {
  let (primary, path) = match active_urdf_model_path(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt_path = robobook_path(root, "runs/model-edits/latest.json")
  let receipt_text = @fsx.read_file_to_string(receipt_path) catch {
    _ =>
      return Err(
        issue(
          "read-urdf-editor-latest", receipt_path, "failed to read latest URDF editor receipt",
        ),
      )
  }
  let receipt_json = @json.parse(receipt_text) catch {
    _ =>
      return Err(
        issue(
          "parse-urdf-editor-latest", receipt_path, "failed to parse latest URDF editor receipt",
        ),
      )
  }
  let receipt : UrdfEditorEditReceipt = @json.from_json(receipt_json) catch {
    _ =>
      return Err(
        issue(
          "decode-urdf-editor-latest", receipt_path, "failed to decode latest URDF editor receipt",
        ),
      )
  }
  if receipt.model_path != path || receipt.model_primary != primary {
    return Err(
      issue(
        "urdf-editor-revert-model-mismatch", path, "latest URDF edit receipt belongs to a different active model",
      ),
    )
  }
  let before_source = @fsx.read_file_to_string(receipt.before_source_path) catch {
    _ =>
      return Err(
        issue(
          "read-urdf-editor-before-source",
          receipt.before_source_path,
          "failed to read URDF editor before-source snapshot",
        ),
      )
  }
  let current_source = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-urdf-editor-source", path, "failed to read active URDF"),
      )
  }
  let current_digest = source_digest(current_source)
  if current_digest != receipt.after_digest {
    return Err(
      issue(
        "urdf-editor-revert-stale-active", path, "active URDF no longer matches the latest edit receipt after-source digest",
      ),
    )
  }
  @fsx.write_string_to_file(path, before_source) catch {
    _ =>
      return Err(
        issue("write-urdf-editor-source", path, "failed to restore active URDF"),
      )
  }
  let result = {
    reverted: true,
    model_primary: primary,
    model_path: path,
    receipt_path,
    source_path: receipt.before_source_path,
    before_digest: current_digest,
    after_digest: source_digest(before_source),
    message: "reverted latest URDF edit \{receipt.edit_id}",
  }
  let body = result.to_json().stringify(indent=2)
  @fsx.write_string_to_file(
    robobook_path(root, "runs/model-edits/latest-revert.json"),
    body,
  ) catch {
    _ =>
      return Err(
        issue(
          "write-urdf-editor-revert", receipt_path, "failed to write URDF editor revert receipt",
        ),
      )
  }
  Ok(result)
}
