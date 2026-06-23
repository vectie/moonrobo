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
priv struct DesktopRuntimeLogResponse {
  active : Bool
  running : Bool
  status : String
  log_path : String
  exists : Bool
  truncated : Bool
  line_count : Int
  max_lines : Int
  max_chars : Int
  tail : String
} derive(ToJson)

///|
priv struct DesktopRuntimeValidationResponse {
  persisted : Bool
  report_path : String
  latest_report_path : String
  report : @runtime_validation.RuntimeValidationReport
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
  } else if http_method == "GET" && path == @host_api.runtime_log_path() {
    desktop_runtime_log_response(config)
  } else if http_method == "GET" && path == @host_api.runtime_validation_path() {
    desktop_runtime_validation_response(config)
  } else if http_method == "POST" &&
    path == @host_api.platform_first_loop_path() {
    desktop_platform_first_loop_response(config, body)
  } else if http_method == "POST" && path == @host_api.platform_task_loop_path() {
    desktop_platform_task_loop_response(config, body)
  } else if http_method == "POST" &&
    path == @host_api.platform_runtime_proof_path() {
    desktop_platform_runtime_proof_response(config)
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
async fn desktop_platform_runtime_proof_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match desktop_runtime_active_preflight(config) {
    None => ()
    Some(response) => return response
  }
  let client = desktop_bridge_client_config(config)
  let frame = match @bridge_client.get_telemetry_frame_async(client) {
    Ok(frame) => frame
    Err(issue) =>
      return desktop_json_response(502, {
        "code": issue.code,
        "path": issue.path,
        "message": issue.message,
      })
  }
  let snapshot = match
    @runtime_process.runtime_health_snapshot(
      config.robobook_root,
      telemetry_probe=Some(
        @runtime_process.telemetry_probe_from_frame(
          frame,
          path=client.telemetry_path,
        ),
      ),
    ) {
    Ok(snapshot) => snapshot
    Err(issue) => return desktop_runtime_process_error_response(issue)
  }
  let record = @runtime_process.runtime_health_record(snapshot)
  match @runtime.write_runtime_health(config.robobook_root, record) {
    Ok(_) => ()
    Err(issue) =>
      return desktop_json_response(500, {
        "code": issue.code,
        "path": issue.path,
        "message": issue.message,
      })
  }
  let request : @host_api.PlatformRuntimeProofRequest = { telemetry: frame }
  @host_api.platform_runtime_proof_response(
    config.robobook_root,
    request.to_json().stringify(),
  )
}

///|
fn desktop_first_loop_needs_runtime_proof(
  response : @host_api.HostApiResponse,
) -> Bool {
  if response.status != 409 {
    return false
  }
  let json = @json.parse(response.body) catch { _ => return false }
  let result : @host_api.PlatformFirstLoopResponse = @json.from_json(json) catch {
    _ => return false
  }
  result.stopped_reason == "advance-blocked" &&
  result.steps.any(step => step.stage == "runtime-required")
}

///|
fn desktop_decode_first_loop_request(
  body : String,
) -> Result[@host_api.PlatformFirstLoopRequest, @host_api.HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok({ task_id: "", max_steps: 6, allow_dispatch: false })
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        desktop_json_response(400, {
          "code": "parse-desktop-first-loop",
          "path": @host_api.platform_first_loop_path(),
          "message": "failed to parse desktop first-loop JSON",
        }),
      )
  }
  let request : @host_api.PlatformFirstLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        desktop_json_response(400, {
          "code": "decode-desktop-first-loop",
          "path": @host_api.platform_first_loop_path(),
          "message": "failed to decode desktop first-loop contract",
        }),
      )
  }
  Ok({
    task_id: request.task_id,
    max_steps: if request.max_steps < 1 {
      1
    } else if request.max_steps > 12 {
      12
    } else {
      request.max_steps
    },
    allow_dispatch: request.allow_dispatch,
  })
}

