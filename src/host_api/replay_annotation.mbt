///|
pub(all) struct ReplayAnnotationRequest {
  annotation_id : String
  frame_id : String
  label : String
  note : String
  severity : String
  requester : @core.Requester
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReplayAnnotationResponse {
  persisted : Bool
  annotation_path : String
  annotation : @annotation.ReplayAnnotation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReplayAnnotationListResponse {
  session_id : String
  annotation_count : Int
  annotations : Array[@annotation.ReplayAnnotation]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn replay_annotations_path(session_id : String) -> String {
  "\{replay_path(session_id)}/annotations"
}

///|
pub fn replay_annotation_path(
  session_id : String,
  annotation_id : String,
) -> String {
  "\{replay_annotations_path(session_id)}/\{annotation_id}"
}

///|
fn split_replay_annotation_path(path : String) -> (String, String)? {
  let prefix = "/api/replays/"
  if !path.has_prefix(prefix) {
    return None
  }
  let rest = path[prefix.length():path.length()]
  match rest.split_once("/annotations/") {
    Some((session_id, annotation_id)) =>
      if session_id.length() > 0 && annotation_id.length() > 0 {
        Some((session_id.to_owned(), annotation_id.to_owned()))
      } else {
        None
      }
    None => None
  }
}

///|
fn session_id_from_replay_annotations_path(path : String) -> String? {
  let prefix = "/api/replays/"
  let suffix = "/annotations"
  if path.has_prefix(prefix) &&
    path.has_suffix(suffix) &&
    path.length() > prefix.length() + suffix.length() {
    Some(path[prefix.length():path.length() - suffix.length()].to_owned())
  } else {
    None
  }
}

///|
fn replay_annotation_id_from_path(path : String) -> (String, String)? {
  split_replay_annotation_path(path)
}

///|
fn default_annotation_request(session_id : String) -> ReplayAnnotationRequest {
  {
    annotation_id: "annotation-\{session_id}-0",
    frame_id: "",
    label: "usable",
    note: "operator marked replay evidence usable",
    severity: "info",
    requester: @core.operator_requester("host-api"),
    created_at_ms: 0L,
  }
}

///|
fn decode_replay_annotation_request(
  body : String,
  path : String,
  session_id : String,
) -> Result[ReplayAnnotationRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_annotation_request(session_id))
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400, "parse-replay-annotation", path, "failed to parse replay annotation JSON",
        ),
      )
  }
  let request : ReplayAnnotationRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400, "decode-replay-annotation", path, "failed to decode replay annotation contract",
        ),
      )
  }
  Ok(request)
}

///|
fn annotation_from_request(
  session_id : String,
  request : ReplayAnnotationRequest,
) -> @annotation.ReplayAnnotation {
  @annotation.replay_annotation(
    request.annotation_id,
    session_id,
    request.frame_id,
    request.label,
    request.note,
    request.severity,
    request.requester,
    request.created_at_ms,
  )
}

///|
pub fn replay_annotations_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let session_id = match session_id_from_replay_annotations_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  match @runtime.list_replay_annotations(root, session_id) {
    Ok(annotations) =>
      json_response(
        200,
        { session_id, annotation_count: annotations.length(), annotations }.to_json(),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn replay_annotation_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let (session_id, annotation_id) = match replay_annotation_id_from_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  match @runtime.read_replay_annotation(root, session_id, annotation_id) {
    Ok(annotation) => json_response(200, annotation.to_json())
    Err(issue) => error_response(400, issue.code, issue.path, issue.message)
  }
}

///|
pub fn replay_annotation_submission_response(
  root : String,
  path : String,
  body : String,
) -> HostApiResponse {
  let session_id = match session_id_from_replay_annotations_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let _session = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  let request = match decode_replay_annotation_request(body, path, session_id) {
    Ok(value) => value
    Err(response) => return response
  }
  let annotation = annotation_from_request(session_id, request)
  let annotation_path = match
    @runtime.write_replay_annotation(root, annotation) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(200, { persisted: true, annotation_path, annotation }.to_json())
}
