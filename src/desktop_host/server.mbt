///|
pub struct Server {
  server : @socket.TCPServer
  port : Int
}

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
pub async fn Server::serve(self : Server, config : DesktopHostConfig) -> Unit {
  for ;; {
    let (conn, _) = self.server.accept()
    handle_connection(config, conn) catch {
      _ => conn.close()
    }
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
  reader.skip_body()
  handle_request(config, request, conn)
}

///|
async fn handle_request(
  config : DesktopHostConfig,
  request : @http.Request,
  conn : @socket.TCP,
) -> Unit {
  let path = strip_query(ascii_to_string(request.path))
  if path == readiness_path() {
    send_json(conn, request.meth, 200, "OK", health_json(config))
  } else if path == "/api" || path.has_prefix("/api/") {
    send_host_api_response(conn, request.meth, config.robotbook_root, path)
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
async fn send_host_api_response(
  conn : @socket.TCP,
  method_ : @http.RequestMethod,
  root : String,
  path : String,
) -> Unit {
  let routed_method = if method_ is Head { "GET" } else { method_text(method_) }
  let response = @host_api.route(root, routed_method, path)
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
