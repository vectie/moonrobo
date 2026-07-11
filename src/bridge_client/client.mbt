///|
pub(all) struct BridgeClientConfig {
  host : String
  port : Int
  contract_path : String
  telemetry_path : String
  execute_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeClientIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn config(
  host? : String = "127.0.0.1",
  port? : Int = 5391,
  contract_path? : String = "/contract",
  telemetry_path? : String = "/telemetry/latest",
  execute_path? : String = "/intents/execute",
) -> BridgeClientConfig {
  { host, port, contract_path, telemetry_path, execute_path }
}

///|
pub fn bridge_base_url(config : BridgeClientConfig) -> String {
  "http://\{config.host}:\{config.port}"
}

///|
fn issue(code : String, path : String, message : String) -> BridgeClientIssue {
  { code, path, message }
}

///|
pub fn telemetry_frame_from_body(
  body : String,
  path? : String = "/telemetry/latest",
) -> Result[@core.TelemetryFrame, BridgeClientIssue] {
  let bridge_response = match @bridge_protocol.parse_response(body) {
    Ok(value) => value
    Err(error) =>
      return Err(
        issue(
          error.code,
          path,
          "bridge telemetry response parse failed: \{error.message}",
        ),
      )
  }
  if bridge_response.status != Accepted {
    return Err(
      issue(
        "bridge-telemetry-rejected",
        path,
        @bridge_protocol.response_json(bridge_response),
      ),
    )
  }
  match bridge_response.telemetry {
    Some(frame) => Ok(frame)
    None =>
      Err(
        issue(
          "bridge-telemetry-missing", path, "bridge telemetry response did not include telemetry",
        ),
      )
  }
}

///|
pub fn sampled_telemetry_frame(
  frame : @core.TelemetryFrame,
  sample_id : String,
  index : Int,
) -> @core.TelemetryFrame {
  let operator_input : Map[String, String] = {}
  for key, value in frame.operator_input {
    operator_input[key] = value
  }
  operator_input["source"] = "sidecar-http"
  operator_input["source_frame_id"] = frame.frame_id
  {
    ..frame,
    frame_id: "sidecar-\{sample_id}-\{index}-\{frame.frame_id}",
    operator_input,
  }
}

///|
async fn request_text(
  config : BridgeClientConfig,
  method_ : @http.RequestMethod,
  path : String,
  body : String,
) -> Result[String, BridgeClientIssue] {
  let host = if config.host == "localhost" { "127.0.0.1" } else { config.host }
  let url = "http://\{host}:\{config.port}\{path}"
  let headers = { "Content-Type": "application/json; charset=utf-8" }
  let (response, response_body) = match method_ {
    Get | Head =>
      @http.get(url, headers~) catch {
        error =>
          return Err(
            issue(
              "bridge-request-failed",
              path,
              "failed to request bridge sidecar: \{error}",
            ),
          )
      }
    Post =>
      @http.post(url, body, headers~) catch {
        error =>
          return Err(
            issue(
              "bridge-request-failed",
              path,
              "failed to request bridge sidecar: \{error}",
            ),
          )
      }
    Put =>
      @http.put(url, body, headers~) catch {
        error =>
          return Err(
            issue(
              "bridge-request-failed",
              path,
              "failed to request bridge sidecar: \{error}",
            ),
          )
      }
    Delete | Connect | Options | Trace | Patch =>
      return Err(
        issue(
          "bridge-method-unsupported",
          path,
          "bridge client does not support HTTP method \{method_}",
        ),
      )
  }
  let text = response_body.text() catch {
    error =>
      return Err(
        issue(
          "bridge-body-failed",
          path,
          "failed to read bridge body: \{error}",
        ),
      )
  }
  if response.code != 200 {
    Err(
      issue(
        "bridge-http-error",
        path,
        "bridge returned HTTP \{response.code}: \{text}",
      ),
    )
  } else {
    Ok(text)
  }
}

///|
async fn get_text(
  config : BridgeClientConfig,
) -> Result[String, BridgeClientIssue] {
  request_text(config, Get, config.telemetry_path, "")
}

///|
async fn get_contract_text(
  config : BridgeClientConfig,
) -> Result[String, BridgeClientIssue] {
  request_text(config, Get, config.contract_path, "")
}

///|
pub fn bridge_response_from_body(
  body : String,
  path? : String = "/intents/execute",
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  match @bridge_protocol.parse_response(body) {
    Ok(response) => Ok(response)
    Err(error) =>
      Err(
        issue(
          error.code,
          path,
          "bridge response parse failed: \{error.message}",
        ),
      )
  }
}

///|
pub fn bridge_contract_from_body(
  body : String,
  path? : String = "/contract",
) -> Result[@bridge_protocol.BridgeContract, BridgeClientIssue] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        issue(
          "bridge-contract-parse-failed", path, "failed to parse bridge contract JSON",
        ),
      )
  }
  let contract : @bridge_protocol.BridgeContract = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "bridge-contract-decode-failed", path, "failed to decode bridge contract JSON",
        ),
      )
  }
  Ok(contract)
}

