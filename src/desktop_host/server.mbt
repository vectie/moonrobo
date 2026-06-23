///|
pub struct Server {
  server : @socket.TCPServer
  port : Int
}

///|
priv struct DesktopTaskMessageSidecarResponse {
  persisted : Bool
  task_id : String
  message_path : String
  receipt_path : String
  dispatch_path : String
  execution_snapshot_path : String
  memory : @host_api.MoonBookMemoryResponse
  runtime_health : DesktopRuntimeHealthResponse?
  receipt : @core.RunReceipt
  bridge_request : @bridge_protocol.BridgeRequest
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
  execution_snapshot : @core.TaskExecutionSnapshot
  result : @pipeline.PipelineResult
} derive(ToJson)

///|
priv struct DesktopRuntimeHealthResponse {
  persisted : Bool
  runtime_health_path : String
  latest_runtime_health_path : String
  record : @runtime_health.RuntimeHealthRecord
  snapshot : @runtime_process.RuntimeHealthSnapshot
} derive(ToJson)

///|
priv struct DesktopEmergencyStopRequest {
  request_id : String?
  now_ms : Int64?
} derive(FromJson)

///|
priv struct DesktopEmergencyStopEvent {
  request_id : String
  now_ms : Int64
} derive(ToJson)

///|
priv struct DesktopEmergencyStopResponse {
  persisted : Bool
  event : DesktopEmergencyStopEvent
  receipt_path : String
  dispatch_path : String
  runtime_health : DesktopRuntimeHealthResponse?
  receipt : @core.RunReceipt
  bridge_request : @bridge_protocol.BridgeRequest
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
} derive(ToJson)

///|
pub fn Server::port(self : Server) -> Int {
  self.port
}

///|
pub fn Server::close(self : Server) -> Unit {
  self.server.close()
}

///|
pub fn Server::new(host : String, port : Int) -> Server raise {
  let host = if host == "localhost" { "127.0.0.1" } else { host }
  let server = @socket.TCPServer::new(@socket.Addr::parse("\{host}:\{port}"))
  { server, port }
}

///|
pub async fn Server::serve(
  self : Server,
  group : @async.TaskGroup[Unit],
  config : DesktopHostConfig,
) -> Unit {
  for ;; {
    let (conn, _) = self.server.accept()
    group.spawn_bg(allow_failure=true, async fn() {
      handle_connection(config, conn) catch {
        _ => conn.close()
      }
    })
  }
}

///|
async fn handle_connection(
  config : DesktopHostConfig,
  conn : @socket.TCP,
) -> Unit {
  defer conn.close()
  let reader = @http.Reader::new(conn)
  let request = reader.read_request()
  let body = read_request_body(reader, 65536)
  handle_request(config, request, conn, body)
}

///|
async fn handle_request(
  config : DesktopHostConfig,
  request : @http.Request,
  conn : @socket.TCP,
  body : String,
) -> Unit {
  let path = strip_query(ascii_to_string(request.path))
  if path == readiness_path() {
    send_json(conn, request.meth, 200, "OK", health_json(config))
  } else if path == "/api" || path.has_prefix("/api/") {
    send_desktop_api_response(conn, request.meth, config, path, body)
  } else {
    send_static_file(conn, request.meth, config.ui_root, path)
  }
}

