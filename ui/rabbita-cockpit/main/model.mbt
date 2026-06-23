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
struct TaskMessageResult {
  message : String
  task_id : String
  session_id : String
  classification : String
  next_route : String
  requires_review : String
  memory_path : String
  card_count : String
  resident_availability : String
}

///|
struct ReviewedIntentDraft {
  intent_id : String
  robot_id : String
  capability : String
  parameters : Json
  requester : Json
  receipt_id : String
  now_ms : Json
  telemetry_age_ms : Json
  developer_gate : Json
}

///|
struct TaskMessageReviewResult {
  message : String
  task_id : String
  classification : String
  route : String
  reason : String
  physical_execution_allowed : String
  requires_review : String
  suggested_capability : String
  goal : String
  intent_draft : ReviewedIntentDraft?
}

///|
struct TaskMessageStatusResult {
  message : String
  task_id : String
  stage : String
  summary : String
  next_route : String
  runtime_status : String
  receipt_status : String
  bridge_status : String
  evaluated : String
  dry_run_collected : String
  approved : String
  executed : String
  runtime_required : String
}

///|
struct MoonClawPlanResult {
  action : String
  summary : String
  run_id : String
  record_path : String
  evidence_route : String
  review_count : String
  needs_human_count : String
  latest_review_id : String
  latest_review_summary : String
  replay_route : String
  replay_frame_count : String
  review_path : String
  first_step_label : String
  first_step_route : String
}

///|
struct RuntimeSupervisorProcessSummary {
  process_id : String
  state : String
  command_available : Bool
} derive(FromJson, ToJson)

///|
struct RuntimeSupervisorIssueSummary {
  code : String
  path : String
  message : String
} derive(FromJson, ToJson)

///|
struct RuntimeSupervisorStatus {
  status : String
  ready : Bool
  snapshot_ready : Bool
  bridge_base_url : String
  processes : Array[RuntimeSupervisorProcessSummary]
  issues : Array[RuntimeSupervisorIssueSummary]
} derive(FromJson, ToJson)

///|
struct RuntimeHealthResult {
  status : String
  persisted : String
  runtime_health_path : String
  latest_runtime_health_path : String
  telemetry_ok : String
  telemetry_status : String
  telemetry_message : String
  telemetry_frame_id : String
}

///|
struct AppModel {
  snapshot : @cockpit.CockpitSnapshot
  source_url : String
  loading : Bool
  error : String?
  last_source : String
  moonstat_url : String
  moonstat_status : @moonstat.MoonroboStatus
  runtime_supervisor_url : String
  runtime_supervisor_launch_url : String
  runtime_supervisor_start_url : String
  runtime_supervisor_stop_url : String
  runtime_emergency_stop_url : String
  runtime_health_url : String
  runtime_supervisor_status : RuntimeSupervisorStatus
  latest_runtime_health : RuntimeHealthResult?
  work_queue : @work_queue.AgentWorkQueue
  next_action_url : String
  agent_dispatch_url : String
  next_action : @work_queue.AgentNextAction?
  intent_url : String
  dry_run_url : String
  approval_url : String
  execute_url : String
  task_message_url : String
  observe_run_url : String
  moonclaw_context_url : String
  moonclaw_run_next_url : String
  evaluating : Bool
  collecting_dry_run : Bool
  approving : Bool
  executing : Bool
  submitting_task_message : Bool
  running_observation : Bool
  refreshing_process_plan : Bool
  preparing_runtime_launch : Bool
  starting_runtime : Bool
  stopping_runtime : Bool
  stopping_emergency : Bool
  running_next_process : Bool
  resolving_review : Bool
  dispatching_next_action : Bool
  loading_task_message_review : Bool
  intent_status : String
  observation_status : String
  task_message_status : String
  task_message_review_status : String
  process_status : String
  runtime_launch_status : String
  runtime_health_status : String
  work_queue_status : String
  walk_x : String
  walk_yaw : String
  walk_duration_ms : String
  task_message : String
  observation_task_id : String
  observation_frame_count : String
  dry_run_receipt_id : String
  approval_id : String
  latest_observation_run : ObservationRunResult?
  latest_task_message : TaskMessageResult?
  latest_task_message_review : TaskMessageReviewResult?
  latest_task_message_status : TaskMessageStatusResult?
  active_reviewed_intent : ReviewedIntentDraft?
  latest_process_plan : MoonClawPlanResult?
}

