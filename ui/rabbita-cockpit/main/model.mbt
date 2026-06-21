///|
struct AppModel {
  snapshot : @cockpit.CockpitSnapshot
  source_url : String
  loading : Bool
  error : String?
  last_source : String
  intent_url : String
  evaluating : Bool
  intent_status : String
  walk_x : String
  walk_yaw : String
  walk_duration_ms : String
}

///|
enum Msg {
  RefreshSnapshot
  SnapshotLoaded(Result[@cockpit.CockpitSnapshot, String])
  EvaluateWalk
  IntentEvaluated(Result[String, String])
  UpdateWalkX(String)
  UpdateWalkYaw(String)
  UpdateWalkDuration(String)
}

///|
fn default_snapshot_url() -> String {
  "/api/cockpit/snapshot"
}

///|
fn default_intent_url() -> String {
  "/api/intents/evaluate"
}

///|
fn init_model() -> AppModel {
  {
    snapshot: sample_snapshot(),
    source_url: default_snapshot_url(),
    loading: true,
    error: None,
    last_source: "sample fallback",
    intent_url: default_intent_url(),
    evaluating: false,
    intent_status: "No command submitted",
    walk_x: "0.10",
    walk_yaw: "0.00",
    walk_duration_ms: "1000",
  }
}

///|
fn update(
  dispatch : (Msg) -> @rabbita.Cmd,
  msg : Msg,
  model : AppModel,
) -> (@rabbita.Cmd, AppModel) {
  match msg {
    RefreshSnapshot =>
      (
        fetch_snapshot(dispatch, model.source_url),
        { ..model, loading: true, error: None },
      )
    SnapshotLoaded(Ok(snapshot)) =>
      (
        @rabbita.none,
        {
          ..model,
          snapshot,
          loading: false,
          error: None,
          last_source: model.source_url,
        },
      )
    SnapshotLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading: false,
          error: Some(error),
          last_source: "sample fallback",
        },
      )
    EvaluateWalk =>
      (
        submit_walk_intent(dispatch, model.intent_url, model),
        { ..model, evaluating: true, intent_status: "Evaluating walk intent" },
      )
    IntentEvaluated(Ok(message)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          evaluating: false,
          intent_status: message,
        },
      )
    IntentEvaluated(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          evaluating: false,
          intent_status: "Intent rejected: \{error}",
        },
      )
    UpdateWalkX(value) => (@rabbita.none, { ..model, walk_x: value })
    UpdateWalkYaw(value) => (@rabbita.none, { ..model, walk_yaw: value })
    UpdateWalkDuration(value) =>
      (@rabbita.none, { ..model, walk_duration_ms: value })
  }
}

///|
fn status_tone(status : String) -> String {
  match status {
    "ok" | "ready" | "fresh" => "ok"
    "dry-run-required" | "waiting-for-dry-run" | "stale" => "warning"
    "blocked" | "error" | "not-ready" => "danger"
    _ => "neutral"
  }
}

///|
fn ready_label(ready : Bool) -> String {
  if ready {
    "ready"
  } else {
    "not-ready"
  }
}

///|
fn read_only_label(read_only : Bool) -> String {
  if read_only {
    "read-only"
  } else {
    "control"
  }
}

///|
fn freshness_label(stale : Bool) -> String {
  if stale {
    "Telemetry stale"
  } else {
    "Telemetry fresh"
  }
}

///|
fn optional_int_label(value : Int?) -> String {
  match value {
    Some(v) => "\{v}"
    None => "-"
  }
}

///|
fn receipt_id_label(receipt : @cockpit.CockpitReceiptSummary?) -> String {
  match receipt {
    Some(value) => value.receipt_id
    None => "No receipt"
  }
}

///|
fn receipt_status_label(receipt : @cockpit.CockpitReceiptSummary?) -> String {
  match receipt {
    Some(value) => value.status
    None => "-"
  }
}

///|
fn receipt_capability_label(
  receipt : @cockpit.CockpitReceiptSummary?,
) -> String {
  match receipt {
    Some(value) => value.capability
    None => "-"
  }
}

///|
fn receipt_started_label(receipt : @cockpit.CockpitReceiptSummary?) -> String {
  match receipt {
    Some(value) => "\{value.started_at_ms}"
    None => "-"
  }
}

///|
fn loading_label(model : AppModel) -> String {
  if model.loading {
    "loading"
  } else {
    "loaded"
  }
}

///|
fn evaluate_button_label(model : AppModel) -> String {
  if model.evaluating {
    "Evaluating..."
  } else {
    "Evaluate Walk"
  }
}
