///|
pub(all) enum BridgeOperation {
  Health
  Metadata
  Capabilities
  LatestTelemetry
  StartObserve
  StopSession
  DryRunIntent
  ExecuteIntent
  EmergencyStop
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum BridgeResponseStatus {
  Accepted
  Rejected
  Error
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeRoute {
  http_method : String
  path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeProtocolIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeRequest {
  request_id : String
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  operation : BridgeOperation
  issued_at_ms : Int64
  session_id : String?
  intent : @core.CommandIntent?
  parameters : Map[String, String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeResponse {
  request_id : String
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  operation : BridgeOperation
  status : BridgeResponseStatus
  message : String
  health : @core.BridgeHealth?
  metadata : @core.BridgeMetadata?
  capabilities : Array[@core.CapabilitySpec]
  telemetry : @core.TelemetryFrame?
  receipt : @core.RunReceipt?
  session_id : String?
  errors : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, message : String) -> BridgeProtocolIssue {
  { code, message }
}

///|
pub fn route_for_operation(operation : BridgeOperation) -> BridgeRoute {
  match operation {
    Health => { http_method: "GET", path: "/health" }
    Metadata => { http_method: "GET", path: "/metadata" }
    Capabilities => { http_method: "GET", path: "/capabilities" }
    LatestTelemetry => { http_method: "GET", path: "/telemetry/latest" }
    StartObserve => { http_method: "POST", path: "/sessions/observe" }
    StopSession => { http_method: "POST", path: "/sessions/{id}/stop" }
    DryRunIntent => { http_method: "POST", path: "/intents/dry-run" }
    ExecuteIntent => { http_method: "POST", path: "/intents/execute" }
    EmergencyStop => { http_method: "POST", path: "/emergency/stop" }
  }
}

///|
pub fn route_for_request(request : BridgeRequest) -> BridgeRoute {
  let route = route_for_operation(request.operation)
  match (request.operation, request.session_id) {
    (StopSession, Some(session_id)) =>
      { http_method: route.http_method, path: "/sessions/\{session_id}/stop" }
    _ => route
  }
}

///|
pub fn operation_requires_intent(operation : BridgeOperation) -> Bool {
  operation == DryRunIntent || operation == ExecuteIntent
}

///|
pub fn operation_mutates(operation : BridgeOperation) -> Bool {
  match operation {
    Health | Metadata | Capabilities | LatestTelemetry => false
    StartObserve | StopSession | DryRunIntent | ExecuteIntent | EmergencyStop =>
      true
  }
}

///|
pub fn bridge_request(
  request_id : String,
  profile : @core.RobotProfile,
  operation : BridgeOperation,
  issued_at_ms : Int64,
  session_id? : String,
  intent? : @core.CommandIntent,
  parameters? : Map[String, String] = {},
) -> BridgeRequest {
  {
    request_id,
    bridge_id: profile.bridge.id,
    robot_id: profile.id,
    operation,
    issued_at_ms,
    session_id,
    intent,
    parameters,
  }
}

///|
pub fn health_request(
  request_id : String,
  profile : @core.RobotProfile,
  issued_at_ms : Int64,
) -> BridgeRequest {
  bridge_request(request_id, profile, Health, issued_at_ms)
}

///|
pub fn telemetry_request(
  request_id : String,
  profile : @core.RobotProfile,
  issued_at_ms : Int64,
) -> BridgeRequest {
  bridge_request(request_id, profile, LatestTelemetry, issued_at_ms)
}

///|
pub fn dry_run_request(
  request_id : String,
  profile : @core.RobotProfile,
  intent : @core.CommandIntent,
  issued_at_ms : Int64,
) -> BridgeRequest {
  bridge_request(request_id, profile, DryRunIntent, issued_at_ms, intent~)
}

///|
pub fn execute_request(
  request_id : String,
  profile : @core.RobotProfile,
  intent : @core.CommandIntent,
  issued_at_ms : Int64,
) -> BridgeRequest {
  bridge_request(request_id, profile, ExecuteIntent, issued_at_ms, intent~)
}

///|
fn profile_has_capability(
  profile : @core.RobotProfile,
  capability_id : @core.CapabilityId,
) -> Bool {
  profile.capabilities.any(fn(capability) { capability.id == capability_id })
}

///|
pub fn validate_request(
  profile : @core.RobotProfile,
  request : BridgeRequest,
) -> Result[Unit, BridgeProtocolIssue] {
  if request.bridge_id != profile.bridge.id {
    return Err(
      issue("bridge-mismatch", "request bridge does not match profile"),
    )
  }
  if request.robot_id != profile.id {
    return Err(issue("robot-mismatch", "request robot does not match profile"))
  }
  if request.operation == StopSession && request.session_id is None {
    return Err(issue("session-missing", "stop-session requires session_id"))
  }
  match request.intent {
    None =>
      if operation_requires_intent(request.operation) {
        return Err(issue("intent-missing", "operation requires command intent"))
      }
    Some(intent) => {
      if intent.robot_id != profile.id {
        return Err(
          issue("intent-robot-mismatch", "intent robot does not match profile"),
        )
      }
      if !profile_has_capability(profile, intent.capability) {
        return Err(
          issue(
            "unsupported-capability", "profile does not expose intent capability",
          ),
        )
      }
    }
  }
  Ok(())
}

///|
pub fn bridge_metadata(profile : @core.RobotProfile) -> @core.BridgeMetadata {
  {
    bridge_id: profile.bridge.id,
    kind: profile.bridge.kind,
    label: "\{profile.label} bridge",
    protocol_version: 1,
    read_only: true,
  }
}

///|
fn base_response(
  request : BridgeRequest,
  status : BridgeResponseStatus,
  message : String,
) -> BridgeResponse {
  {
    request_id: request.request_id,
    bridge_id: request.bridge_id,
    robot_id: request.robot_id,
    operation: request.operation,
    status,
    message,
    health: None,
    metadata: None,
    capabilities: [],
    telemetry: None,
    receipt: None,
    session_id: request.session_id,
    errors: [],
  }
}

///|
pub fn health_response(
  request : BridgeRequest,
  health : @core.BridgeHealth,
) -> BridgeResponse {
  { ..base_response(request, Accepted, "bridge health"), health: Some(health) }
}

///|
pub fn metadata_response(
  request : BridgeRequest,
  metadata : @core.BridgeMetadata,
) -> BridgeResponse {
  {
    ..base_response(request, Accepted, "bridge metadata"),
    metadata: Some(metadata),
  }
}

///|
pub fn capabilities_response(
  request : BridgeRequest,
  capabilities : Array[@core.CapabilitySpec],
) -> BridgeResponse {
  { ..base_response(request, Accepted, "bridge capabilities"), capabilities, }
}

///|
pub fn telemetry_response(
  request : BridgeRequest,
  telemetry : @core.TelemetryFrame,
) -> BridgeResponse {
  {
    ..base_response(request, Accepted, "latest telemetry"),
    telemetry: Some(telemetry),
  }
}

///|
pub fn receipt_response(
  request : BridgeRequest,
  receipt : @core.RunReceipt,
) -> BridgeResponse {
  {
    ..base_response(request, Accepted, "bridge receipt"),
    receipt: Some(receipt),
  }
}

///|
pub fn rejected_response(
  request : BridgeRequest,
  message : String,
) -> BridgeResponse {
  base_response(request, Rejected, message)
}

///|
pub fn error_response(
  request : BridgeRequest,
  message : String,
  errors : Array[String],
) -> BridgeResponse {
  { ..base_response(request, Error, message), errors, }
}

///|
pub fn request_json(request : BridgeRequest, indent? : Int = 2) -> String {
  request.to_json().stringify(indent~)
}

///|
pub fn response_json(response : BridgeResponse, indent? : Int = 2) -> String {
  response.to_json().stringify(indent~)
}

///|
pub fn parse_request(
  text : String,
) -> Result[BridgeRequest, BridgeProtocolIssue] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(issue("parse-request", "failed to parse bridge request JSON"))
  }
  let request : BridgeRequest = @json.from_json(json) catch {
    _ => return Err(issue("decode-request", "failed to decode bridge request"))
  }
  Ok(request)
}

///|
pub fn parse_response(
  text : String,
) -> Result[BridgeResponse, BridgeProtocolIssue] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-response", "failed to parse bridge response JSON"),
      )
  }
  let response : BridgeResponse = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-response", "failed to decode bridge response"))
  }
  Ok(response)
}
