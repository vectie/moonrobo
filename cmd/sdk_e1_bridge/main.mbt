///|
struct Server {
  server : @http.Server
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
async fn read_request_body(reader : &@io.Reader, limit : Int) -> String {
  let bytes : Array[Byte] = []
  let buf = FixedArray::make(1024, b'\x00')
  for ;; {
    let remaining = limit - bytes.length()
    if remaining <= 0 {
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
  let server = @http.Server::new(@socket.Addr::parse("\{host}:\{port}"))
  { server, port }
}

///|
async fn send_response(
  conn : @http.ServerConnection,
  method_ : @http.RequestMethod,
  response : @gateway.SdkE1BridgeHttpResponse,
) -> Unit {
  conn.send_response(response.status, reason_text(response.status), extra_headers={
    "Content-Type": response.content_type + "; charset=utf-8",
  })
  if !(method_ is Head) {
    conn.write(response.body)
  }
  conn.end_response()
}

///|
async fn handle_connection(
  config : @gateway.SdkE1BridgeConfig,
  request : @http.Request,
  body_reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let body = read_request_body(body_reader, 65536)
  let routed_method = if request.meth is Head {
    "GET"
  } else {
    method_text(request.meth)
  }
  let response = @gateway.route(
    config,
    routed_method,
    strip_query(request.path),
    body,
  )
  send_response(conn, request.meth, response)
}

///|
async fn serve_loop(
  server : Server,
  config : @gateway.SdkE1BridgeConfig,
) -> Unit {
  server.server.run_forever(
    async fn(request, body_reader, conn) {
      handle_connection(config, request, body_reader, conn)
    },
    allow_failure=true,
  )
}

///|
fn serve(
  root : String,
  host : String,
  port : Int,
  snapshot_path : String,
  read_only : Bool,
  command_path : String,
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
  if !read_only {
    println("SDK E1 high-control execution: control-gated")
    println("SDK E1 command output: \{command_path}")
  }
  @async.with_event_loop(async fn(_group) {
    serve_loop(
      server,
      @gateway.config(root, read_only~, snapshot_path~, command_path~),
    )
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
  read_only : Bool,
  command_path : String,
) -> Unit {
  let response = @gateway.route(
    @gateway.config(root, read_only~, snapshot_path~, command_path~),
    method_,
    path,
    body,
  )
  println(response.body)
}

///|
fn print_usage() -> Unit {
  println(
    "moon run cmd/sdk_e1_bridge -- serve [robobook-root] [host] [port] [snapshot-json] [read-only|control-gated] [command-json]",
  )
  println(
    "moon run cmd/sdk_e1_bridge -- route [robobook-root] [method] [path] [body-json] [snapshot-json] [read-only|control-gated] [command-json]",
  )
}

///|
fn read_only_from_mode(mode : String) -> Bool {
  mode != "control-gated"
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
      let read_only = read_only_from_mode(cli_arg(args, 6).unwrap_or(""))
      let command_path = cli_arg(args, 7).unwrap_or("")
      serve(root, host, port, snapshot_path, read_only, command_path)
    }
    "route" => {
      let method_ = cli_arg(args, 3).unwrap_or("GET")
      let path = cli_arg(args, 4).unwrap_or("/health")
      let body = cli_arg(args, 5).unwrap_or("")
      let snapshot_path = cli_arg(args, 6).unwrap_or("")
      let read_only = read_only_from_mode(cli_arg(args, 7).unwrap_or(""))
      let command_path = cli_arg(args, 8).unwrap_or("")
      route_once(
        root, method_, path, body, snapshot_path, read_only, command_path,
      )
    }
    "help" => print_usage()
    _ => {
      println("unknown Moonrobo SDK E1 bridge command: \{command}")
      print_usage()
    }
  }
}
