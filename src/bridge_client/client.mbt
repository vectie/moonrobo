///|
pub(all) struct BridgeClientConfig {
  host : String
  port : Int
  telemetry_path : String
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
  telemetry_path? : String = "/telemetry/latest",
) -> BridgeClientConfig {
  { host, port, telemetry_path }
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
fn to_ascii(text : String) -> Bytes {
  Bytes::makei(text.length(), index => text.unsafe_get(index).to_int().to_byte())
}

///|
fn host_header(config : BridgeClientConfig) -> String {
  "\{config.host}:\{config.port}"
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
async fn get_text(
  config : BridgeClientConfig,
) -> Result[String, BridgeClientIssue] {
  let host = if config.host == "localhost" { "127.0.0.1" } else { config.host }
  let conn = @socket.TCP::connect_to_host(to_ascii(host), port=config.port) catch {
    error =>
      return Err(
        issue(
          "bridge-connect-failed",
          bridge_base_url(config),
          "failed to connect to bridge sidecar: \{error}",
        ),
      )
  }
  defer conn.close()
  @http.send_request(
    conn,
    {
      meth: Get,
      path: to_ascii(config.telemetry_path),
      headers: [
        Header(b"Host", to_ascii(host_header(config))),
        Header(b"Connection", b"close"),
      ],
    },
    Empty,
  ) catch {
    error =>
      return Err(
        issue(
          "bridge-request-failed",
          config.telemetry_path,
          "failed to send bridge telemetry request: \{error}",
        ),
      )
  }
  let reader = @http.Reader::new(conn)
  let response = reader.read_response() catch {
    error =>
      return Err(
        issue(
          "bridge-response-failed",
          config.telemetry_path,
          "failed to read bridge telemetry response: \{error}",
        ),
      )
  }
  let body = reader.read_all() catch {
    error =>
      return Err(
        issue(
          "bridge-body-failed",
          config.telemetry_path,
          "failed to read bridge telemetry body: \{error}",
        ),
      )
  }
  let text = @utf8.decode_lossy(body)
  if response.code != 200 {
    Err(
      issue(
        "bridge-http-error",
        config.telemetry_path,
        "bridge returned HTTP \{response.code}: \{text}",
      ),
    )
  } else {
    Ok(text)
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
