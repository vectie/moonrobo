///|
pub(all) enum SdkE1TelemetrySourceKind {
  GeneratedSnapshot
  SnapshotFile
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1TelemetrySource {
  kind : SdkE1TelemetrySourceKind
  snapshot_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1BridgeConfig {
  robobook_root : String
  read_only : Bool
  telemetry_source : SdkE1TelemetrySource
  command_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1BridgeHttpResponse {
  status : Int
  content_type : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1BridgeIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn config(
  robobook_root : String,
  read_only? : Bool = true,
  snapshot_path? : String = "",
  command_path? : String = "",
) -> SdkE1BridgeConfig {
  {
    robobook_root,
    read_only,
    telemetry_source: telemetry_source(snapshot_path),
    command_path,
  }
}

///|
pub fn telemetry_source(snapshot_path : String) -> SdkE1TelemetrySource {
  if snapshot_path.trim().to_owned() == "" {
    { kind: GeneratedSnapshot, snapshot_path: "" }
  } else {
    { kind: SnapshotFile, snapshot_path }
  }
}

///|
fn json_response(status : Int, body : Json) -> SdkE1BridgeHttpResponse {
  { status, content_type: "application/json", body: body.stringify(indent=2) }
}

///|
fn issue_response(
  status : Int,
  code : String,
  message : String,
) -> SdkE1BridgeHttpResponse {
  json_response(status, { code, message }.to_json())
}

///|
fn response_json(
  status : Int,
  response : @bridge_protocol.BridgeResponse,
) -> SdkE1BridgeHttpResponse {
  json_response(status, response.to_json())
}

///|
fn load_profile(
  config : SdkE1BridgeConfig,
) -> Result[@core.RobotProfile, SdkE1BridgeHttpResponse] {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => Ok(book.profile)
    Err(issue) => Err(issue_response(500, issue.code, issue.message))
  }
}

///|
fn generated_snapshot(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> @sdk_e1.SdkE1Snapshot {
  {
    ..@sdk_e1.default_snapshot("sdk-e1-sidecar-\{now_ms}", now_ms),
    joints: @sdk_e1.default_joint_states(profile),
  }
}

///|
fn read_snapshot_file(
  path : String,
) -> Result[@sdk_e1.SdkE1Snapshot, SdkE1BridgeHttpResponse] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue_response(
          500, "read-sdk-snapshot", "failed to read SDK E1 snapshot file",
        ),
      )
  }
  match @sdk_e1.parse_snapshot(text) {
    Ok(snapshot) => Ok(snapshot)
    Err(issue) => Err(issue_response(500, issue.code, issue.message))
  }
}

///|
fn snapshot_from_source(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> Result[@sdk_e1.SdkE1Snapshot, SdkE1BridgeHttpResponse] {
  let snapshot = match config.telemetry_source.kind {
    GeneratedSnapshot => generated_snapshot(profile, now_ms)
    SnapshotFile =>
      match read_snapshot_file(config.telemetry_source.snapshot_path) {
        Ok(snapshot) => snapshot
        Err(response) => return Err(response)
      }
  }
  match @sdk_e1.validate_snapshot(profile, snapshot) {
    Ok(_) => Ok(snapshot)
    Err(issue) => Err(issue_response(500, issue.code, issue.message))
  }
}

///|
fn request_id(prefix : String, now_ms : Int64) -> String {
  "\{prefix}-\{now_ms}"
}

///|
fn health_response(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  let snapshot = match snapshot_from_source(config, profile, now_ms) {
    Ok(snapshot) => snapshot
    Err(response) => return response
  }
  response_json(
    200,
    @sdk_e1.health_response(
      request_id("request-sidecar-health", now_ms),
      profile,
      snapshot,
    ),
  )
}

///|
fn metadata_response(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  let metadata = {
    ..@bridge_protocol.bridge_metadata(profile),
    read_only: config.read_only,
  }
  response_json(
    200,
    @bridge_protocol.metadata_response(
      @bridge_protocol.bridge_request(
        request_id("request-sidecar-metadata", now_ms),
        profile,
        Metadata,
        now_ms,
      ),
      metadata,
    ),
  )
}

///|
fn capabilities_response(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  response_json(
    200,
    @bridge_protocol.capabilities_response(
      @bridge_protocol.bridge_request(
        request_id("request-sidecar-capabilities", now_ms),
        profile,
        Capabilities,
        now_ms,
      ),
      profile.capabilities,
    ),
  )
}

///|
fn telemetry_response(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  let snapshot = match snapshot_from_source(config, profile, now_ms) {
    Ok(snapshot) => snapshot
    Err(response) => return response
  }
  match
    @sdk_e1.telemetry_response(
      request_id("request-sidecar-telemetry", now_ms),
      profile,
      snapshot,
    ) {
    Ok(response) => response_json(200, response)
    Err(issue) => issue_response(500, issue.code, issue.message)
  }
}

///|
fn session_id_from_stop_path(path : String) -> String? {
  let prefix = "/sessions/"
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
fn parse_bridge_request(
  profile : @core.RobotProfile,
  body : String,
) -> Result[@bridge_protocol.BridgeRequest, SdkE1BridgeHttpResponse] {
  let request = match @bridge_protocol.parse_request(body) {
    Ok(request) => request
    Err(issue) => return Err(issue_response(400, issue.code, issue.message))
  }
  match @bridge_protocol.validate_request(profile, request) {
    Err(issue) =>
      return Err(
        response_json(
          400,
          @bridge_protocol.error_response(request, "invalid bridge request", [
            issue.message,
          ]),
        ),
      )
    Ok(_) => ()
  }
  Ok(request)
}

///|
fn persist_high_control_command(
  config : SdkE1BridgeConfig,
  request : @bridge_protocol.BridgeRequest,
  command : @sdk_e1.SdkE1HighControlCommand,
) -> Result[Unit, SdkE1BridgeHttpResponse] {
  if config.command_path == "" {
    return Err(
      response_json(
        200,
        @bridge_protocol.rejected_response(
          request, "SDK E1 bridge is command-enabled but has no command output path",
        ),
      ),
    )
  }
  @fsx.write_string_to_file(
    config.command_path,
    @sdk_e1.high_control_command_json(command),
  ) catch {
    _ =>
      return Err(
        response_json(
          500,
          @bridge_protocol.error_response(
            request,
            "failed to write SDK E1 high-control command",
            [config.command_path],
          ),
        ),
      )
  }
  Ok(())
}

///|
fn session_response(
  profile : @core.RobotProfile,
  body : String,
  operation : @bridge_protocol.BridgeOperation,
  message : String,
  path_session_id? : String,
) -> SdkE1BridgeHttpResponse {
  let request = match parse_bridge_request(profile, body) {
    Ok(request) => request
    Err(response) => return response
  }
  if request.operation != operation {
    return response_json(
      400,
      @bridge_protocol.rejected_response(
        request, "session endpoint requires a matching session operation",
      ),
    )
  }
  match (path_session_id, request.session_id) {
    (Some(path_id), Some(request_id)) =>
      if path_id != request_id {
        return response_json(
          400,
          @bridge_protocol.error_response(request, "invalid bridge request", [
            "session path does not match request",
          ]),
        )
      }
    _ => ()
  }
  response_json(200, @bridge_protocol.session_response(request, message))
}

///|
fn execute_response(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  body : String,
) -> SdkE1BridgeHttpResponse {
  let request = match parse_bridge_request(profile, body) {
    Ok(request) => request
    Err(response) => return response
  }
  if request.operation != ExecuteIntent {
    return response_json(
      400,
      @bridge_protocol.rejected_response(
        request, "execute endpoint requires ExecuteIntent",
      ),
    )
  }
  if config.read_only {
    return response_json(
      200,
      @bridge_protocol.rejected_response(
        request, "SDK E1 bridge is running in read-only mode",
      ),
    )
  }
  let intent = match request.intent {
    Some(intent) => intent
    None =>
      return response_json(
        400,
        @bridge_protocol.rejected_response(
          request, "execute endpoint requires command intent",
        ),
      )
  }
  let verdict = @core.evaluate_intent(
    {
      profile,
      bridge_health: @core.bridge_ok(
        profile.bridge.id,
        profile.id,
        last_telemetry_age_ms=0,
      ),
      approval_id: Some("sdk-e1-bridge-command-enabled"),
      dry_run_receipt_id: Some("sdk-e1-bridge-command-enabled"),
      developer_gate: false,
    },
    intent,
  )
  if verdict.decision != Allow {
    return response_json(
      200,
      @bridge_protocol.rejected_response(request, verdict.detail),
    )
  }
  let command = match @sdk_e1.high_control_command(intent) {
    Ok(command) => command
    Err(issue) =>
      return response_json(
        200,
        @bridge_protocol.rejected_response(request, issue.message),
      )
  }
  match persist_high_control_command(config, request, command) {
    Ok(_) => ()
    Err(response) => return response
  }
  let snapshot = match
    snapshot_from_source(config, profile, request.issued_at_ms) {
    Ok(snapshot) => snapshot
    Err(response) => return response
  }
  let feedback = match
    @sdk_e1.command_feedback_frame(
      profile,
      snapshot,
      intent,
      frame_id="sdk-e1-command-feedback-\{intent.intent_id}-\{request.issued_at_ms}",
    ) {
    Ok(frame) => frame
    Err(issue) =>
      return response_json(
        500,
        @bridge_protocol.error_response(request, issue.message, [issue.code]),
      )
  }
  let ready = @core.receipt_from_verdict(
    "receipt-\{intent.intent_id}-bridge-accepted",
    profile.bridge.id,
    intent,
    verdict,
    request.issued_at_ms,
  )
  let receipt = @core.executed_receipt(
    ready.receipt_id,
    ready,
    request.issued_at_ms,
    telemetry_frame_count=1,
    artifact_paths=[
      @sdk_e1.high_control_command_artifact(command),
      config.command_path,
    ],
  )
  let response = @bridge_protocol.receipt_response(request, receipt)
  response_json(200, {
    ..response,
    message: @sdk_e1.high_control_command_summary(command),
    telemetry: Some(feedback),
  })
}

///|
fn emergency_stop_response(
  config : SdkE1BridgeConfig,
  profile : @core.RobotProfile,
  body : String,
) -> SdkE1BridgeHttpResponse {
  let request = match parse_bridge_request(profile, body) {
    Ok(request) => request
    Err(response) => return response
  }
  if request.operation != EmergencyStop {
    return response_json(
      400,
      @bridge_protocol.rejected_response(
        request, "emergency endpoint requires EmergencyStop",
      ),
    )
  }
  if config.read_only {
    return response_json(
      200,
      @bridge_protocol.rejected_response(
        request, "SDK E1 bridge is running in read-only mode",
      ),
    )
  }
  let command = @sdk_e1.emergency_stop_command(request.request_id)
  match persist_high_control_command(config, request, command) {
    Ok(_) => ()
    Err(response) => return response
  }
  let intent = @core.command_intent(
    command.intent_id,
    profile.id,
    command.capability,
    @core.operator_requester("emergency-stop"),
  )
  let snapshot = match
    snapshot_from_source(config, profile, request.issued_at_ms) {
    Ok(snapshot) => snapshot
    Err(response) => return response
  }
  let feedback = match
    @sdk_e1.command_feedback_frame(
      profile,
      snapshot,
      intent,
      frame_id="sdk-e1-command-feedback-\{intent.intent_id}-\{request.issued_at_ms}",
    ) {
    Ok(frame) => frame
    Err(issue) =>
      return response_json(
        500,
        @bridge_protocol.error_response(request, issue.message, [issue.code]),
      )
  }
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "emergency stop command bypasses normal task approval",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-\{request.request_id}-emergency-ready",
    profile.bridge.id,
    intent,
    verdict,
    request.issued_at_ms,
  )
  let receipt = @core.executed_receipt(
    "receipt-\{request.request_id}-emergency-executed",
    ready,
    request.issued_at_ms,
    telemetry_frame_count=1,
    artifact_paths=[
      @sdk_e1.high_control_command_artifact(command),
      config.command_path,
    ],
  )
  let response = @bridge_protocol.receipt_response(request, receipt)
  response_json(200, {
    ..response,
    message: @sdk_e1.high_control_command_summary(command),
    telemetry: Some(feedback),
  })
}

///|
pub fn route(
  config : SdkE1BridgeConfig,
  http_method : String,
  path : String,
  body : String,
  now_ms? : Int64 = 0L,
) -> SdkE1BridgeHttpResponse {
  let profile = match load_profile(config) {
    Ok(profile) => profile
    Err(response) => return response
  }
  match (http_method, path) {
    ("GET", "/health") => health_response(config, profile, now_ms)
    ("GET", "/metadata") => metadata_response(config, profile, now_ms)
    ("GET", "/capabilities") => capabilities_response(profile, now_ms)
    ("GET", "/telemetry/latest") => telemetry_response(config, profile, now_ms)
    ("POST", "/sessions/observe") =>
      session_response(
        profile,
        body,
        StartObserve,
        "observation session started",
      )
    ("POST", "/intents/execute") => execute_response(config, profile, body)
    ("POST", "/emergency/stop") =>
      emergency_stop_response(config, profile, body)
    _ =>
      match (http_method, session_id_from_stop_path(path)) {
        ("POST", Some(session_id)) =>
          session_response(
            profile,
            body,
            StopSession,
            "observation session stopped",
            path_session_id=session_id,
          )
        _ => issue_response(404, "not-found", "No SDK E1 bridge route")
      }
  }
}