///|
pub fn execute_response_from_body(
  body : String,
  path? : String = "/intents/execute",
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  let response = match bridge_response_from_body(body, path~) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  if response.operation != ExecuteIntent {
    Err(
      issue(
        "bridge-execute-operation-mismatch", path, "bridge response operation was not ExecuteIntent",
      ),
    )
  } else {
    Ok(response)
  }
}

///|
pub async fn get_telemetry_frame_async(
  config : BridgeClientConfig,
) -> Result[@core.TelemetryFrame, BridgeClientIssue] {
  match get_text(config) {
    Ok(body) => telemetry_frame_from_body(body, path=config.telemetry_path)
    Err(error) => Err(error)
  }
}

///|
pub async fn get_bridge_contract_async(
  config : BridgeClientConfig,
) -> Result[@bridge_protocol.BridgeContract, BridgeClientIssue] {
  match get_contract_text(config) {
    Ok(body) => bridge_contract_from_body(body, path=config.contract_path)
    Err(error) => Err(error)
  }
}

///|
pub async fn post_bridge_request_async(
  config : BridgeClientConfig,
  request : @bridge_protocol.BridgeRequest,
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  let route = @bridge_protocol.route_for_request(request)
  if route.http_method != "POST" {
    return Err(
      issue(
        "bridge-post-route-mismatch",
        route.path,
        "bridge request does not map to a POST route",
      ),
    )
  }
  let body = match
    request_text(
      config,
      Post,
      route.path,
      @bridge_protocol.request_json(request),
    ) {
    Ok(body) => body
    Err(error) => return Err(error)
  }
  bridge_response_from_body(body, path=route.path)
}

///|
pub fn post_bridge_request(
  config : BridgeClientConfig,
  request : @bridge_protocol.BridgeRequest,
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  let results : Array[
    Result[@bridge_protocol.BridgeResponse, BridgeClientIssue],
  ] = []
  @async.with_event_loop(async fn(_group) {
    results.push(post_bridge_request_async(config, request))
  }) catch {
    error =>
      return Err(
        issue(
          "bridge-event-loop-failed",
          bridge_base_url(config),
          "bridge request event loop failed: \{error}",
        ),
      )
  }
  if results.is_empty() {
    Err(
      issue(
        "bridge-empty-result",
        bridge_base_url(config),
        "bridge request finished without a result",
      ),
    )
  } else {
    results[0]
  }
}

///|
pub fn post_execute_intent(
  config : BridgeClientConfig,
  request : @bridge_protocol.BridgeRequest,
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  if request.operation != ExecuteIntent {
    return Err(
      issue(
        "bridge-execute-operation-mismatch",
        config.execute_path,
        "bridge request operation was not ExecuteIntent",
      ),
    )
  }
  match post_bridge_request(config, request) {
    Ok(response) =>
      execute_response_from_body(
        @bridge_protocol.response_json(response),
        path=config.execute_path,
      )
    Err(error) => Err(error)
  }
}

///|
pub async fn post_execute_intent_async(
  config : BridgeClientConfig,
  request : @bridge_protocol.BridgeRequest,
) -> Result[@bridge_protocol.BridgeResponse, BridgeClientIssue] {
  if request.operation != ExecuteIntent {
    return Err(
      issue(
        "bridge-execute-operation-mismatch",
        config.execute_path,
        "bridge request operation was not ExecuteIntent",
      ),
    )
  }
  match post_bridge_request_async(config, request) {
    Ok(response) =>
      execute_response_from_body(
        @bridge_protocol.response_json(response),
        path=config.execute_path,
      )
    Err(error) => Err(error)
  }
}

///|
pub fn get_telemetry_frame(
  config : BridgeClientConfig,
) -> Result[@core.TelemetryFrame, BridgeClientIssue] {
  let results : Array[Result[@core.TelemetryFrame, BridgeClientIssue]] = []
  @async.with_event_loop(async fn(_group) {
    results.push(get_telemetry_frame_async(config))
  }) catch {
    error =>
      return Err(
        issue(
          "bridge-event-loop-failed",
          bridge_base_url(config),
          "bridge telemetry event loop failed: \{error}",
        ),
      )
  }
  if results.is_empty() {
    Err(
      issue(
        "bridge-empty-result",
        bridge_base_url(config),
        "bridge telemetry request finished without a result",
      ),
    )
  } else {
    results[0]
  }
}

///|
pub fn get_bridge_contract(
  config : BridgeClientConfig,
) -> Result[@bridge_protocol.BridgeContract, BridgeClientIssue] {
  let results : Array[
    Result[@bridge_protocol.BridgeContract, BridgeClientIssue],
  ] = []
  @async.with_event_loop(async fn(_group) {
    results.push(get_bridge_contract_async(config))
  }) catch {
    error =>
      return Err(
        issue(
          "bridge-event-loop-failed",
          bridge_base_url(config),
          "bridge contract event loop failed: \{error}",
        ),
      )
  }
  if results.is_empty() {
    Err(
      issue(
        "bridge-empty-result",
        bridge_base_url(config),
        "bridge contract request finished without a result",
      ),
    )
  } else {
    results[0]
  }
}