///|
fn desktop_safe_first_loop_body(
  request : @host_api.PlatformFirstLoopRequest,
) -> String {
  @host_api.PlatformFirstLoopRequest::{
    task_id: request.task_id,
    max_steps: request.max_steps,
    allow_dispatch: false,
  }
  .to_json()
  .stringify()
}

///|
fn desktop_decode_first_loop_response(
  response : @host_api.HostApiResponse,
) -> @host_api.PlatformFirstLoopResponse? {
  let json = @json.parse(response.body) catch { _ => return None }
  let result : @host_api.PlatformFirstLoopResponse = @json.from_json(json) catch {
    _ => return None
  }
  Some(result)
}

///|
fn desktop_first_loop_dispatch_ready(
  response : @host_api.HostApiResponse,
) -> Bool {
  match desktop_decode_first_loop_response(response) {
    Some(result) =>
      response.status == 409 &&
      result.stopped_reason == "dispatch-ready" &&
      result.steps.any(step => step.physical_execution_allowed)
    None => false
  }
}

///|
fn desktop_response_message(response : @host_api.HostApiResponse) -> String {
  let json = @json.parse(response.body) catch {
    _ => return "sidecar dispatch returned HTTP \{response.status}"
  }
  match json {
    { "message": String(message), .. } => message
    { "code": String(code), .. } => code
    _ => "sidecar dispatch returned HTTP \{response.status}"
  }
}

///|
fn desktop_first_loop_sidecar_step(
  task_id : String,
  response : @host_api.HostApiResponse,
) -> @host_api.PlatformFirstLoopStep {
  let advanced = response.status >= 200 && response.status < 300
  @host_api.PlatformFirstLoopStep::{
    step_id: "execute-sidecar",
    route: @host_api.moonbook_task_message_execute_sidecar_path(task_id),
    status: if advanced {
      "advanced"
    } else {
      "blocked"
    },
    http_status: response.status,
    message: if advanced {
      "dispatched reviewed task through supervised sidecar"
    } else {
      desktop_response_message(response)
    },
    stage: if advanced {
      "completed"
    } else {
      "ready-to-dispatch"
    },
    advanced,
    blocked: !advanced,
    physical_execution_allowed: true,
  }
}

///|
fn desktop_first_loop_dispatch_task_id(
  config : DesktopHostConfig,
  request : @host_api.PlatformFirstLoopRequest,
) -> Result[String, @host_api.HostApiResponse] {
  if request.task_id != "" {
    return Ok(request.task_id)
  }
  let response = @host_api.agent_next_action_response(config.robobook_root)
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        desktop_json_response(500, {
          "code": "parse-first-loop-next-action",
          "path": @host_api.agent_next_action_path(),
          "message": "failed to parse first-loop next action",
        }),
      )
  }
  let plan : @work_queue.AgentNextActionPlan = @json.from_json(json) catch {
    _ =>
      return Err(
        desktop_json_response(500, {
          "code": "decode-first-loop-next-action",
          "path": @host_api.agent_next_action_path(),
          "message": "failed to decode first-loop next action",
        }),
      )
  }
  match plan.action {
    Some(action) if action.kind == "execute-command-message" =>
      match task_id_from_execute_sidecar_path(action.route) {
        Some(task_id) => Ok(task_id)
        None =>
          Err(
            desktop_json_response(409, {
              "code": "first-loop-dispatch-route-missing",
              "path": action.route,
              "message": "ready first-loop action does not target execute-sidecar",
            }),
          )
      }
    Some(action) =>
      Err(
        desktop_json_response(409, {
          "code": "first-loop-dispatch-not-ready",
          "path": action.route,
          "message": "first-loop dispatch expected execute-command-message but selected \{action.kind}",
        }),
      )
    None =>
      Err(
        desktop_json_response(409, {
          "code": "first-loop-dispatch-no-action",
          "path": @host_api.agent_next_action_path(),
          "message": "first-loop dispatch found no selected task-message action",
        }),
      )
  }
}

