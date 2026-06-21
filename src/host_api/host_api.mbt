///|
pub(all) struct HostApiResponse {
  status : Int
  content_type : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostApiError {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostApiHealth {
  service : String
  robotbook_root : String
  status : String
  snapshot_path : String
  read_only : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntentSubmissionRequest {
  intent_id : String
  robot_id : String
  capability : String
  parameters : Map[String, String]
  requester : @core.Requester
  receipt_id : String
  now_ms : Int64
  approval_id : String
  dry_run_receipt_id : String
  developer_gate : Bool
  telemetry_age_ms : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntentSubmissionResponse {
  persisted : Bool
  receipt_path : String
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn snapshot_path() -> String {
  "/api/cockpit/snapshot"
}

///|
pub fn health_path() -> String {
  "/api/health"
}

///|
pub fn intent_evaluate_path() -> String {
  "/api/intents/evaluate"
}

///|
fn json_response(status : Int, body : Json) -> HostApiResponse {
  { status, content_type: "application/json", body: body.stringify(indent=2) }
}

///|
fn error_response(
  status : Int,
  code : String,
  path : String,
  message : String,
) -> HostApiResponse {
  json_response(status, { code, path, message }.to_json())
}

///|
fn receipts_or_empty(root : String) -> Array[@core.RunReceipt] {
  match @runtime.list_run_receipts(root) {
    Ok(receipts) => receipts
    Err(_) => []
  }
}

///|
fn maybe_text(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
fn bridge_health_for_submission(
  profile : @core.RobotProfile,
  request : IntentSubmissionRequest,
) -> @core.BridgeHealth {
  if request.telemetry_age_ms < 0 {
    @mock_bridge.health(profile, telemetry_age_ms=-1)
  } else {
    @mock_bridge.health(profile, telemetry_age_ms=request.telemetry_age_ms)
  }
}

///|
fn intent_for_submission(
  profile : @core.RobotProfile,
  request : IntentSubmissionRequest,
) -> @core.CommandIntent {
  @core.command_intent(
    request.intent_id,
    if request.robot_id == "" {
      profile.id
    } else {
      request.robot_id
    },
    request.capability,
    request.requester,
    parameters=request.parameters,
  )
}

///|
fn decode_submission(
  body : String,
) -> Result[IntentSubmissionRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-intent-submission",
        path: intent_evaluate_path(),
        message: "failed to parse intent submission JSON",
      })
  }
  let request : IntentSubmissionRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-intent-submission",
        path: intent_evaluate_path(),
        message: "failed to decode intent submission contract",
      })
  }
  Ok(request)
}

///|
pub fn intent_submission_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_submission(body) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let health = bridge_health_for_submission(book.profile, request)
  let intent = intent_for_submission(book.profile, request)
  let result = match
    (maybe_text(request.approval_id), maybe_text(request.dry_run_receipt_id)) {
    (Some(approval_id), Some(dry_run_receipt_id)) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        approval_id~,
        dry_run_receipt_id~,
        developer_gate=request.developer_gate,
      )
    (Some(approval_id), None) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        approval_id~,
        developer_gate=request.developer_gate,
      )
    (None, Some(dry_run_receipt_id)) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        dry_run_receipt_id~,
        developer_gate=request.developer_gate,
      )
    (None, None) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        developer_gate=request.developer_gate,
      )
  }
  match @runtime.write_run_receipt(root, result.receipt) {
    Ok(path) =>
      json_response(
        200,
        { persisted: true, receipt_path: path, result }.to_json(),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
fn walk_safety(
  profile : @core.RobotProfile,
  health : @core.BridgeHealth,
) -> @pipeline.PipelineResult {
  let intent = @pipeline.high_walk_intent(
    "intent-host-cockpit-walk",
    profile.id,
    @core.operator_requester("host-api"),
    "0.10",
    "0.00",
    "1000",
  )
  @pipeline.evaluate_request(
    profile, health, intent, "receipt-host-cockpit-walk", 0L,
  )
}

///|
pub fn cockpit_snapshot(
  root : String,
) -> Result[@cockpit.CockpitSnapshot, @runtime.RuntimeIssue] {
  match @runtime.load_robotbook(root) {
    Err(issue) => Err(issue)
    Ok(book) => {
      let bridge = @mock_bridge.new(book.profile)
      let health = @mock_bridge.health(book.profile, telemetry_age_ms=0)
      let frame = @mock_bridge.telemetry_frame(book.profile, bridge, 0L)
      Ok(
        @cockpit.snapshot(
          book,
          health,
          frame,
          walk_safety(book.profile, health),
          receipts_or_empty(root),
        ),
      )
    }
  }
}

///|
pub fn snapshot_response(root : String) -> HostApiResponse {
  match cockpit_snapshot(root) {
    Ok(snapshot) => json_response(200, snapshot.to_json())
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn health_response(root : String) -> HostApiResponse {
  let status = match @runtime.load_robotbook(root) {
    Ok(book) => if book.status.ready { "ready" } else { "not-ready" }
    Err(_) => "error"
  }
  json_response(
    200,
    {
      service: "moonrobo",
      robotbook_root: root,
      status,
      snapshot_path: snapshot_path(),
      read_only: true,
    }.to_json(),
  )
}

///|
pub fn route(
  root : String,
  http_method : String,
  path : String,
) -> HostApiResponse {
  route_with_body(root, http_method, path, "")
}

///|
pub fn route_with_body(
  root : String,
  http_method : String,
  path : String,
  body : String,
) -> HostApiResponse {
  if http_method == "GET" {
    match path {
      "/api/cockpit/snapshot" => snapshot_response(root)
      "/api/health" => health_response(root)
      _ => error_response(404, "not-found", path, "No Moonrobo host API route")
    }
  } else if http_method == "POST" {
    match path {
      "/api/intents/evaluate" => intent_submission_response(root, body)
      _ => error_response(404, "not-found", path, "No Moonrobo host API route")
    }
  } else {
    error_response(
      405, "method-not-allowed", path, "Only GET and POST are supported",
    )
  }
}
