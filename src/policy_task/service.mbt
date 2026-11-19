///|
/// HTTP stays outside the synchronous supervisor and actor tick.
/// The clock is local to the Atlas host; clients use the advertised time.
pub struct Service {
  priv supervisor : @skills.Supervisor
  priv clock : () -> Int64
}

///|
pub fn Service::new(
  supervisor : @skills.Supervisor,
  clock : () -> Int64,
) -> Service {
  { supervisor, clock, }
}

///|
pub(all) struct Reply {
  code : Int32
  body : Json
}

///|
/// Synchronous dispatch can also be embedded in another transport.
/// Start/finish are deliberately local runner operations, not HTTP endpoints.
pub fn Service::dispatch(
  self : Service,
  verb : String,
  path : String,
  body : Json,
) -> Reply {
  let now = (self.clock)()
  let execution = self.supervisor.snapshot(now)
  try {
    match (verb, path) {
      ("GET", "/v1/catalog") =>
        {
          code: 200,
          body: {
            "now_ms": Json(now),
            "catalog": Json(self.supervisor.catalog()),
          },
        }
      ("GET", "/v1/state") =>
        {
          code: 200,
          body: {
            "now_ms": Json(now),
            "context_version": Json(self.supervisor.version()),
            "execution": match execution {
              Some(e) => Json(e)
              None => Json::null()
            },
          },
        }
      ("POST", "/v1/skills") => {
        let request : @skills.Request = @json.from_json(body)
        { code: 200, body: Json(self.supervisor.accept(request, now)), }
      }
      ("POST", "/v1/cancel") => {
        guard body is { "request_id": String(id), .. } else {
          return { code: 400, body: { "error": "request_id is required" }, }
        }
        {
          code: 200,
          body: Json(
            self.supervisor.cancel(id, detail="task coordinator cancellation"),
          ),
        }
      }
      _ => { code: 404, body: { "error": "unknown task endpoint" }, }
    }
  } catch {
    @skills.SkillError::Rejected(reason) =>
      { code: 409, body: { "error": Json(reason) }, }
    _ => { code: 400, body: { "error": "invalid task request" }, }
  }
}

///|
pub async fn Service::serve(self : Service, server : @http.Server) -> Unit {
  server.run_forever() <| ((request, body, connection) => {
    let payload = if request.meth is Post {
      body.read_all().json() catch {
        error => {
          if @async.is_cancellation_error(error) {
            raise error
          }
          connection.send_response(400, "Bad Request")
          connection.write_string("{\"error\":\"invalid JSON\"}")
          connection.end_response()
          return
        }
      }
    } else {
      Json::null()
    }
    let verb = match request.meth {
      Get => "GET"
      Post => "POST"
      _ => "OTHER"
    }
    let reply = self.dispatch(verb, request.path, payload)
    let reason = match reply.code {
      200 => "OK"
      400 => "Bad Request"
      409 => "Conflict"
      _ => "Not Found"
    }
    connection.send_response(reply.code, reason, extra_headers={
      "Content-Type": "application/json",
    })
    connection.write_string(reply.body.stringify())
    connection.end_response()
  })
}
