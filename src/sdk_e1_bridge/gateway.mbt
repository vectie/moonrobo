///|
pub(all) struct SdkE1BridgeConfig {
  robotbook_root : String
  read_only : Bool
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
  robotbook_root : String,
  read_only? : Bool = true,
) -> SdkE1BridgeConfig {
  { robotbook_root, read_only }
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
  match @runtime.load_robotbook(config.robotbook_root) {
    Ok(book) => Ok(book.profile)
    Err(issue) => Err(issue_response(500, issue.code, issue.message))
  }
}

///|
fn snapshot(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> @sdk_e1.SdkE1Snapshot {
  {
    ..@sdk_e1.default_snapshot("sdk-e1-sidecar-\{now_ms}", now_ms),
    joints: @sdk_e1.default_joint_states(profile),
  }
}

///|
fn request_id(prefix : String, now_ms : Int64) -> String {
  "\{prefix}-\{now_ms}"
}

///|
fn health_response(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  response_json(
    200,
    @sdk_e1.health_response(
      request_id("request-sidecar-health", now_ms),
      profile,
      snapshot(profile, now_ms),
    ),
  )
}

///|
fn metadata_response(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  response_json(
    200,
    @bridge_protocol.metadata_response(
      @bridge_protocol.bridge_request(
        request_id("request-sidecar-metadata", now_ms),
        profile,
        Metadata,
        now_ms,
      ),
      @bridge_protocol.bridge_metadata(profile),
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
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> SdkE1BridgeHttpResponse {
  match
    @sdk_e1.telemetry_response(
      request_id("request-sidecar-telemetry", now_ms),
      profile,
      snapshot(profile, now_ms),
    ) {
    Ok(response) => response_json(200, response)
    Err(issue) => issue_response(500, issue.code, issue.message)
  }
}

///|
fn execute_response(
  profile : @core.RobotProfile,
  body : String,
) -> SdkE1BridgeHttpResponse {
  let request = match @bridge_protocol.parse_request(body) {
    Ok(request) => request
    Err(issue) => return issue_response(400, issue.code, issue.message)
  }
  match @bridge_protocol.validate_request(profile, request) {
    Err(issue) =>
      return response_json(
        400,
        @bridge_protocol.error_response(request, "invalid bridge request", [
          issue.message,
        ]),
      )
    Ok(_) => ()
  }
  if request.operation != ExecuteIntent {
    return response_json(
      400,
      @bridge_protocol.rejected_response(
        request, "execute endpoint requires ExecuteIntent",
      ),
    )
  }
  response_json(
    200,
    @bridge_protocol.rejected_response(
      request, "SDK E1 bridge scaffold is read-only until supervised control transport is enabled",
    ),
  )
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
    ("GET", "/health") => health_response(profile, now_ms)
    ("GET", "/metadata") => metadata_response(profile, now_ms)
    ("GET", "/capabilities") => capabilities_response(profile, now_ms)
    ("GET", "/telemetry/latest") => telemetry_response(profile, now_ms)
    ("POST", "/intents/execute") => execute_response(profile, body)
    _ => issue_response(404, "not-found", "No SDK E1 bridge route")
  }
}
