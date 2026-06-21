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
fn command_result(
  message : String,
  dry_run_receipt_id? : String = "",
  approval_id? : String = "",
) -> CommandResult {
  { message, dry_run_receipt_id, approval_id }
}

///|
fn parse_intent_result_payload(json : Json) -> Result[CommandResult, String] {
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
      Ok(command_result("\{next_action}: \{status} receipt \{receipt_id}"))
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
fn parse_dry_run_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "dry_run": { "dry_run_receipt_id": String(dry_run_receipt_id), .. },
      "result": {
        "next_action": String(next_action),
        "receipt": { "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "\{next_action}: \{status} dry run \{dry_run_receipt_id}",
          dry_run_receipt_id~,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid dry-run response")
  }
}

///|
fn parse_approval_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "approval": {
        "approval_id": String(approval_id),
        "dry_run_receipt_id": String(dry_run_receipt_id),
        ..
      },
      "result": {
        "next_action": String(next_action),
        "receipt": { "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "\{next_action}: \{status} approval \{approval_id}",
          dry_run_receipt_id~,
          approval_id~,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid approval response")
  }
}

///|
fn walk_intent_body(
  model : AppModel,
  receipt_id? : String = "receipt-cockpit-walk",
) -> Json {
  let snapshot = model.snapshot
  {
    "intent_id": "intent-cockpit-walk",
    "robot_id": snapshot.robot.robot_id,
    "capability": "control.high.walk",
    "parameters": {
      "x": model.walk_x,
      "yaw": model.walk_yaw,
      "duration_ms": model.walk_duration_ms,
    },
    "requester": { "kind": "operator", "id": "cockpit" },
    "receipt_id": receipt_id,
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "approval_id": model.approval_id,
    "dry_run_receipt_id": model.dry_run_receipt_id,
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
  model : AppModel,
  receipt_id? : String = "receipt-cockpit-walk",
) -> Cmd {
  if url == default_dry_run_url() {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(DryRunCollected(result)) },
      parse_dry_run_result_payload,
    )
    @http.post(url, Json(walk_intent_body(model, receipt_id~)), expect~)
  } else if url == default_approval_url() {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(ApprovalRecorded(result)) },
      parse_approval_result_payload,
    )
    @http.post(url, Json(walk_intent_body(model, receipt_id~)), expect~)
  } else {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(IntentEvaluated(result)) },
      parse_intent_result_payload,
    )
    @http.post(url, Json(walk_intent_body(model, receipt_id~)), expect~)
  }
}
