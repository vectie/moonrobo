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
pub fn snapshot_path() -> String {
  "/api/cockpit/snapshot"
}

///|
pub fn health_path() -> String {
  "/api/health"
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
  if http_method != "GET" {
    error_response(405, "method-not-allowed", path, "Only GET is supported")
  } else {
    match path {
      "/api/cockpit/snapshot" => snapshot_response(root)
      "/api/health" => health_response(root)
      _ => error_response(404, "not-found", path, "No Moonrobo host API route")
    }
  }
}
