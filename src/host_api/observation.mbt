///|
pub(all) struct ObservationStartRequest {
  session_id : String
  receipt_id : String
  requester : @core.Requester
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationStopRequest {
  receipt_id : String
  requester : @core.Requester
  now_ms : Int64
  telemetry_frame_count : Int
  latest_frame_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationSubmissionResponse {
  persisted : Bool
  receipt_path : String
  observation_path : String
  session : @core.ObservationSession
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn observation_start_path() -> String {
  "/api/sessions/observe"
}

///|
pub fn observation_stop_path(session_id : String) -> String {
  "/api/sessions/\{session_id}/stop"
}

///|
fn generated_session_id(
  profile : @core.RobotProfile,
  request : ObservationStartRequest,
) -> String {
  if request.session_id == "" {
    "observe-\{profile.id}-\{request.now_ms}"
  } else {
    request.session_id
  }
}

///|
fn maybe_frame_id(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
fn observe_result(
  profile : @core.RobotProfile,
  requester : @core.Requester,
  receipt_id : @core.ReceiptId,
  now_ms : Int64,
) -> @pipeline.PipelineResult {
  @pipeline.evaluate_request(
    profile,
    @core.bridge_ok(profile.bridge.id, profile.id, last_telemetry_age_ms=0),
    @pipeline.observe_telemetry_intent(
      "intent-observe-\{receipt_id}",
      profile.id,
      requester,
    ),
    receipt_id,
    now_ms,
  )
}

///|
fn decode_observation_start(
  body : String,
  path : String,
) -> Result[ObservationStartRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-start",
        path,
        message: "failed to parse observation start JSON",
      })
  }
  let request : ObservationStartRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-start",
        path,
        message: "failed to decode observation start contract",
      })
  }
  Ok(request)
}

///|
fn decode_observation_stop(
  body : String,
  path : String,
) -> Result[ObservationStopRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-stop",
        path,
        message: "failed to parse observation stop JSON",
      })
  }
  let request : ObservationStopRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-stop",
        path,
        message: "failed to decode observation stop contract",
      })
  }
  Ok(request)
}

///|
fn ensure_observe_allowed(
  result : @pipeline.PipelineResult,
  path : String,
) -> HostApiResponse? {
  if result.next_action == Execute {
    None
  } else {
    Some(
      error_response(
        400, "observation-not-allowed", path, "safety pipeline did not allow observation",
      ),
    )
  }
}

///|
pub fn observation_start_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_observation_start(body, observation_start_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let session_id = generated_session_id(book.profile, request)
  let result = observe_result(
    book.profile,
    request.requester,
    request.receipt_id,
    request.now_ms,
  )
  match ensure_observe_allowed(result, observation_start_path()) {
    Some(response) => return response
    None => ()
  }
  let receipt = @core.executed_receipt(
    request.receipt_id,
    result.receipt,
    request.now_ms,
    telemetry_frame_count=1,
  )
  let session = @core.observation_session(
    session_id,
    book.profile,
    request.requester,
    receipt.receipt_id,
    request.now_ms,
    telemetry_frame_count=1,
    latest_frame_id="sdk-e1-sidecar-\{request.now_ms}",
  )
  let bridge_request = @bridge_protocol.start_observe_request(
    "request-observe-start-\{session_id}-\{request.now_ms}",
    book.profile,
    session_id,
    request.now_ms,
  )
  let bridge_response = @bridge_protocol.session_response(
    bridge_request, "observation session started",
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let observation_path = match
    @runtime.write_observation_session(root, session) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      receipt_path,
      observation_path,
      session,
      receipt,
      bridge_response,
      result,
    }.to_json(),
  )
}

///|
fn session_id_from_observation_stop_path(path : String) -> String? {
  let prefix = "/api/sessions/"
  let suffix = "/stop"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
pub fn observation_stop_response(
  root : String,
  path : String,
  body : String,
) -> HostApiResponse {
  let session_id = match session_id_from_observation_stop_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let request = match decode_observation_stop(body, path) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let existing = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  if existing.status != Active {
    return error_response(
      400, "observation-not-active", path, "observation session is not active",
    )
  }
  let result = observe_result(
    book.profile,
    request.requester,
    request.receipt_id,
    request.now_ms,
  )
  match ensure_observe_allowed(result, path) {
    Some(response) => return response
    None => ()
  }
  let receipt = @core.executed_receipt(
    request.receipt_id,
    result.receipt,
    request.now_ms,
    telemetry_frame_count=request.telemetry_frame_count,
  )
  let session = match maybe_frame_id(request.latest_frame_id) {
    Some(frame_id) =>
      @core.stopped_observation_session(
        existing,
        request.now_ms,
        request.telemetry_frame_count,
        latest_frame_id=frame_id,
      )
    None =>
      @core.stopped_observation_session(
        existing,
        request.now_ms,
        request.telemetry_frame_count,
      )
  }
  let bridge_request = @bridge_protocol.stop_session_request(
    "request-observe-stop-\{session_id}-\{request.now_ms}",
    book.profile,
    session_id,
    request.now_ms,
  )
  let bridge_response = @bridge_protocol.session_response(
    bridge_request, "observation session stopped",
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let observation_path = match
    @runtime.write_observation_session(root, session) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      receipt_path,
      observation_path,
      session,
      receipt,
      bridge_response,
      result,
    }.to_json(),
  )
}
