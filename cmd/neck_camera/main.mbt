///|
struct Camera {
  mut frame : Bytes?
  mut sequence : Int32
  mut updated : Int64
  mut fps : Int32
  mut window_start : Int64
  mut window_frames : Int32
}

///|
fn now() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
async fn capture_once(
  camera : Camera,
  ssh_socket : String,
  device : String,
) -> Unit {
  @async.with_task_group(group => {
    let (reader, output) = @process.read_from_process()
    defer reader.close()
    let child = @process.spawn(
      group,
      "ssh",
      [
        "-S",
        ssh_socket,
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "ServerAliveInterval=5",
        "-o",
        "ServerAliveCountMax=2",
        "elf@192.168.2.192",
        "ffmpeg -nostdin -hide_banner -loglevel error -f v4l2 -input_format yuyv422 -video_size 640x480 -framerate 15 -i \{device} -an -c:v mjpeg -q:v 5 -threads 1 -f image2pipe -flush_packets 1 pipe:1",
      ],
      stdout=output,
      no_wait=true,
    )
    let decoder = JpegDecoder::new()
    while reader.read_some(max_len=65536) is Some(chunk) {
      for frame in decoder.feed(chunk) {
        let now = now()
        camera.frame = Some(frame)
        camera.updated = now
        camera.sequence += 1
        camera.window_frames += 1
        if now - camera.window_start >= 1000L {
          camera.fps = (camera.window_frames.to_int64() *
          1000L /
          (now - camera.window_start)).to_int()
          camera.window_start = now
          camera.window_frames = 0
        }
      }
    }
    println("Camera capture exited: \{child.wait()}")
  })
}

///|
async fn send_bytes(
  conn : @http.ServerConnection,
  content_type : String,
  bytes : Bytes,
) -> Unit {
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": content_type,
    "Content-Length": bytes.length().to_string(),
  })
  conn.write(bytes)
  conn.end_response()
}

///|
async fn main {
  let args = @env.args()
  let ssh_socket = args
    .get(1)
    .unwrap_or("/tmp/moonrobo-elf2-neck-20261125.sock")
  let device = args
    .get(2)
    .unwrap_or(
      "/dev/v4l/by-id/usb-Intel_R__RealSense_TM__Depth_Camera_455_Intel_R__RealSense_TM__Depth_Camera_455_025523050943-video-index0",
    )
  // The path is passed through SSH's remote shell; accept only literal device paths.
  guard device.has_prefix("/dev/") &&
    device
    .iter()
    .all(c => {
      c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '/' | '_' | '-' | '.')
    }) else {
    abort("Camera device must be a literal /dev path")
  }
  let html = @fs.read_file("ui/rabbita-cockpit/public/neck-camera.html").binary()
  let camera : Camera = {
    frame: None,
    sequence: 0,
    updated: 0L,
    fps: 0,
    window_start: now(),
    window_frames: 0,
  }
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:4195"), headers={
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  })
  defer server.close()
  println("MoonRobo live camera: http://127.0.0.1:4195/")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        capture_once(camera, ssh_socket, device) catch {
          err => println("Camera reconnect: \{err}")
        }
        camera.fps = 0
        @async.sleep(2000)
      }
    })
    server.run_forever(allow_failure=true, (request, _body, conn) => {
      guard request.meth is Get else {
        conn.send_response(405, "Method Not Allowed")
        conn.end_response()
        return
      }
      let path = request.path.split("?").collect()[0].to_owned()
      match path {
        "/" | "/neck-camera.html" =>
          send_bytes(conn, "text/html; charset=utf-8", html)
        "/status" => {
          let age = if camera.updated == 0L {
            -1L
          } else {
            now() - camera.updated
          }
          let live = age >= 0L && age < 1500L
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "application/json",
          })
          conn.write_string(
            "{\"live\":\{live},\"sequence\":\{camera.sequence},\"frame_age_ms\":\{age},\"fps\":\{if live { camera.fps } else { 0 }}}",
          )
          conn.end_response()
        }
        "/snapshot.jpg" =>
          if camera.frame is Some(frame) && now() - camera.updated < 1500L {
            send_bytes(conn, "image/jpeg", frame)
          } else {
            conn.send_response(503, "Camera Unavailable")
            conn.end_response()
          }
        "/stream.mjpg" => {
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "multipart/x-mixed-replace; boundary=moonframe",
            "X-Accel-Buffering": "no",
          })
          conn.flush()
          let mut previous = -1
          let mut last_sent = now()
          for ;; {
            if camera.sequence != previous &&
              now() - camera.updated < 1500L &&
              camera.frame is Some(frame) {
              conn.write_string(
                "--moonframe\r\nContent-Type: image/jpeg\r\nContent-Length: \{frame.length()}\r\n\r\n",
              )
              conn.write(frame)
              conn.write_string("\r\n")
              conn.flush()
              previous = camera.sequence
              last_sent = now()
            }
            if now() - last_sent > 5000L {
              break
            }
            @async.sleep(20)
          }
          conn.write_string("--moonframe--\r\n")
          conn.end_response()
        }
        _ => {
          conn.send_response(404, "Not Found")
          conn.end_response()
        }
      }
    })
  })
}
