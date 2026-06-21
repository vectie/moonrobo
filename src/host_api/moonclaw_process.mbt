///|
pub fn moonclaw_run_next_path() -> String {
  "/api/moonclaw/run-next"
}

///|
pub fn moonclaw_runs_path() -> String {
  "/api/moonclaw/runs"
}

///|
pub(all) struct AgentProcessRunListResponse {
  run_count : Int
  runs : Array[@agent_process.AgentProcessRunRecord]
} derive(Debug, Eq, ToJson, FromJson)

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
  match @agent_process.run_next_recorded(root, request) {
    Ok(record) => json_response(200, record.to_json())
    Err(error) => pipeline_error_response(error)
  }
}

///|
pub fn moonclaw_runs_response(root : String) -> HostApiResponse {
  match @agent_process.list_agent_process_records(root) {
    Ok(records) =>
      json_response(
        200,
        { run_count: records.length(), runs: records }.to_json(),
      )
    Err(error) => pipeline_error_response(error)
  }
}
