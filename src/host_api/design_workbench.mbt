///|
/// Inert workbench routes. The caller's selected RoboBook remains untouched;
/// drafts and fresh digital artifacts live only in the workbench namespace.
pub fn design_workbench_response(
  root : String,
  operation : String,
  body : String,
) -> HostApiResponse {
  if body.length() > 131072 {
    return error_response(
      400, "design-too-large", operation, "Workbench requests must be at most 128 KiB",
    )
  }
  let request = @json.parse(body) catch {
    _ =>
      return error_response(
        400, "invalid-design-request", operation, "Expected JSON request",
      )
  }
  let result = (fn() -> Json raise {
    if operation == "catalogue" {
      guard request is Object(_) else { fail("Catalogue requires an object") }
      return @design_workbench.catalogue(root).to_json()
    }
    if operation == "save" {
      guard request
        is { "design": design, "recorded_at": String(recorded_at), .. } else {
        fail("Save requires design and recorded_at")
      }
      let draft = @design_workbench.save_draft(root, design, recorded_at)
      return @design_workbench.inspect_revision(
        root,
        draft.design_id,
        draft.revision,
      )
    }
    guard request
      is { "design_id": String(id), "revision": String(revision), .. } else {
      fail("Select a design ID and revision")
    }
    if operation == "open" {
      return @design_workbench.inspect_revision(root, id, revision)
    }
    guard request is { "expected_digest": String(digest), .. } else {
      fail("Re-open the saved draft to select its exact source digest")
    }
    match operation {
      "build" => {
        let _ = @design_workbench.build_revision(root, id, revision, digest)
        @design_workbench.inspect_revision(root, id, revision)
      }
      "export" =>
        @design_workbench.export_input(root, id, revision, digest).to_json()
      _ => fail("Unknown design workbench operation")
    }
  })() catch {
    error =>
      return error_response(
        409,
        "design-workbench-unconfirmed",
        operation,
        error.to_string(),
      )
  }
  json_response(200, result)
}