///|
fn method_text(method_ : @http.RequestMethod) -> String {
  match method_ {
    Get | Head => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
fn reason_text(status : Int) -> String {
  match status {
    200 => "OK"
    400 => "Bad Request"
    404 => "Not Found"
    405 => "Method Not Allowed"
    409 => "Conflict"
    500 => "Internal Server Error"
    _ => "Moonrobo Response"
  }
}

///|
async fn send_desktop_api_response(
  conn : @socket.TCP,
  method_ : @http.RequestMethod,
  config : DesktopHostConfig,
  path : String,
  body : String,
) -> Unit {
  let routed_method = if method_ is Head { "GET" } else { method_text(method_) }
  let response = desktop_api_response(config, routed_method, path, body)
  let body = if method_ is Head { b"" } else { to_ascii(response.body) }
  @http.send_response(
    conn,
    {
      code: response.status,
      reason: to_ascii(reason_text(response.status)),
      headers: [
        Header(
          b"Content-Type",
          to_ascii(response.content_type + "; charset=utf-8"),
        ),
        Header(b"Connection", b"close"),
      ],
    },
    Fixed(body),
  )
}

///|
async fn desktop_api_response(
  config : DesktopHostConfig,
  http_method : String,
  path : String,
  body : String,
) -> @host_api.HostApiResponse {
  if http_method == "GET" && path == @host_api.bridge_sidecar_path() {
    desktop_bridge_sidecar_response(config)
  } else if http_method == "GET" && path == @host_api.runtime_supervisor_path() {
    desktop_runtime_supervisor_response(config)
  } else if http_method == "GET" &&
    path == @host_api.runtime_supervisor_script_path() {
    desktop_runtime_supervisor_script_response(config)
  } else if http_method == "POST" &&
    path == @host_api.runtime_supervisor_launch_path() {
    desktop_runtime_supervisor_launch_response(config)
  } else if http_method == "GET" &&
    path == @host_api.runtime_supervisor_run_path() {
    desktop_runtime_supervisor_run_response(config)
  } else if http_method == "GET" && path == @host_api.runtime_health_path() {
    desktop_runtime_health_response(config)
  } else if http_method == "POST" &&
    path == @host_api.runtime_supervisor_start_path() {
    desktop_runtime_supervisor_start_response(config)
  } else if http_method == "POST" &&
    path == @host_api.runtime_supervisor_stop_path() {
    desktop_runtime_supervisor_stop_response(config)
  } else if http_method == "POST" &&
    path == @host_api.runtime_emergency_stop_path() {
    desktop_runtime_emergency_stop_response(config, body)
  } else if http_method == "GET" &&
    @host_api.is_moonbook_task_message_status_path(path) {
    desktop_task_message_status_response(config, path)
  } else if http_method == "POST" &&
    task_id_from_execute_sidecar_path(path) is Some(task_id) {
    task_message_execute_sidecar_response(config, task_id)
  } else {
    @host_api.route_with_body(config.robobook_root, http_method, path, body)
  }
}

///|
fn desktop_json_response(
  status : Int,
  body : Json,
) -> @host_api.HostApiResponse {
  { status, content_type: "application/json", body: body.stringify(indent=2) }
}

///|
fn desktop_text_response(
  status : Int,
  body : String,
) -> @host_api.HostApiResponse {
  { status, content_type: "text/plain", body }
}

///|
fn desktop_runtime_error_response(
  issue : @runtime.RuntimeIssue,
) -> @host_api.HostApiResponse {
  desktop_json_response(500, {
    "code": issue.code,
    "path": issue.path,
    "message": issue.message,
  })
}

///|
fn desktop_command_available(command : Array[String]) -> Bool {
  !command.is_empty() && @fsx.path_exists(command[0])
}

///|
fn desktop_bridge_sidecar_spec(
  config : DesktopHostConfig,
  profile : @core.RobotProfile,
) -> @bridge_sidecar.BridgeSidecarSpec {
  @bridge_sidecar.spec_for_profile(
    profile,
    config.robobook_root,
    host=config.bridge_host,
    port=config.bridge_port,
  )
}

///|
fn desktop_physical_runtime_spec(
  config : DesktopHostConfig,
  profile : @core.RobotProfile,
) -> @bridge_sidecar.PhysicalRuntimeSpec {
  @bridge_sidecar.runtime_spec_for_profile(
    profile,
    config.robobook_root,
    host=config.bridge_host,
    port=config.bridge_port,
  )
}

///|
fn desktop_bridge_sidecar_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let spec = desktop_bridge_sidecar_spec(config, book.profile)
      desktop_json_response(200, {
        "spec": spec.to_json(),
        "status": @bridge_sidecar.status_for_spec(
          spec,
          desktop_command_available(spec.command),
        ).to_json(),
        "runtime": desktop_physical_runtime_spec(config, book.profile).to_json(),
      })
    }
    Err(issue) => desktop_runtime_error_response(issue)
  }
}

///|
fn desktop_runtime_supervisor_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) =>
      desktop_json_response(
        200,
        @supervisor.plan(desktop_physical_runtime_spec(config, book.profile)).to_json(),
      )
    Err(issue) => desktop_runtime_error_response(issue)
  }
}