///|
fn desktop_first_loop_dispatch_response(
  config : DesktopHostConfig,
  first : @host_api.HostApiResponse,
  request : @host_api.PlatformFirstLoopRequest,
  task_id : String,
  sidecar : @host_api.HostApiResponse,
) -> @host_api.HostApiResponse {
  let first_result = match desktop_decode_first_loop_response(first) {
    Some(result) => result
    None => return first
  }
  let steps : Array[@host_api.PlatformFirstLoopStep] = []
  for step in first_result.steps {
    steps.push(step)
  }
  steps.push(desktop_first_loop_sidecar_step(task_id, sidecar))
  let final_loop = @host_api.platform_first_loop_response(
    config.robobook_root,
    desktop_safe_first_loop_body(request),
  )
  let final_result = match desktop_decode_first_loop_response(final_loop) {
    Some(result) => result
    None => first_result
  }
  let advanced = sidecar.status >= 200 && sidecar.status < 300
  desktop_json_response(
    if advanced {
      200
    } else {
      sidecar.status
    },
    @host_api.PlatformFirstLoopResponse::{
      advanced: first_result.advanced || advanced,
      blocked: !advanced,
      stopped_reason: if advanced {
        "dispatched"
      } else {
        "sidecar-dispatch-blocked"
      },
      step_count: steps.length(),
      steps,
      readiness: final_result.readiness,
      readiness_plan: final_result.readiness_plan,
    }.to_json(),
  )
}

///|
async fn desktop_platform_first_loop_safe_response(
  config : DesktopHostConfig,
  body : String,
) -> @host_api.HostApiResponse {
  let first = @host_api.platform_first_loop_response(config.robobook_root, body)
  if !desktop_first_loop_needs_runtime_proof(first) {
    return first
  }
  let proof = desktop_platform_runtime_proof_response(config)
  if proof.status >= 200 && proof.status < 300 {
    @host_api.platform_first_loop_response(config.robobook_root, body)
  } else {
    first
  }
}

///|
async fn desktop_platform_first_loop_response(
  config : DesktopHostConfig,
  body : String,
) -> @host_api.HostApiResponse {
  let request = match desktop_decode_first_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let safe_body = desktop_safe_first_loop_body(request)
  let first = desktop_platform_first_loop_safe_response(config, safe_body)
  if !request.allow_dispatch || !desktop_first_loop_dispatch_ready(first) {
    return first
  }
  let task_id = match desktop_first_loop_dispatch_task_id(config, request) {
    Ok(task_id) => task_id
    Err(response) => return response
  }
  let sidecar = task_message_execute_sidecar_response(config, task_id)
  desktop_first_loop_dispatch_response(config, first, request, task_id, sidecar)
}

///|
async fn desktop_platform_task_loop_response(
  config : DesktopHostConfig,
  body : String,
) -> @host_api.HostApiResponse {
  let request = match @host_api.decode_platform_task_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let task_message_response = @host_api.moontown_task_message_response(
    config.robobook_root,
    request.task_message.to_json().stringify(),
  )
  if task_message_response.status < 200 || task_message_response.status >= 300 {
    return task_message_response
  }
  let json = @json.parse(task_message_response.body) catch {
    _ =>
      return desktop_json_response(500, {
        "code": "parse-desktop-task-loop-message",
        "path": @host_api.platform_task_loop_path(),
        "message": "task-message ingress returned invalid JSON",
      })
  }
  let task_message : @host_api.MoontownTaskMessageResponse = @json.from_json(
    json,
  ) catch {
    _ =>
      return desktop_json_response(500, {
        "code": "decode-desktop-task-loop-message",
        "path": @host_api.platform_task_loop_path(),
        "message": "task-message ingress returned an unexpected contract",
      })
  }
  let first_loop = desktop_platform_first_loop_response(
    config,
    @host_api.platform_task_loop_first_loop_body(
      request,
      task_message.message_plan.task.task_id,
      allow_dispatch=request.allow_dispatch,
    ),
  )
  @host_api.platform_task_loop_compose_response(
    task_message,
    first_loop,
    dispatch_requested=request.allow_dispatch,
  )
}

