///|
pub fn robobook_import_urdf_path() -> String {
  "/api/robobook/import-urdf"
}

///|
pub fn robobook_import_urdf_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request : @runtime.UrdfImportRequest = @json.from_json(@json.parse(body)) catch {
    _ =>
      return error_response(
        400,
        "parse-urdf-import",
        robobook_import_urdf_path(),
        "failed to parse URDF import request",
      )
  }
  match @runtime.import_urdf_model(root, request) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}
