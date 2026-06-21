///|
using @rabbita {type Cmd}

///|
fn parse_snapshot_payload(
  json : Json,
) -> Result[@cockpit.CockpitSnapshot, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid cockpit snapshot: \{error}")
  }
}

///|
fn fetch_snapshot(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, @cockpit.CockpitSnapshot] = Json(
    fn(result) { dispatch(SnapshotLoaded(result)) },
    parse_snapshot_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_intent_result_payload(json : Json) -> Result[String, String] {
  match json {
    {
      "persisted": true,
      "result": {
        "next_action": String(next_action),
        "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok("\{next_action}: \{status} receipt \{receipt_id}")
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid intent evaluation response")
  }
}

///|
fn walk_intent_body(snapshot : @cockpit.CockpitSnapshot) -> Json {
  {
    "intent_id": "intent-cockpit-walk",
    "robot_id": snapshot.robot.robot_id,
    "capability": "control.high.walk",
    "parameters": {
      "x": "0.10",
      "yaw": "0.00",
      "duration_ms": "1000",
    },
    "requester": { "kind": "operator", "id": "cockpit" },
    "receipt_id": "receipt-cockpit-walk",
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "approval_id": "",
    "dry_run_receipt_id": "",
    "developer_gate": false,
    "telemetry_age_ms": match snapshot.bridge.telemetry_age_ms {
      Some(age) => age
      None => -1
    },
  }
}

///|
fn submit_walk_intent(
  dispatch : (Msg) -> Cmd,
  url : String,
  snapshot : @cockpit.CockpitSnapshot,
) -> Cmd {
  let expect : @http.Expecting[Cmd, String] = Json(
    fn(result) { dispatch(IntentEvaluated(result)) },
    parse_intent_result_payload,
  )
  @http.post(url, Json(walk_intent_body(snapshot)), expect~)
}