///|
enum Msg {
  RefreshSnapshot
  SnapshotLoaded(Result[@cockpit.CockpitSnapshot, String])
  RuntimeSupervisorLoaded(Result[RuntimeSupervisorStatus, String])
  PollRuntimeHealth
  RuntimeHealthLoaded(Result[RuntimeHealthResult, String])
  PrepareRuntimeLaunch
  RuntimeLaunchPrepared(Result[CommandResult, String])
  StartRuntime
  RuntimeStarted(Result[CommandResult, String])
  StopRuntime
  RuntimeStopped(Result[CommandResult, String])
  EmergencyStopRuntime
  RuntimeEmergencyStopped(Result[CommandResult, String])
  MoonstatLoaded(Result[@moonstat.MoonroboStatus, String])
  NextActionLoaded(Result[@work_queue.AgentNextActionPlan, String])
  DispatchNextAction
  NextActionDispatched(Result[CommandResult, String])
  OpenTaskMessageReview
  TaskMessageReviewLoaded(Result[TaskMessageReviewResult, String])
  TaskMessageStatusLoaded(Result[TaskMessageStatusResult, String])
  EvaluateReviewedIntent
  EvaluateWalk
  IntentEvaluated(Result[CommandResult, String])
  CollectDryRun
  DryRunCollected(Result[CommandResult, String])
  ApproveWalk
  ApprovalRecorded(Result[CommandResult, String])
  ExecuteWalk
  ExecutionRecorded(Result[CommandResult, String])
  SubmitTaskMessage
  TaskMessageSubmitted(Result[TaskMessageResult, String])
  RunObservation
  ObservationRunCompleted(Result[ObservationRunResult, String])
  RefreshProcessPlan
  ProcessPlanLoaded(Result[MoonClawPlanResult, String])
  RunNextProcess
  NextProcessCompleted(Result[MoonClawPlanResult, String])
  AcceptLatestReview
  ReviewAccepted(Result[CommandResult, String])
  UpdateWalkX(String)
  UpdateWalkYaw(String)
  UpdateWalkDuration(String)
  UpdateTaskMessage(String)
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
fn default_task_message_url() -> String {
  "/api/moontown/tasks/message"
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
fn default_moonstat_url() -> String {
  "/api/moonstat/status"
}

///|
fn default_runtime_supervisor_url() -> String {
  "/api/runtime/supervisor"
}

///|
fn default_runtime_supervisor_launch_url() -> String {
  "/api/runtime/supervisor/launch"
}

///|
fn default_runtime_supervisor_start_url() -> String {
  "/api/runtime/supervisor/start"
}

///|
fn default_runtime_supervisor_stop_url() -> String {
  "/api/runtime/supervisor/stop"
}

///|
fn default_runtime_emergency_stop_url() -> String {
  "/api/runtime/emergency-stop"
}

///|
fn default_runtime_health_url() -> String {
  "/api/runtime/health"
}

///|
fn runtime_health_poll_interval_ms() -> Int {
  5000
}

///|
#cfg(target="js")
fn schedule_runtime_health_poll(dispatch : (Msg) -> @rabbita.Cmd) -> @rabbita.Cmd {
  @rabbita.delay(
    dispatch(PollRuntimeHealth),
    runtime_health_poll_interval_ms(),
  )
}

///|
#cfg(not(target="js"))
fn schedule_runtime_health_poll(_dispatch : (Msg) -> @rabbita.Cmd) -> @rabbita.Cmd {
  @rabbita.none
}

///|
fn default_next_action_url() -> String {
  "/api/agent/next-action"
}

///|
fn default_agent_dispatch_url() -> String {
  "/api/agent/dispatch-next"
}

///|
fn init_model() -> AppModel {
  {
    snapshot: sample_snapshot(),
    source_url: default_snapshot_url(),
    loading: true,
    error: None,
    last_source: "sample fallback",
    moonstat_url: default_moonstat_url(),
    moonstat_status: sample_moonstat_status(),
    runtime_supervisor_url: default_runtime_supervisor_url(),
    runtime_supervisor_launch_url: default_runtime_supervisor_launch_url(),
    runtime_supervisor_start_url: default_runtime_supervisor_start_url(),
    runtime_supervisor_stop_url: default_runtime_supervisor_stop_url(),
    runtime_emergency_stop_url: default_runtime_emergency_stop_url(),
    runtime_health_url: default_runtime_health_url(),
    runtime_supervisor_status: sample_runtime_supervisor_status(),
    latest_runtime_health: None,
    work_queue: sample_work_queue(),
    next_action_url: default_next_action_url(),
    agent_dispatch_url: default_agent_dispatch_url(),
    next_action: sample_next_action(),
    intent_url: default_intent_url(),
    dry_run_url: default_dry_run_url(),
    approval_url: default_approval_url(),
    execute_url: default_execute_url(),
    task_message_url: default_task_message_url(),
    observe_run_url: default_observe_run_url(),
    moonclaw_context_url: default_moonclaw_context_url(),
    moonclaw_run_next_url: default_moonclaw_run_next_url(),
    evaluating: false,
    collecting_dry_run: false,
    approving: false,
    executing: false,
    submitting_task_message: false,
    running_observation: false,
    refreshing_process_plan: false,
    preparing_runtime_launch: false,
    starting_runtime: false,
    stopping_runtime: false,
    stopping_emergency: false,
    running_next_process: false,
    resolving_review: false,
    dispatching_next_action: false,
    loading_task_message_review: false,
    intent_status: "No command submitted",
    observation_status: "No observation run submitted",
    task_message_status: "No task message submitted",
    task_message_review_status: "No task-message review loaded",
    process_status: "No process plan loaded",
    runtime_launch_status: "Runtime launch not prepared",
    runtime_health_status: "Runtime health not polled",
    work_queue_status: "Sample queue loaded",
    walk_x: "0.10",
    walk_yaw: "0.00",
    walk_duration_ms: "1000",
    task_message: "inspect robot status",
    observation_task_id: "standing-goal-cockpit",
    observation_frame_count: "3",
    dry_run_receipt_id: "",
    approval_id: "",
    latest_observation_run: None,
    latest_task_message: None,
    latest_task_message_review: None,
    latest_task_message_status: None,
    active_reviewed_intent: None,
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
        fetch_runtime_supervisor_status(dispatch, model.runtime_supervisor_url),
        {
          ..model,
          snapshot,
          loading: false,
          error: None,
          last_source: model.source_url,
        },
      )
    RuntimeSupervisorLoaded(Ok(status)) =>
      (
        fetch_moonstat_status(dispatch, model.moonstat_url),
        { ..model, runtime_supervisor_status: status },
      )
    RuntimeSupervisorLoaded(Err(error)) =>
      (
        fetch_moonstat_status(dispatch, model.moonstat_url),
        {
          ..model,
          runtime_supervisor_status: {
            ..model.runtime_supervisor_status,
            status: "blocked",
            ready: false,
            issues: [
              {
                code: "runtime-supervisor-rejected",
                path: model.runtime_supervisor_url,
                message: error,
              },
            ],
          },
        },
      )
    PollRuntimeHealth =>
      (
        @rabbita.batch([
          fetch_runtime_health(dispatch, model.runtime_health_url),
          schedule_runtime_health_poll(dispatch),
        ]),
        { ..model, runtime_health_status: "Polling runtime health" },
      )
    RuntimeHealthLoaded(Ok(health)) =>
      {
        let next_model = {
          ..model,
          latest_runtime_health: Some(health),
          runtime_health_status: "Runtime health \{health.status}; telemetry \{health.telemetry_status}",
        }
        (
          runtime_health_task_status_command(dispatch, next_model, health),
          next_model,
        )
      }
    RuntimeHealthLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, runtime_health_status: "Runtime health rejected: \{error}" },
      )
    PrepareRuntimeLaunch =>
      (
        submit_runtime_launch(dispatch, model.runtime_supervisor_launch_url),
        {
          ..model,
          preparing_runtime_launch: true,
          runtime_launch_status: "Preparing runtime supervisor launch receipt",
        },
      )
    RuntimeLaunchPrepared(Ok(result)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          preparing_runtime_launch: false,
          runtime_launch_status: result.message,
        },
      )
    RuntimeLaunchPrepared(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          preparing_runtime_launch: false,
          runtime_launch_status: "Runtime launch rejected: \{error}",
        },
      )
    StartRuntime =>
      (
        submit_runtime_start(dispatch, model.runtime_supervisor_start_url),
        {
          ..model,
          starting_runtime: true,
          runtime_launch_status: "Starting runtime supervisor",
        },
      )
    RuntimeStarted(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_runtime_health(dispatch, model.runtime_health_url),
        ]),
        {
          ..model,
          loading: true,
          starting_runtime: false,
          runtime_launch_status: result.message,
        },
      )
    RuntimeStarted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          starting_runtime: false,
          runtime_launch_status: "Runtime start rejected: \{error}",
        },
      )
    StopRuntime =>
      (
        submit_runtime_stop(dispatch, model.runtime_supervisor_stop_url),
        {
          ..model,
          stopping_runtime: true,
          runtime_launch_status: "Stopping runtime supervisor",
        },
      )
    RuntimeStopped(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_runtime_health(dispatch, model.runtime_health_url),
        ]),
        {
          ..model,
          loading: true,
          stopping_runtime: false,
          runtime_launch_status: result.message,
        },
      )
    RuntimeStopped(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          stopping_runtime: false,
          runtime_launch_status: "Runtime stop rejected: \{error}",
        },
      )
    EmergencyStopRuntime =>
      (
        submit_runtime_emergency_stop(dispatch, model.runtime_emergency_stop_url),
        {
          ..model,
          stopping_emergency: true,
          runtime_launch_status: "Sending emergency stop",
        },
      )
    RuntimeEmergencyStopped(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_runtime_health(dispatch, model.runtime_health_url),
        ]),
        {
          ..model,
          loading: true,
          stopping_emergency: false,
          runtime_launch_status: result.message,
        },
      )
    RuntimeEmergencyStopped(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          stopping_emergency: false,
          runtime_launch_status: "Emergency stop rejected: \{error}",
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
    MoonstatLoaded(Ok(status)) =>
      (
        fetch_next_action(dispatch, model.next_action_url),
        {
          ..model,
          moonstat_status: status,
          work_queue_status: "Refreshing agent work queue",
        },
      )
    MoonstatLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, process_status: "Moonstat status rejected: \{error}" },
      )
    NextActionLoaded(Ok(plan)) =>
      (
        @rabbita.none,
        {
          ..model,
          work_queue: plan.queue,
          next_action: plan.action,
          work_queue_status: "Loaded \{plan.queue.item_count} work item(s)",
        },
      )
    NextActionLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, work_queue_status: "Next action rejected: \{error}" },
      )
    DispatchNextAction =>
      (
        submit_agent_dispatch(dispatch, model.agent_dispatch_url, model.next_action),
        {
          ..model,
          dispatching_next_action: true,
          work_queue_status: "Dispatching safe agent action",
        },
      )
    NextActionDispatched(Ok(result)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          dispatching_next_action: false,
          work_queue_status: result.message,
        },
      )
    NextActionDispatched(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          dispatching_next_action: false,
          work_queue_status: "Agent dispatch rejected: \{error}",
        },
      )
    OpenTaskMessageReview =>
      match task_message_review_route(model) {
        Some(route) =>
          (
            fetch_task_message_review(dispatch, route),
            {
              ..model,
              loading_task_message_review: true,
              task_message_review_status: "Loading task-message review",
            },
          )
        None =>
          (
            @rabbita.none,
            {
              ..model,
              task_message_review_status: "No task-message review action selected",
            },
          )
      }
    TaskMessageReviewLoaded(Ok(result)) =>
      (
        fetch_task_message_status(dispatch, task_message_status_route(result.task_id)),
        {
          ..model,
          loading_task_message_review: false,
          task_message_review_status: result.message,
          latest_task_message_review: Some(result),
        },
      )
    TaskMessageReviewLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading_task_message_review: false,
          task_message_review_status: "Task-message review rejected: \{error}",
        },
      )
    TaskMessageStatusLoaded(Ok(result)) =>
      {
        let next_model = {
          ..model,
          latest_task_message_status: Some(result),
          task_message_review_status: result.message,
        }
        if should_auto_dispatch_task_message(model, result) {
          (
            submit_intent(
              dispatch,
              active_intent_route(next_model, model.execute_url, "execute"),
              next_model,
              receipt_id=active_receipt_id(next_model, "executed"),
            ),
            {
              ..next_model,
              executing: true,
              intent_status: "Dispatching reviewed task through healthy runtime",
            },
          )
        } else {
          (@rabbita.none, next_model)
        }
      }
    TaskMessageStatusLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          task_message_review_status: "Task-message status rejected: \{error}",
        },
      )
    EvaluateReviewedIntent =>
      match model.latest_task_message_review {
        Some({ intent_draft: Some(draft), task_id, .. }) => {
          let active_model = { ..model, active_reviewed_intent: Some(draft) }
          (
            submit_intent(
              dispatch,
              task_message_evaluate_route(task_id),
              active_model,
              receipt_id=draft.receipt_id,
            ),
            {
              ..active_model,
              evaluating: true,
              intent_status: "Evaluating reviewed task intent",
            },
          )
        }
        Some(_) =>
          (
            @rabbita.none,
            { ..model, intent_status: "Reviewed task does not include an evaluable intent draft" },
          )
        None =>
          (
            @rabbita.none,
            { ..model, intent_status: "No reviewed task intent is selected" },
          )
      }
    EvaluateWalk =>
      (
        submit_intent(
          dispatch,
          model.intent_url,
          { ..model, active_reviewed_intent: None },
        ),
        {
          ..model,
          active_reviewed_intent: None,
          evaluating: true,
          intent_status: "Evaluating walk intent",
        },
      )
    IntentEvaluated(Ok(message)) =>
      {
        let next_model = {
          ..model,
          loading: active_task_message_id(model) is None,
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
        }
        (reviewed_status_or_snapshot(dispatch, model), next_model)
      }
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
        submit_intent(
          dispatch,
          active_intent_route(model, model.dry_run_url, "dry-run"),
          model,
          receipt_id=active_receipt_id(model, "dry-run"),
        ),
        {
          ..model,
          collecting_dry_run: true,
          intent_status: "Collecting dry-run evidence",
        },
      )
    DryRunCollected(Ok(message)) =>
      (
        reviewed_status_or_snapshot(dispatch, model),
        {
          ..model,
          loading: active_task_message_id(model) is None,
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
        submit_intent(
          dispatch,
          active_intent_route(model, model.approval_url, "approve"),
          model,
          receipt_id=active_receipt_id(model, "approval"),
        ),
        { ..model, approving: true, intent_status: "Recording approval" },
      )
    ApprovalRecorded(Ok(message)) =>
      (
        reviewed_status_or_snapshot(dispatch, model),
        {
          ..model,
          loading: active_task_message_id(model) is None,
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
        submit_intent(
          dispatch,
          active_intent_route(model, model.execute_url, "execute"),
          model,
          receipt_id=active_receipt_id(model, "executed"),
        ),
        { ..model, executing: true, intent_status: "Executing bridge intent" },
      )
    ExecutionRecorded(Ok(message)) =>
      (
        reviewed_status_or_snapshot(dispatch, model),
        {
          ..model,
          loading: active_task_message_id(model) is None,
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
    SubmitTaskMessage =>
      (
        submit_task_message(dispatch, model.task_message_url, model),
        {
          ..model,
          submitting_task_message: true,
          task_message_status: "Submitting task message",
        },
      )
    TaskMessageSubmitted(Ok(result)) =>
      (
        fetch_snapshot(dispatch, model.source_url),
        {
          ..model,
          loading: true,
          submitting_task_message: false,
          task_message_status: result.message,
          latest_task_message: Some(result),
        },
      )
    TaskMessageSubmitted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          submitting_task_message: false,
          task_message_status: "Task message rejected: \{error}",
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
    AcceptLatestReview =>
      match latest_review_id(model) {
        Some(review_id) =>
          (
            submit_review_resolution(dispatch, review_id, model),
            {
              ..model,
              resolving_review: true,
              process_status: "Accepting review \{review_id}",
            },
          )
        None =>
          (
            @rabbita.none,
            { ..model, process_status: "No review is selected for acceptance" },
          )
      }
    ReviewAccepted(Ok(result)) =>
      (
        fetch_moonclaw_context(dispatch, model.moonclaw_context_url),
        {
          ..model,
          resolving_review: false,
          process_status: result.message,
        },
      )
    ReviewAccepted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          resolving_review: false,
          process_status: "Review acceptance rejected: \{error}",
        },
      )
    UpdateWalkX(value) => (@rabbita.none, { ..model, walk_x: value })
    UpdateWalkYaw(value) => (@rabbita.none, { ..model, walk_yaw: value })
    UpdateWalkDuration(value) =>
      (@rabbita.none, { ..model, walk_duration_ms: value })
    UpdateTaskMessage(value) =>
      (@rabbita.none, { ..model, task_message: value })
    UpdateObservationTaskId(value) =>
      (@rabbita.none, { ..model, observation_task_id: value })
    UpdateObservationFrameCount(value) =>
      (@rabbita.none, { ..model, observation_frame_count: value })
  }
}

