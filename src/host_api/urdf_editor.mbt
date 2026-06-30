///|
pub fn robobook_urdf_document_path() -> String {
  "/api/robobook/urdf/document"
}

///|
pub fn robobook_urdf_history_path() -> String {
  "/api/robobook/urdf/history"
}

///|
pub fn robobook_urdf_edit_path() -> String {
  "/api/robobook/urdf/edit"
}

///|
pub fn robobook_urdf_revert_path() -> String {
  "/api/robobook/urdf/revert"
}

///|
pub fn robobook_urdf_document_response(root : String) -> HostApiResponse {
  match @runtime.read_active_urdf_document(root) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}

///|
pub fn robobook_urdf_history_response(root : String) -> HostApiResponse {
  match @runtime.list_urdf_editor_history(root) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}

///|
pub fn robobook_urdf_edit_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request : @runtime.UrdfEditorEditRequest = @json.from_json(
    @json.parse(body),
  ) catch {
    _ =>
      return error_response(
        400,
        "parse-urdf-editor-edit",
        robobook_urdf_edit_path(),
        "failed to parse URDF editor edit request",
      )
  }
  match @runtime.apply_active_urdf_edit(root, request) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}

///|
pub fn robobook_urdf_revert_response(root : String) -> HostApiResponse {
  match @runtime.revert_latest_urdf_edit(root) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}
