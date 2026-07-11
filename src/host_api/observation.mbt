///|
pub fn observation_start_path() -> String {
  "/api/sessions/observe"
}

///|
pub fn observation_stop_path(session_id : String) -> String {
  "/api/sessions/\{session_id}/stop"
}

///|
pub fn observation_frame_path(session_id : String) -> String {
  "/api/sessions/\{session_id}/frames"
}

///|
fn decode_observation_start(
  body : String,
  path : String,
) -> Result[@pipeline.ObservationStartRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-start",
        path,
        message: "failed to parse observation start JSON",
      })
  }
  let request : @pipeline.ObservationStartRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-start",
        path,
        message: "failed to decode observation start contract",
      })
  }
  Ok(request)
}

///|
fn decode_observation_stop(
  body : String,
  path : String,
) -> Result[@pipeline.ObservationStopRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-stop",
        path,
        message: "failed to parse observation stop JSON",
      })
  }
  let request : @pipeline.ObservationStopRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-stop",
        path,
        message: "failed to decode observation stop contract",
      })
  }
  Ok(request)
}

///|
fn decode_observation_frame(
  body : String,
  path : String,
) -> Result[@core.TelemetryFrame, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-frame",
        path,
        message: "failed to parse observation telemetry frame JSON",
      })
  }
  let frame : @core.TelemetryFrame = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-frame",
        path,
        message: "failed to decode observation telemetry frame contract",
      })
  }
  Ok(frame)
}

///|
pub fn observation_start_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_observation_start(body, observation_start_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  match @pipeline.start_observation(root, request) {
    Ok(response) => json_response(200, response.to_json())
    Err(error) => pipeline_error_response(error)
  }
}

///|
fn session_id_from_observation_stop_path(path : String) -> String? {
  let prefix = "/api/sessions/"
  let suffix = "/stop"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
fn session_id_from_observation_frame_path(path : String) -> String? {
  let prefix = "/api/sessions/"
  let suffix = "/frames"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
pub fn observation_frame_response(
  root : String,
  path : String,
  body : String,
) -> HostApiResponse {
  let session_id = match session_id_from_observation_frame_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No MoonRobo host API route",
      )
  }
  let frame = match decode_observation_frame(body, path) {
    Ok(frame) => frame
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  match @pipeline.ingest_observation_frame(root, session_id, frame) {
    Ok(response) => json_response(200, response.to_json())
    Err(error) => pipeline_error_response(error)
  }
}

///|
pub fn observation_stop_response(
  root : String,
  path : String,
  body : String,
) -> HostApiResponse {
  let session_id = match session_id_from_observation_stop_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No MoonRobo host API route",
      )
  }
  let request = match decode_observation_stop(body, path) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  match @pipeline.stop_observation(root, session_id, request) {
    Ok(response) => json_response(200, response.to_json())
    Err(error) => pipeline_error_response(error)
  }
}
