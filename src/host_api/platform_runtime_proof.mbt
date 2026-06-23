///|
pub(all) struct PlatformRuntimeProofRequest {
  telemetry : @core.TelemetryFrame
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformRuntimeProofResponse {
  persisted : Bool
  status : String
  runtime_ready : Bool
  runtime_health_path : String
  latest_runtime_health_path : String
  record : @runtime_health.RuntimeHealthRecord
  previous_record : @runtime_health.RuntimeHealthRecord
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_runtime_proof_path() -> String {
  "/api/moonrobo/runtime-proof"
}

///|
fn decode_runtime_proof_request(
  body : String,
) -> Result[PlatformRuntimeProofRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-runtime-proof",
          platform_runtime_proof_path(),
          "failed to parse runtime proof JSON",
        ),
      )
  }
  let request : PlatformRuntimeProofRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-runtime-proof",
          platform_runtime_proof_path(),
          "failed to decode runtime proof contract",
        ),
      )
  }
  Ok(request)
}

///|
fn validate_runtime_proof_identity(
  book : @runtime.LoadedRoboBook,
  frame : @core.TelemetryFrame,
) -> HostApiResponse? {
  if frame.robot_id != book.profile.id {
    Some(
      error_response(
        409,
        "runtime-proof-robot-mismatch",
        platform_runtime_proof_path(),
        "telemetry robot \{frame.robot_id} does not match RoboBook robot \{book.profile.id}",
      ),
    )
  } else if frame.bridge_id != book.profile.bridge.id {
    Some(
      error_response(
        409,
        "runtime-proof-bridge-mismatch",
        platform_runtime_proof_path(),
        "telemetry bridge \{frame.bridge_id} does not match RoboBook bridge \{book.profile.bridge.id}",
      ),
    )
  } else {
    None
  }
}

///|
fn active_runtime_health_or_error(
  root : String,
) -> Result[@runtime_health.RuntimeHealthRecord, HostApiResponse] {
  match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) =>
      if record.active && record.running {
        Ok(record)
      } else {
        Err(
          error_response(
            409,
            "runtime-proof-not-running",
            platform_runtime_proof_path(),
            "runtime proof requires persisted active runtime health from the supervisor",
          ),
        )
      }
    Ok(None) =>
      Err(
        error_response(
          409,
          "runtime-proof-no-runtime-health",
          platform_runtime_proof_path(),
          "runtime proof requires latest runtime health evidence before telemetry can be accepted",
        ),
      )
    Err(issue) =>
      Err(error_response(500, issue.code, issue.path, issue.message))
  }
}

///|
fn runtime_proof_record(
  frame : @core.TelemetryFrame,
  previous : @runtime_health.RuntimeHealthRecord,
) -> @runtime_health.RuntimeHealthRecord {
  @runtime_health.record(
    frame.captured_at_ms,
    "healthy",
    true,
    true,
    previous.pid,
    previous.launch_id,
    previous.runtime_id,
    frame.robot_id,
    frame.bridge_id,
    previous.bridge_base_url,
    true,
    "telemetry-ok",
    "runtime telemetry proof matches the selected RoboBook",
    platform_runtime_proof_path(),
    frame.frame_id,
    frame.captured_at_ms,
    health_id="runtime-proof-\{frame.frame_id}",
  )
}

///|
pub fn platform_runtime_proof_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_runtime_proof_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  match validate_runtime_proof_identity(book, request.telemetry) {
    Some(response) => return response
    None => ()
  }
  let previous_record = match active_runtime_health_or_error(root) {
    Ok(record) => record
    Err(response) => return response
  }
  let record = runtime_proof_record(request.telemetry, previous_record)
  let runtime_health_path = match @runtime.write_runtime_health(root, record) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let readiness = @readiness.report(root, book)
  json_response(
    200,
    {
      persisted: true,
      status: record.status,
      runtime_ready: record.status == "healthy",
      runtime_health_path,
      latest_runtime_health_path: @runtime.latest_runtime_health_path(root),
      record,
      previous_record,
      readiness,
      readiness_plan: @readiness.plan(readiness),
    }.to_json(),
  )
}
