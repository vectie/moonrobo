///|
///|
struct CommandResult {
  message : String
  dry_run_receipt_id : String
  approval_id : String
}

///|
struct ObservationRunResult {
  message : String
  session_id : String
  status : String
  frame_count : String
  latest_frame_id : String
  resident_availability : String
}

///|
struct MoonClawPlanResult {
  action : String
  summary : String
  run_id : String
  record_path : String
  review_count : String
  needs_human_count : String
  latest_review_id : String
  latest_review_summary : String
  first_step_label : String
  first_step_route : String
}

///|
struct AppModel {
  snapshot : @cockpit.CockpitSnapshot
  source_url : String
  loading : Bool
  error : String?
  last_source : String
  intent_url : String
  dry_run_url : String
  approval_url : String
  execute_url : String
  observe_run_url : String
  moonclaw_context_url : String
  moonclaw_run_next_url : String
  evaluating : Bool
  collecting_dry_run : Bool
  approving : Bool
  executing : Bool
  running_observation : Bool
  refreshing_process_plan : Bool
  running_next_process : Bool
  intent_status : String
  observation_status : String
  process_status : String
  walk_x : String
  walk_yaw : String
  walk_duration_ms : String
  observation_task_id : String
  observation_frame_count : String
  dry_run_receipt_id : String
  approval_id : String
  latest_observation_run : ObservationRunResult?
  latest_process_plan : MoonClawPlanResult?
}

