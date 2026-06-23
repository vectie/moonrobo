///|
struct Server {
  server : @socket.TCPServer
  port : Int
}

///|
fn cli_arg(args : Array[String], index : Int) -> String? {
  if index < args.length() {
    Some(args[index])
  } else {
    None
  }
}

///|
fn parse_port(text : String, fallback : Int) -> Int {
  @string.parse_int(text) catch {
    _ => fallback
  }
}

///|
fn default_host() -> String {
  "127.0.0.1"
}

///|
fn default_port() -> Int {
  5391
}

///|
fn strip_query(path : String) -> String {
  match path.find("?") {
    Some(index) => path[:index].to_owned()
    None => path
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
    _ => "Moonrobo SDK E1 Bridge Response"
  }
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
fn Server::new(host : String, port : Int) -> Server raise {
  let host = if host == "localhost" { "127.0.0.1" } else { host }
  let server = @socket.TCPServer::new(@socket.Addr::parse("\{host}:\{port}"))
  { server, port }
}

///|
async fn send_response(
  conn : @socket.TCP,
  method_ : @http.RequestMethod,
  response : @gateway.SdkE1BridgeHttpResponse,
) -> Unit {
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
async fn handle_connection(
  config : @gateway.SdkE1BridgeConfig,
  conn : @socket.TCP,
) -> Unit {
  defer conn.close()
  let reader = @http.Reader::new(conn)
  let request = reader.read_request()
  let body = read_request_body(reader, 65536)
  let routed_method = if request.meth is Head {
    "GET"
  } else {
    method_text(request.meth)
  }
  let response = @gateway.route(
    config,
    routed_method,
    strip_query(ascii_to_string(request.path)),
    body,
  )
  send_response(conn, request.meth, response)
}

///|
async fn serve_loop(
  server : Server,
  config : @gateway.SdkE1BridgeConfig,
  group : @async.TaskGroup[Unit],
) -> Unit {
  for ;; {
    let (conn, _) = server.server.accept()
    group.spawn_bg(allow_failure=true, async fn() {
      handle_connection(config, conn) catch {
        _ => conn.close()
      }
    })
  }
}

///|
fn serve(
  root : String,
  host : String,
  port : Int,
  snapshot_path : String,
) -> Unit {
  let server = Server::new(host, port) catch {
    error => {
      println("Moonrobo SDK E1 bridge failed to bind \{host}:\{port}: \{error}")
      return
    }
  }
  println("Moonrobo SDK E1 bridge: http://\{host}:\{server.port}/")
  println("RoboBook root: \{root}")
  if snapshot_path != "" {
    println("SDK snapshot source: \{snapshot_path}")
  }
  @async.with_event_loop(async fn(group) {
    serve_loop(server, @gateway.config(root, snapshot_path~), group)
  }) catch {
    error => println("Moonrobo SDK E1 bridge stopped: \{error}")
  }
}

///|
fn route_once(
  root : String,
  method_ : String,
  path : String,
  body : String,
  snapshot_path : String,
) -> Unit {
  let response = @gateway.route(
    @gateway.config(root, snapshot_path~),
    method_,
    path,
    body,
  )
  println(response.body)
}

///|
fn print_usage() -> Unit {
  println(
    "moon run cmd/sdk_e1_bridge -- serve [robobook-root] [host] [port] [snapshot-json]",
  )
  println(
    "moon run cmd/sdk_e1_bridge -- route [robobook-root] [method] [path] [body-json] [snapshot-json]",
  )
}

///|
fn main {
  let args = @sys.get_cli_args()
  let command = cli_arg(args, 1).unwrap_or("serve")
  let root = cli_arg(args, 2).unwrap_or("examples/noetix-e1")
  match command {
    "serve" => {
      let host = cli_arg(args, 3).unwrap_or(default_host())
      let port = parse_port(cli_arg(args, 4).unwrap_or(""), default_port())
      let snapshot_path = cli_arg(args, 5).unwrap_or("")
      serve(root, host, port, snapshot_path)
    }
    "route" => {
      let method_ = cli_arg(args, 3).unwrap_or("GET")
      let path = cli_arg(args, 4).unwrap_or("/health")
      let body = cli_arg(args, 5).unwrap_or("")
      let snapshot_path = cli_arg(args, 6).unwrap_or("")
      route_once(root, method_, path, body, snapshot_path)
    }
    "help" => print_usage()
    _ => {
      println("unknown Moonrobo SDK E1 bridge command: \{command}")
      print_usage()
    }
  }
}