///|
fn status_tone(status : String) -> String {
  match status {
    "ok" | "ready" | "fresh" | "ready-for-execution" | "launchable" | "healthy" | "proposal-only" | "Observe" | "evaluate-policy" | "clear" | "bridge-ready" =>
      "ok"
    "dry-run-required" | "waiting-for-dry-run" | "approval-required" | "waiting-for-approval" | "stale" | "missing-command" | "degraded" | "requires-dry-run" | "requires-approval" | "ReviewEvidence" | "connect-bridge" | "review-evidence" | "annotate-replay" | "repair-dataset" | "dry-run-policy-proposal" | "approve-policy-proposal" | "collector-ready" =>
      "warning"
    "blocked" | "blocked-quality" | "blocked-safety" | "error" | "not-ready" | "attention" | "Hold" | "repair-policy-quality" | "review-policy-safety" =>
      "danger"
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
fn receipt_bridge_error_label(receipt : @cockpit.CockpitReceiptSummary?) -> String {
  match receipt {
    Some({ bridge_error: Some(value), .. }) => value
    _ => "-"
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

///|
fn latest_review_id(model : AppModel) -> String? {
  match model.latest_process_plan {
    Some(value) if value.latest_review_id != "-" => Some(value.latest_review_id)
    _ => None
  }
}

///|
fn can_accept_latest_review(model : AppModel) -> Bool {
  latest_review_id(model) is Some(_)
}

///|
fn accept_review_button_label(model : AppModel) -> String {
  if model.resolving_review {
    "Accepting..."
  } else {
    "Accept Review"
  }
}

///|
fn is_task_message_review_kind(kind : String) -> Bool {
  kind == "review-command-message" || kind == "review-maintenance-message"
}

///|
fn task_message_review_route(model : AppModel) -> String? {
  match model.next_action {
    Some(action) if is_task_message_review_kind(action.kind) && action.http_method == "GET" =>
      Some(action.route)
    _ =>
      match model.work_queue.next_item {
        Some(item) if is_task_message_review_kind(item.kind) => Some(item.target_path)
        _ => None
      }
  }
}

///|
fn can_open_task_message_review(model : AppModel) -> Bool {
  task_message_review_route(model) is Some(_)
}

///|
fn can_evaluate_reviewed_intent(model : AppModel) -> Bool {
  match model.latest_task_message_review {
    Some({ intent_draft: Some(_), .. }) => true
    _ => false
  }
}

///|
fn task_message_waits_on_runtime(status : TaskMessageStatusResult) -> Bool {
  status.stage == "runtime-required" || status.stage == "runtime-unhealthy"
}

///|
fn runtime_health_task_status_command(
  dispatch : (Msg) -> @rabbita.Cmd,
  model : AppModel,
  health : RuntimeHealthResult,
) -> @rabbita.Cmd {
  match model.latest_task_message_status {
    Some(status) =>
      if task_message_waits_on_runtime(status) &&
        (health.status == "healthy" || health.status == "bridge-unhealthy") {
        fetch_task_message_status(dispatch, task_message_status_route(status.task_id))
      } else {
        @rabbita.none
      }
    _ => @rabbita.none
  }
}

///|
fn should_auto_dispatch_task_message(
  model : AppModel,
  status : TaskMessageStatusResult,
) -> Bool {
  model.active_reviewed_intent is Some(_) &&
  !model.executing &&
  status.stage == "ready-to-dispatch" &&
  status.evaluated == "true" &&
  status.dry_run_collected == "true" &&
  status.approved == "true" &&
  status.executed == "false" &&
  status.next_route == task_message_action_route(status.task_id, "execute")
}

///|
fn task_message_review_button_label(model : AppModel) -> String {
  if model.loading_task_message_review {
    "Opening..."
  } else {
    "Open Task Review"
  }
}

///|
fn evaluate_reviewed_intent_button_label(model : AppModel) -> String {
  if model.evaluating && model.active_reviewed_intent is Some(_) {
    "Evaluating..."
  } else {
    "Evaluate Reviewed Intent"
  }
}

///|
fn active_receipt_id(model : AppModel, suffix : String) -> String {
  match model.active_reviewed_intent {
    Some(draft) => "receipt-\{draft.intent_id}-\{suffix}"
    None => "receipt-cockpit-walk-\{suffix}"
  }
}

///|
fn task_message_evaluate_route(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/evaluate"
}

///|
fn task_message_status_route(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/status"
}

///|
fn active_task_message_id(model : AppModel) -> String? {
  match (model.active_reviewed_intent, model.latest_task_message_review) {
    (Some(_), Some(review)) => Some(review.task_id)
    _ => None
  }
}

///|
fn reviewed_status_or_snapshot(
  dispatch : (Msg) -> @rabbita.Cmd,
  model : AppModel,
) -> @rabbita.Cmd {
  match active_task_message_id(model) {
    Some(task_id) =>
      fetch_task_message_status(dispatch, task_message_status_route(task_id))
    None => fetch_snapshot(dispatch, model.source_url)
  }
}

///|
fn task_message_action_route(task_id : String, action : String) -> String {
  let route_action = if action == "execute" {
    "execute-sidecar"
  } else {
    action
  }
  "/api/moonbook/task-messages/\{task_id}/\{route_action}"
}

///|
fn active_intent_route(
  model : AppModel,
  fallback : String,
  action : String,
) -> String {
  match active_task_message_id(model) {
    Some(task_id) => task_message_action_route(task_id, action)
    None => fallback
  }
}