///|
fn bounded_runtime_log_tail(
  text : String,
  max_lines : Int,
  max_chars : Int,
) -> (String, Int, Bool) {
  let lines = text.split("\n").to_array()
  let selected : Array[String] = []
  let mut used_chars = 0
  let limit = if lines.length() < max_lines {
    lines.length()
  } else {
    max_lines
  }
  for offset in 0..<limit {
    let index = lines.length() - 1 - offset
    let line = lines[index].to_owned()
    let extra = line.length() + (if selected.is_empty() { 0 } else { 1 })
    if used_chars + extra <= max_chars {
      selected.insert(0, line)
      used_chars += extra
    } else {
      break
    }
  }
  let line_tail = selected.join("\n")
  (line_tail, lines.length(), selected.length() < lines.length())
}

///|
fn desktop_runtime_log_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  let max_lines = 80
  let max_chars = 12000
  match @runtime_process.read_active_run(config.robobook_root) {
    Ok(None) =>
      desktop_json_response(
        200,
        DesktopRuntimeLogResponse::{
          active: false,
          running: false,
          status: "not-running",
          log_path: "",
          exists: false,
          truncated: false,
          line_count: 0,
          max_lines,
          max_chars,
          tail: "",
        }.to_json(),
      )
    Ok(Some(run)) => {
      if run.log_path == "" || !@fsx.path_exists(run.log_path) {
        return desktop_json_response(
          200,
          DesktopRuntimeLogResponse::{
            active: true,
            running: run.running,
            status: run.status,
            log_path: run.log_path,
            exists: false,
            truncated: false,
            line_count: 0,
            max_lines,
            max_chars,
            tail: "",
          }.to_json(),
        )
      }
      let text = @fsx.read_file_to_string(run.log_path) catch {
        _ =>
          return desktop_json_response(500, {
            "code": "read-runtime-log",
            "path": run.log_path,
            "message": "failed to read runtime supervisor log",
          })
      }
      let (tail, line_count, truncated) = bounded_runtime_log_tail(
        text, max_lines, max_chars,
      )
      desktop_json_response(
        200,
        DesktopRuntimeLogResponse::{
          active: true,
          running: run.running,
          status: run.status,
          log_path: run.log_path,
          exists: true,
          truncated,
          line_count,
          max_lines,
          max_chars,
          tail,
        }.to_json(),
      )
    }
    Err(issue) => desktop_runtime_process_error_response(issue)
  }
}

///|
fn desktop_runtime_log_probe(config : DesktopHostConfig) -> (String, Bool) {
  match @runtime_process.read_active_run(config.robobook_root) {
    Ok(Some(run)) =>
      (run.log_path, run.log_path != "" && @fsx.path_exists(run.log_path))
    _ => ("", false)
  }
}

