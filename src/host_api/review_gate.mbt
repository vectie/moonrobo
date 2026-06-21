///|
pub(all) struct ReviewResolutionRequest {
  note : String
  resolved_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReviewResolutionResponse {
  persisted : Bool
  review_path : String
  review : @review.ProcessReview
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn review_path(review_id : String) -> String {
  "/api/reviews/\{review_id}"
}

///|
pub fn review_resolve_path(review_id : String) -> String {
  "\{review_path(review_id)}/resolve"
}

///|
fn review_id_from_review_path(path : String) -> String? {
  let prefix = "/api/reviews/"
  if path.has_prefix(prefix) &&
    path.length() > prefix.length() &&
    !path.has_suffix("/resolve") {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn review_id_from_resolve_path(path : String) -> String? {
  let prefix = "/api/reviews/"
  let suffix = "/resolve"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
pub fn review_response(root : String, path : String) -> HostApiResponse {
  let review_id = match review_id_from_review_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  match @runtime.read_process_review(root, review_id) {
    Ok(review) => json_response(200, review.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}

///|
fn default_resolution_request() -> ReviewResolutionRequest {
  { note: "operator accepted review evidence", resolved_at_ms: 0L }
}

///|
fn decode_review_resolution(
  body : String,
  path : String,
) -> Result[ReviewResolutionRequest, HostApiError] {
  if body == "" {
    return Ok(default_resolution_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-review-resolution",
        path,
        message: "failed to parse review resolution JSON",
      })
  }
  let request : ReviewResolutionRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-review-resolution",
        path,
        message: "failed to decode review resolution contract",
      })
  }
  Ok(request)
}

///|
pub fn review_resolution_response(
  root : String,
  path : String,
  body : String,
) -> HostApiResponse {
  let review_id = match review_id_from_resolve_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let request = match decode_review_resolution(body, path) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let review = match @runtime.read_process_review(root, review_id) {
    Ok(review) => review
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  let resolved = @review.resolve_review(
    review,
    request.note,
    request.resolved_at_ms,
  )
  let review_path = match @runtime.write_process_review(root, resolved) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    { persisted: true, review_path, review: resolved }.to_json(),
  )
}
