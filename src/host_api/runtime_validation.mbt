///|
fn decode_runtime_validation_session_request(
  body : String,
  path : String,
) -> Result[@runtime.RuntimeValidationSessionRequest, HostApiResponse] {
  if body == "" {
    return Ok(@runtime.default_runtime_validation_session_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400, "parse-runtime-validation-session", path, "failed to parse runtime validation session JSON",
        ),
      )
  }
  let request : @runtime.RuntimeValidationSessionRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400, "decode-runtime-validation-session", path, "failed to decode runtime validation session contract",
        ),
      )
  }
  Ok(request)
}

///|
pub fn runtime_validation_session_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_runtime_validation_session_request(
      body,
      runtime_validation_session_path(),
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  match
    @runtime.write_runtime_validation_session_from_latest_health(
      root,
      book.profile,
      0L,
      request,
    ) {
    Ok(result) => json_response(200, result.to_json())
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}
