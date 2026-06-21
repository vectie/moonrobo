///|
pub fn moonclaw_run_next_path() -> String {
  "/api/moonclaw/run-next"
}

///|
fn decode_agent_process_request(
  body : String,
  path : String,
) -> Result[@agent_process.AgentProcessRunRequest, HostApiError] {
  if body == "" {
    return Ok(@agent_process.default_run_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-agent-process",
        path,
        message: "failed to parse agent process JSON",
      })
  }
  let request : @agent_process.AgentProcessRunRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-agent-process",
        path,
        message: "failed to decode agent process contract",
      })
  }
  Ok(request)
}

///|
pub fn moonclaw_run_next_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_agent_process_request(body, moonclaw_run_next_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  match @agent_process.run_next(root, request) {
    Ok(result) => json_response(200, result.to_json())
    Err(error) => pipeline_error_response(error)
  }
}