///|
fn desktop_runtime_supervisor_script_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) =>
      desktop_text_response(
        200,
        @supervisor.shell_script(
          @supervisor.plan(desktop_physical_runtime_spec(config, book.profile)),
        ),
      )
    Err(issue) => desktop_runtime_error_response(issue)
  }
}

///|
fn desktop_runtime_supervisor_launch_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let plan = @supervisor.plan(
        desktop_physical_runtime_spec(config, book.profile),
      )
      match @runtime_launcher.prepare_launch(config.robobook_root, plan) {
        Ok(result) => desktop_json_response(200, result.to_json())
        Err(issue) =>
          desktop_json_response(issue.http_status, {
            "code": issue.code,
            "path": issue.path,
            "message": issue.message,
          })
      }
    }
    Err(issue) => desktop_runtime_error_response(issue)
  }
}

///|
fn desktop_runtime_process_error_response(
  issue : @pipeline.PipelineIssue,
) -> @host_api.HostApiResponse {
  desktop_json_response(issue.http_status, {
    "code": issue.code,
    "path": issue.path,
    "message": issue.message,
  })
}

///|
fn desktop_runtime_supervisor_run_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime_process.read_active_run(config.robobook_root) {
    Ok(Some(run)) =>
      desktop_json_response(200, {
        "active": true,
        "status": run.status,
        "pid": run.pid,
        "running": run.running,
        "run": run.to_json(),
      })
    Ok(None) =>
      desktop_json_response(200, {
        "active": false,
        "status": "not-running",
        "pid": 0,
        "running": false,
        "run": {},
      })
    Err(issue) => desktop_runtime_process_error_response(issue)
  }
}

///|
async fn desktop_runtime_health_snapshot(
  config : DesktopHostConfig,
) -> Result[@runtime_process.RuntimeHealthSnapshot, @pipeline.PipelineIssue] {
  match @runtime_process.read_active_run(config.robobook_root) {
    Ok(Some(run)) if run.running => {
      let client = desktop_bridge_client_config(config)
      let probe = match @bridge_client.get_telemetry_frame_async(client) {
        Ok(frame) =>
          @runtime_process.telemetry_probe_from_frame(
            frame,
            path=client.telemetry_path,
          )
        Err(issue) =>
          @runtime_process.telemetry_probe_from_error(
            issue.code,
            issue.path,
            issue.message,
          )
      }
      @runtime_process.runtime_health_snapshot(
        config.robobook_root,
        telemetry_probe=Some(probe),
      )
    }
    Ok(_) => @runtime_process.runtime_health_snapshot(config.robobook_root)
    Err(issue) => Err(issue)
  }
}

///|
async fn desktop_runtime_health_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match desktop_runtime_health_snapshot(config) {
    Ok(snapshot) => {
      let record = @runtime_process.runtime_health_record(snapshot)
      let path = match
        @runtime.write_runtime_health(config.robobook_root, record) {
        Ok(path) => path
        Err(issue) =>
          return desktop_json_response(500, {
            "code": issue.code,
            "path": issue.path,
            "message": issue.message,
          })
      }
      desktop_json_response(
        200,
        DesktopRuntimeHealthResponse::{
          persisted: true,
          runtime_health_path: path,
          latest_runtime_health_path: @runtime.latest_runtime_health_path(
            config.robobook_root,
          ),
          record,
          snapshot,
        }.to_json(),
      )
    }
    Err(issue) => desktop_runtime_process_error_response(issue)
  }
}

///|
fn desktop_runtime_supervisor_start_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let plan = @supervisor.plan(
        desktop_physical_runtime_spec(config, book.profile),
      )
      match @runtime_process.start_launch(config.robobook_root, plan) {
        Ok(run) => desktop_json_response(200, run.to_json())
        Err(issue) => desktop_runtime_process_error_response(issue)
      }
    }
    Err(issue) => desktop_runtime_error_response(issue)
  }
}

///|
fn desktop_runtime_supervisor_stop_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime_process.stop_active_run(config.robobook_root) {
    Ok(result) => desktop_json_response(200, result.to_json())
    Err(issue) => desktop_runtime_process_error_response(issue)
  }
}