///|
async fn desktop_runtime_validation_response(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let plan = @supervisor.plan(
        desktop_physical_runtime_spec(config, book.profile),
      )
      let health = match desktop_runtime_health_snapshot(config) {
        Ok(snapshot) => Some(snapshot)
        Err(_) => None
      }
      let (log_path, log_exists) = desktop_runtime_log_probe(config)
      let report = @runtime_validation.validation_report(
        plan,
        desktop_now_ms(),
        health~,
        log_path~,
        log_exists~,
      )
      let path = match desktop_persist_runtime_validation(config, report) {
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
        DesktopRuntimeValidationResponse::{
          persisted: true,
          report_path: path,
          latest_report_path: @runtime.latest_runtime_validation_path(
            config.robobook_root,
          ),
          report,
        }.to_json(),
      )
    }
    Err(issue) => desktop_runtime_error_response(issue)
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
fn desktop_runtime_log_path(config : DesktopHostConfig) -> String {
  match
    @runtime_process.require_active_run(
      config.robobook_root,
      expected_bridge_base_url=@bridge_client.bridge_base_url(
        desktop_bridge_client_config(config),
      ),
    ) {
    Ok(run) => run.log_path
    Err(_) => ""
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
  match desktop_runtime_active_preflight(config) {
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
    runtime_log_path=desktop_runtime_log_path(config),
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
fn desktop_runtime_active_preflight(
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
fn desktop_runtime_health_issue_response(
  profile : @core.RobotProfile,
  snapshot : @runtime_process.RuntimeHealthSnapshot,
) -> @host_api.HostApiResponse? {
  if snapshot.status != "healthy" {
    return Some(
      desktop_json_response(409, {
        "code": "runtime-not-healthy",
        "path": @host_api.runtime_health_path(),
        "message": "runtime status \{snapshot.status} is not healthy; bridge telemetry must be reachable before task-message sidecar execution",
      }),
    )
  }
  if snapshot.robot_id != profile.id {
    return Some(
      desktop_json_response(409, {
        "code": "runtime-robot-mismatch",
        "path": @host_api.runtime_health_path(),
        "message": "runtime telemetry robot \{snapshot.robot_id} does not match selected RoboBook robot \{profile.id}",
      }),
    )
  }
  if snapshot.bridge_id != profile.bridge.id {
    return Some(
      desktop_json_response(409, {
        "code": "runtime-bridge-mismatch",
        "path": @host_api.runtime_health_path(),
        "message": "runtime telemetry bridge \{snapshot.bridge_id} does not match selected RoboBook bridge \{profile.bridge.id}",
      }),
    )
  }
  None
}

///|
fn desktop_persist_runtime_validation(
  config : DesktopHostConfig,
  report : @runtime_validation.RuntimeValidationReport,
) -> Result[String, @runtime.RuntimeIssue] {
  @runtime.write_runtime_validation_report(
    config.robobook_root,
    report.report_id,
    report.to_json().stringify(indent=2),
  )
}

///|
fn desktop_runtime_validation_block_response(
  report : @runtime_validation.RuntimeValidationReport,
  report_path : String,
) -> @host_api.HostApiResponse? {
  if report.ready_for_live_sdk {
    None
  } else {
    Some(
      desktop_json_response(409, {
        "code": "runtime-validation-blocked",
        "path": report_path,
        "message": "runtime validation is \{report.status}; live SDK readiness is required before task-message sidecar execution",
        "report": report.to_json(),
      }),
    )
  }
}

///|
async fn desktop_runtime_execution_preflight(
  config : DesktopHostConfig,
) -> @host_api.HostApiResponse? {
  match desktop_runtime_active_preflight(config) {
    None => ()
    Some(response) => return Some(response)
  }
  let book = match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => book
    Err(issue) => return Some(desktop_runtime_error_response(issue))
  }
  let snapshot = match desktop_runtime_health_snapshot(config) {
    Ok(snapshot) => snapshot
    Err(issue) => return Some(desktop_runtime_process_error_response(issue))
  }
  match desktop_runtime_health_issue_response(book.profile, snapshot) {
    None => ()
    Some(response) => return Some(response)
  }
  let plan = @supervisor.plan(
    desktop_physical_runtime_spec(config, book.profile),
  )
  let (log_path, log_exists) = desktop_runtime_log_probe(config)
  let report = @runtime_validation.validation_report(
    plan,
    desktop_now_ms(),
    health=Some(snapshot),
    log_path~,
    log_exists~,
  )
  match desktop_persist_runtime_validation(config, report) {
    Ok(report_path) =>
      desktop_runtime_validation_block_response(report, report_path)
    Err(issue) => Some(desktop_runtime_error_response(issue))
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
      runtime_log_path=desktop_runtime_log_path(config),
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
        runtime_log_path=execution.execution_snapshot.runtime_log_path,
        telemetry_frame_id=health.record.telemetry_frame_id,
        telemetry_captured_at_ms=health.record.telemetry_captured_at_ms,
        physical_feedback_path=health.record.telemetry_path,
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