///|
enum Msg {
  RefreshSnapshot
  SnapshotLoaded(Result[@cockpit.CockpitSnapshot, String])
  EvaluateWalk
  IntentEvaluated(Result[CommandResult, String])
  CollectDryRun
  DryRunCollected(Result[CommandResult, String])
  ApproveWalk
  ApprovalRecorded(Result[CommandResult, String])
  ExecuteWalk
  ExecutionRecorded(Result[CommandResult, String])
  RunObservation
  ObservationRunCompleted(Result[ObservationRunResult, String])
  RefreshProcessPlan
  ProcessPlanLoaded(Result[MoonClawPlanResult, String])
  RunNextProcess
  NextProcessCompleted(Result[MoonClawPlanResult, String])
  UpdateWalkX(String)
  UpdateWalkYaw(String)
  UpdateWalkDuration(String)
  UpdateObservationTaskId(String)
  UpdateObservationFrameCount(String)
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
fn default_dry_run_url() -> String {
  "/api/intents/dry-run"
}

///|
fn default_approval_url() -> String {
  "/api/intents/approve"
}

///|
fn default_execute_url() -> String {
  "/api/intents/execute"
}

///|
fn default_observe_run_url() -> String {
  "/api/moontown/tasks/observe-run"
}

///|
fn default_moonclaw_context_url() -> String {
  "/api/moonclaw/context"
}

///|
fn default_moonclaw_run_next_url() -> String {
  "/api/moonclaw/run-next"
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
    dry_run_url: default_dry_run_url(),
    approval_url: default_approval_url(),
    execute_url: default_execute_url(),
    observe_run_url: default_observe_run_url(),
    moonclaw_context_url: default_moonclaw_context_url(),
    moonclaw_run_next_url: default_moonclaw_run_next_url(),
    evaluating: false,
    collecting_dry_run: false,
    approving: false,
    executing: false,
    running_observation: false,
    refreshing_process_plan: false,
    running_next_process: false,
    intent_status: "No command submitted",
    observation_status: "No observation run submitted",
    process_status: "No process plan loaded",
    walk_x: "0.10",
    walk_yaw: "0.00",
    walk_duration_ms: "1000",
    observation_task_id: "standing-goal-cockpit",
    observation_frame_count: "3",
    dry_run_receipt_id: "",
    approval_id: "",
    latest_observation_run: None,
    latest_process_plan: None,
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
          intent_status: message.message,
          dry_run_receipt_id: if message.dry_run_receipt_id == "" {
            model.dry_run_receipt_id
          } else {
            message.dry_run_receipt_id
          },
          approval_id: if message.approval_id == "" {
            model.approval_id
          } else {
            message.approval_id
          },
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
    CollectDryRun =>
      (
        submit_walk_intent(dispatch, model.dry_run_url, model, receipt_id="receipt-cockpit-walk-dry-run"),
        {
          ..model,
          collecting_dry_run: true,
          intent_status: "Collecting dry-run evidence",
        },
      )
    DryRunCollected(Ok(message)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          collecting_dry_run: false,
          intent_status: message.message,
          dry_run_receipt_id: message.dry_run_receipt_id,
        },
      )
    DryRunCollected(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          collecting_dry_run: false,
          intent_status: "Dry run rejected: \{error}",
        },
      )
    ApproveWalk =>
      (
        submit_walk_intent(dispatch, model.approval_url, model, receipt_id="receipt-cockpit-walk-approval"),
        { ..model, approving: true, intent_status: "Recording approval" },
      )
    ApprovalRecorded(Ok(message)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          approving: false,
          intent_status: message.message,
          dry_run_receipt_id: message.dry_run_receipt_id,
          approval_id: message.approval_id,
        },
      )
    ApprovalRecorded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          approving: false,
          intent_status: "Approval rejected: \{error}",
        },
      )
    ExecuteWalk =>
      (
        submit_walk_intent(dispatch, model.execute_url, model, receipt_id="receipt-cockpit-walk-executed"),
        { ..model, executing: true, intent_status: "Executing bridge intent" },
      )
    ExecutionRecorded(Ok(message)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          executing: false,
          intent_status: message.message,
        },
      )
    ExecutionRecorded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          executing: false,
          intent_status: "Execution rejected: \{error}",
        },
      )
    RunObservation =>
      (
        submit_observation_run(dispatch, model.observe_run_url, model),
        {
          ..model,
          running_observation: true,
          observation_status: "Running observation pipeline",
        },
      )
    ObservationRunCompleted(Ok(result)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          running_observation: false,
          observation_status: result.message,
          latest_observation_run: Some(result),
        },
      )
    ObservationRunCompleted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          running_observation: false,
          observation_status: "Observation run rejected: \{error}",
        },
      )
    RefreshProcessPlan =>
      (
        fetch_moonclaw_context(dispatch, model.moonclaw_context_url),
        {
          ..model,
          refreshing_process_plan: true,
          process_status: "Refreshing process plan",
        },
      )
    ProcessPlanLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          refreshing_process_plan: false,
          process_status: result.summary,
          latest_process_plan: Some(result),
        },
      )
    ProcessPlanLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          refreshing_process_plan: false,
          process_status: "Process plan rejected: \{error}",
        },
      )
    RunNextProcess =>
      (
        submit_moonclaw_run_next(dispatch, model.moonclaw_run_next_url, model),
        {
          ..model,
          running_next_process: true,
          process_status: "Running next process",
        },
      )
    NextProcessCompleted(Ok(result)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          running_next_process: false,
          process_status: result.summary,
          latest_process_plan: Some(result),
        },
      )
    NextProcessCompleted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          running_next_process: false,
          process_status: "Next process rejected: \{error}",
        },
      )
    UpdateWalkX(value) => (@rabbita.none, { ..model, walk_x: value })
    UpdateWalkYaw(value) => (@rabbita.none, { ..model, walk_yaw: value })
    UpdateWalkDuration(value) =>
      (@rabbita.none, { ..model, walk_duration_ms: value })
    UpdateObservationTaskId(value) =>
      (@rabbita.none, { ..model, observation_task_id: value })
    UpdateObservationFrameCount(value) =>
      (@rabbita.none, { ..model, observation_frame_count: value })
  }
}

///|
fn status_tone(status : String) -> String {
  match status {
    "ok" | "ready" | "fresh" | "ready-for-execution" | "launchable" | "Observe" =>
      "ok"
    "dry-run-required" | "waiting-for-dry-run" | "approval-required" | "waiting-for-approval" | "stale" | "missing-command" | "ReviewEvidence" =>
      "warning"
    "blocked" | "error" | "not-ready" | "Hold" => "danger"
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

///|
fn dry_run_button_label(model : AppModel) -> String {
  if model.collecting_dry_run {
    "Collecting..."
  } else {
    "Collect Dry Run"
  }
}

///|
fn approval_button_label(model : AppModel) -> String {
  if model.approving {
    "Approving..."
  } else {
    "Approve"
  }
}

///|
fn execute_button_label(model : AppModel) -> String {
  if model.executing {
    "Executing..."
  } else {
    "Execute"
  }
}

///|
fn observation_button_label(model : AppModel) -> String {
  if model.running_observation {
    "Running..."
  } else {
    "Run Observation"
  }
}

///|
fn process_plan_button_label(model : AppModel) -> String {
  if model.refreshing_process_plan {
    "Refreshing..."
  } else {
    "Refresh Plan"
  }
}

///|
fn next_process_button_label(model : AppModel) -> String {
  if model.running_next_process {
    "Running..."
  } else {
    "Run Next"
  }
}