///|
fn desktop_emergency_dispatch_id(
  request : @bridge_protocol.BridgeRequest,
) -> String {
  "dispatch-\{request.request_id}"
}

///|
fn desktop_now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn desktop_emergency_stop_event(
  body : String,
  fallback_now_ms : Int64,
) -> Result[DesktopEmergencyStopEvent, @host_api.HostApiResponse] {
  let empty : DesktopEmergencyStopRequest = { request_id: None, now_ms: None }
  let submitted = if body.trim().to_owned() == "" {
    empty
  } else {
    let json = @json.parse(body) catch {
      _ =>
        return Err(
          desktop_json_response(400, {
            "code": "parse-emergency-stop",
            "path": @host_api.runtime_emergency_stop_path(),
            "message": "failed to parse emergency stop JSON",
          }),
        )
    }
    let request : DesktopEmergencyStopRequest = @json.from_json(json) catch {
      _ =>
        return Err(
          desktop_json_response(400, {
            "code": "decode-emergency-stop",
            "path": @host_api.runtime_emergency_stop_path(),
            "message": "failed to decode emergency stop contract",
          }),
        )
    }
    request
  }
  let now_ms = match submitted.now_ms {
    Some(value) if value > 0L => value
    _ => fallback_now_ms
  }
  let request_id = match submitted.request_id {
    Some(value) if value.trim().to_owned() != "" => value
    _ => "request-emergency-stop-\{now_ms}"
  }
  Ok({ request_id, now_ms })
}

///|
fn desktop_bridge_response_status_label(
  status : @bridge_protocol.BridgeResponseStatus,
) -> String {
  match status {
    Accepted => "Accepted"
    Rejected => "Rejected"
    Error => "Error"
  }
}

///|
async fn desktop_persist_runtime_health(
  config : DesktopHostConfig,
) -> DesktopRuntimeHealthResponse? {
  match desktop_runtime_health_snapshot(config) {
    Ok(snapshot) => {
      let record = @runtime_process.runtime_health_record(snapshot)
      match @runtime.write_runtime_health(config.robobook_root, record) {
        Ok(path) =>
          Some(DesktopRuntimeHealthResponse::{
            persisted: true,
            runtime_health_path: path,
            latest_runtime_health_path: @runtime.latest_runtime_health_path(
              config.robobook_root,
            ),
            record,
            snapshot,
          })
        Err(_) => None
      }
    }
    Err(_) => None
  }
}

///|
async fn desktop_runtime_emergency_stop_response(
  config : DesktopHostConfig,
  body : String,
) -> @host_api.HostApiResponse {
  match desktop_runtime_execution_preflight(config) {
    None => ()
    Some(response) => return response
  }
  let book = match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => book
    Err(issue) => return desktop_runtime_error_response(issue)
  }
  let event = match desktop_emergency_stop_event(body, desktop_now_ms()) {
    Ok(event) => event
    Err(response) => return response
  }
  let request = @bridge_protocol.emergency_stop_request(
    event.request_id,
    book.profile,
    event.now_ms,
  )
  let bridge_response = match
    @bridge_client.post_bridge_request_async(
      desktop_bridge_client_config(config),
      request,
    ) {
    Ok(response) => response
    Err(issue) =>
      return desktop_json_response(502, {
        "code": issue.code,
        "path": issue.path,
        "message": issue.message,
      })
  }
  let receipt = match bridge_response.receipt {
    Some(receipt) => receipt
    None =>
      return desktop_json_response(502, {
        "code": "emergency-receipt-missing",
        "path": @host_api.runtime_emergency_stop_path(),
        "message": "bridge emergency response did not include a receipt",
      })
  }
  let route = @bridge_protocol.route_for_request(request)
  let dispatch = @core.bridge_dispatch_evidence(
    desktop_emergency_dispatch_id(request),
    request.request_id,
    request.bridge_id,
    request.robot_id,
    "EmergencyStop",
    route.http_method,
    route.path,
    receipt.intent.intent_id,
    receipt.receipt_id,
    desktop_bridge_response_status_label(bridge_response.status),
    bridge_response.message,
    event.now_ms,
  )
  let receipt_path = match
    @runtime.write_run_receipt(config.robobook_root, receipt) {
    Ok(path) => path
    Err(issue) =>
      return desktop_json_response(500, {
        "code": issue.code,
        "path": issue.path,
        "message": issue.message,
      })
  }
  let dispatch_path = match
    @runtime.write_bridge_dispatch_evidence(config.robobook_root, dispatch) {
    Ok(path) => path
    Err(issue) =>
      return desktop_json_response(500, {
        "code": issue.code,
        "path": issue.path,
        "message": issue.message,
      })
  }
  let runtime_health = desktop_persist_runtime_health(config)
  desktop_json_response(
    200,
    DesktopEmergencyStopResponse::{
      persisted: true,
      event,
      receipt_path,
      dispatch_path,
      runtime_health,
      receipt,
      bridge_request: request,
      bridge_response,
      bridge_dispatch: dispatch,
    }.to_json(),
  )
}

