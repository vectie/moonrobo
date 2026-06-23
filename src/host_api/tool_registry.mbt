///|
pub(all) struct ToolRegistryResponse {
  persisted : Bool
  registry_path : String
  registry : @tool_registry.ToolRegistry
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ToolRegistrationRequest {
  provider : @tool_registry.ToolProvider
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn tool_registry_path() -> String {
  "/api/tools/registry"
}

///|
pub fn tool_register_path() -> String {
  "/api/tools/register"
}

///|
fn tool_registry_or_response(
  root : String,
  generated_at_ms : Int64,
) -> Result[@tool_registry.ToolRegistry, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  match @runtime.ensure_tool_registry(root, book.profile.id, generated_at_ms) {
    Ok(registry) => Ok(registry)
    Err(issue) =>
      Err(error_response(500, issue.code, issue.path, issue.message))
  }
}

///|
pub fn tool_registry_response(root : String) -> HostApiResponse {
  match tool_registry_or_response(root, 0L) {
    Ok(registry) =>
      json_response(
        200,
        {
          persisted: true,
          registry_path: @runtime.tool_registry_path(root),
          registry,
        }.to_json(),
      )
    Err(response) => response
  }
}

///|
fn decode_tool_registration_request(
  body : String,
) -> Result[ToolRegistrationRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-tool-registration",
          tool_register_path(),
          "failed to parse tool registration JSON",
        ),
      )
  }
  let request : ToolRegistrationRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-tool-registration",
          tool_register_path(),
          "failed to decode tool registration contract",
        ),
      )
  }
  Ok(request)
}

///|
pub fn tool_register_response(root : String, body : String) -> HostApiResponse {
  let request = match decode_tool_registration_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let registry = match
    @runtime.register_tool_provider(
      root,
      book.profile.id,
      request.provider,
      request.now_ms,
    ) {
    Ok(registry) => registry
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      registry_path: @runtime.tool_registry_path(root),
      registry,
    }.to_json(),
  )
}
