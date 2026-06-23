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
  receipt : @core.RunReceipt
  bridge_request : @bridge_protocol.BridgeRequest
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
  result : @pipeline.PipelineResult
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
  if http_method == "POST" &&
    task_id_from_execute_sidecar_path(path) is Some(task_id) {
    task_message_execute_sidecar_response(config, task_id)
  } else {
    @host_api.route_with_body(config.robobook_root, http_method, path, body)
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
  let execution = match
    @bridge_execution.execute_task_message_with_sidecar_async(
      config.robobook_root,
      task_id,
      @bridge_client.config(host=config.bridge_host, port=config.bridge_port),
    ) {
    Ok(result) => result
    Err(issue) =>
      return {
        status: 500,
        content_type: "application/json",
        body: issue.to_json().stringify(indent=2),
      }
  }
  {
    status: 200,
    content_type: "application/json",
    body: DesktopTaskMessageSidecarResponse::{
      persisted: true,
      task_id,
      message_path: execution.message_path,
      receipt_path: execution.receipt_path,
      dispatch_path: execution.dispatch_path,
      receipt: execution.receipt,
      bridge_request: execution.bridge_request,
      bridge_response: execution.bridge_response,
      bridge_dispatch: execution.bridge_dispatch,
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