///|
async fn desktop_task_message_status_response(
  config : DesktopHostConfig,
  path : String,
) -> @host_api.HostApiResponse {
  let (runtime_status, runtime_bridge_base_url) = match
    desktop_runtime_health_snapshot(config) {
    Ok(snapshot) => (snapshot.status, snapshot.bridge_base_url)
    Err(_) => ("unknown", "")
  }
  @host_api.moonbook_task_message_status_response(
    config.robobook_root,
    path,
    runtime_status~,
    runtime_bridge_base_url~,
  )
}

///|
fn desktop_bridge_client_config(
  config : DesktopHostConfig,
) -> @bridge_client.BridgeClientConfig {
  @bridge_client.config(host=config.bridge_host, port=config.bridge_port)
}

///|
fn desktop_runtime_execution_preflight(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse? {
  match
    @runtime_process.require_active_run(
      config.robobook_root,
      expected_bridge_base_url=@bridge_client.bridge_base_url(
        desktop_bridge_client_config(config),
      ),
    ) {
    Ok(_) => None
    Err(issue) => Some(desktop_runtime_process_error_response(issue))
  }
}

///|
fn task_id_from_execute_sidecar_path(path : String) -> String? {
  let prefix = @host_api.moonbook_task_messages_path() + "/"
  let suffix = "/execute-sidecar"
  if path.has_prefix(prefix) && path.has_suffix(suffix) {
    let task_id = path[prefix.length():path.length() - suffix.length()].to_owned()
    if task_id == "" {
      None
    } else {
      Some(task_id)
    }
  } else {
    None
  }
}

///|
async fn task_message_execute_sidecar_response(
  config : DesktopHostConfig,
  task_id : String,
) -> @host_api.HostApiResponse {
  match desktop_runtime_execution_preflight(config) {
    None => ()
    Some(response) => return response
  }
  let execution = match
    @bridge_execution.execute_task_message_with_sidecar_async(
      config.robobook_root,
      task_id,
      desktop_bridge_client_config(config),
    ) {
    Ok(result) => result
    Err(issue) =>
      return {
        status: 500,
        content_type: "application/json",
        body: issue.to_json().stringify(indent=2),
      }
  }
  let runtime_health = match desktop_runtime_health_snapshot(config) {
    Ok(snapshot) => {
      let record = @runtime_process.runtime_health_record(snapshot)
      match @runtime.write_runtime_health(config.robobook_root, record) {
        Ok(path) =>
          Some(DesktopRuntimeHealthResponse::{
            persisted: true,
            runtime_health_path: path,
            latest_runtime_health_path: @runtime.latest_runtime_health_path(
              config.robobook_root,
            ),
            record,
            snapshot,
          })
        Err(_) => None
      }
    }
    Err(_) => None
  }
  let execution_snapshot = match runtime_health {
    Some(health) => {
      let snapshot = @core.task_execution_snapshot(
        execution.execution_snapshot.snapshot_id,
        task_id,
        execution.message_path,
        execution.receipt_path,
        execution.dispatch_path,
        execution.memory.memory_path,
        execution.receipt,
        execution.bridge_dispatch,
        execution.execution_snapshot.captured_at_ms,
        runtime_health_path=health.runtime_health_path,
        runtime_status=health.record.status,
        runtime_health_persisted=true,
      )
      match
        @runtime.write_task_execution_snapshot(config.robobook_root, snapshot) {
        Ok(_) => snapshot
        Err(_) => execution.execution_snapshot
      }
    }
    None => execution.execution_snapshot
  }
  let execution_snapshot_path = @runtime.task_execution_snapshot_path(
    config.robobook_root,
    execution_snapshot.snapshot_id,
  )
  {
    status: 200,
    content_type: "application/json",
    body: DesktopTaskMessageSidecarResponse::{
      persisted: true,
      task_id,
      message_path: execution.message_path,
      receipt_path: execution.receipt_path,
      dispatch_path: execution.dispatch_path,
      execution_snapshot_path,
      memory: execution.memory,
      runtime_health,
      receipt: execution.receipt,
      bridge_request: execution.bridge_request,
      bridge_response: execution.bridge_response,
      bridge_dispatch: execution.bridge_dispatch,
      execution_snapshot,
      result: execution.result,
    }
    .to_json()
    .stringify(indent=2),
  }
}

///|
async fn send_json(
  conn : @socket.TCP,
  method_ : @http.RequestMethod,
  status : Int,
  reason : String,
  body : Json,
) -> Unit {
  @http.send_response(
    conn,
    {
      code: status,
      reason: to_ascii(reason),
      headers: [
        Header(b"Content-Type", b"application/json; charset=utf-8"),
        Header(b"Connection", b"close"),
      ],
    },
    Fixed(
      if method_ is Head {
        b""
      } else {
        to_ascii(body.stringify(indent=2))
      },
    ),
  )
}

///|
async fn send_text_status(
  conn : @socket.TCP,
  status : Int,
  reason : String,
  body : String,
) -> Unit {
  @http.send_response(
    conn,
    {
      code: status,
      reason: to_ascii(reason),
      headers: [
        Header(b"Content-Type", b"text/plain; charset=utf-8"),
        Header(b"Connection", b"close"),
      ],
    },
    Fixed(to_ascii(body)),
  )
}

///|
async fn send_static_file(
  conn : @socket.TCP,
  method_ : @http.RequestMethod,
  ui_root : String,
  path : String,
) -> Unit {
  guard method_ is Get || method_ is Head else {
    send_text_status(conn, 405, "Method Not Allowed", "Method Not Allowed\n")
    return
  }
  let requested = match resolve_static_request_path(ui_root, path) {
    Some(file_path) => file_path
    None => {
      send_text_status(conn, 400, "Bad Request", "Bad Request\n")
      return
    }
  }
  let file_path = if @fsx.path_exists(requested) {
    requested
  } else if !request_has_file_extension(path) &&
    @fsx.path_exists(fallback_index_path(ui_root)) {
    fallback_index_path(ui_root)
  } else {
    send_text_status(conn, 404, "Not Found", "Not Found\n")
    return
  }
  let body = if method_ is Head {
    b""
  } else {
    @fsx.read_file_to_bytes(file_path) catch {
      _ => {
        send_text_status(conn, 404, "Not Found", "Not Found\n")
        return
      }
    }
  }
  @http.send_response(
    conn,
    {
      code: 200,
      reason: b"OK",
      headers: [
        Header(b"Content-Type", to_ascii(content_type(file_path))),
        Header(b"Connection", b"close"),
      ],
    },
    Fixed(body),
  )
}

///|
async fn read_request_body(reader : @http.Reader, limit : Int) -> String {
  let bytes : Array[Byte] = []
  let buf = FixedArray::make(1024, b'\x00')
  for ;; {
    let remaining = limit - bytes.length()
    if remaining <= 0 {
      reader.skip_body()
      break
    }
    let max_len = if remaining < buf.length() {
      remaining
    } else {
      buf.length()
    }
    let n = reader.read(buf, max_len~)
    if n <= 0 {
      break
    }
    for index in 0..<n {
      bytes.push(buf[index])
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
fn to_ascii(text : String) -> Bytes {
  Bytes::makei(text.length(), index => text.unsafe_get(index).to_int().to_byte())
}

///|
fn ascii_to_string(bytes : Bytes) -> String {
  let builder = StringBuilder::new()
  for byte in bytes {
    builder.write_char(byte.to_int().unsafe_to_char())
  }
  builder.to_string()
}
