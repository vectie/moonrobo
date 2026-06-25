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
struct TaskMessageLedgerItem {
  task_id : String
  goal : String
  classification : String
  stage : String
  route : String
  next_route : String
  evaluated : String
  dry_run_collected : String
  approved : String
  executed : String
  requires_review : String
  physical_execution_allowed : String
  message_path : String
}

///|
struct TaskMessageLedgerResult {
  message : String
  message_count : String
  messages : Array[TaskMessageLedgerItem]
}

///|
struct TaskConversationTurn {
  turn_id : String
  task_id : String
  created_at_ms : String
  user_text : String
  robo_text : String
  classification : String
  stage : String
  next_route : String
  requires_review : String
  physical_execution_allowed : String
}

///|
struct TaskConversationResult {
  message : String
  turn_count : String
  latest_task_id : String
  turns : Array[TaskConversationTurn]
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
struct TaskLoopMappingResult {
  mapping_id : String
  robot_id : String
  resident_id : String
  bridge_id : String
  runtime_status : String
  availability : String
  mapped : String
  reachable : String
  latest_task_id : String
  latest_execution_status : String
  latest_feedback_status : String
  latest_command_outcome_status : String
  verified_execution_count : String
}

///|
struct TaskLoopExecutionProofResult {
  execution_count : String
  verified_count : String
  latest_snapshot_id : String
  latest_snapshot_path : String
  latest_status : String
  latest_verified : String
  latest_command_outcome_status : String
}

struct TaskLoopSessionResult {
  session_id : String
  thread_id : String
  resident_id : String
  mapping_id : String
  robot_id : String
  bridge_id : String
  task_id : String
  latest_user_text : String
  latest_robo_text : String
  stage : String
  continuation_route : String
  dispatch_requested : String
  dispatch_ready : String
  execution_verified : String
  recovery_kind : String
  recovery_path : String
}

///|
struct TaskLoopResult {
  message : String
  task_id : String
  routine_id : String
  routine_status : String
  routine_verified : String
  routine_path : String
  routine_memory_updated : String
  routine_next_route : String
  proof_status : String
  proof_verified : String
  proof_path : String
  proof_next_route : String
  proof_auto_feedback_bound : String
  proof_auto_feedback_verified : String
  proof_auto_feedback_message : String
  continued : String
  dispatch_requested : String
  classification : String
  task_stage : String
  task_summary : String
  task_next_route : String
  conversation_turn_count : String
  conversation_latest_task_id : String
  resident_availability : String
  mapping : TaskLoopMappingResult
  execution_proof : TaskLoopExecutionProofResult
  session : TaskLoopSessionResult
}

///|
struct RoboSessionResult {
  message : String
  status : String
  has_task_message : String
  loop_count : String
  turn_count : String
  step_count : String
  session : TaskLoopSessionResult
  mapping : TaskLoopMappingResult
  execution_proof : TaskLoopExecutionProofResult
  decision : RoboDecisionResult
}

///|
struct RoboDecisionResult {
  status : String
  can_act : String
  needs_operator : String
  needs_agent : String
  accepts_task_messages : String
  physical_execution_allowed : String
  next_owner : String
  next_method : String
  next_route : String
  target_route : String
  next_kind : String
  next_title : String
  queue_count : String
  readiness_status : String
  loop_status : String
  loop_percent : String
}

///|
struct RoboTurnResult {
  message : String
  turn_id : String
  turn_path : String
  status : String
  accepted : String
  agent_ran : String
  task_id : String
  next_owner : String
  next_kind : String
  next_route : String
  can_act : String
  needs_agent : String
}

///|
struct RoboStepResult {
  message : String
  step_id : String
  step_path : String
  status : String
  advanced : String
  before_owner : String
  before_route : String
  after_owner : String
  after_route : String
}

///|
struct RoboStepHistoryResult {
  message : String
  step_count : String
  steps : Array[RoboStepResult]
}

///|
struct RoboLoopResult {
  message : String
  loop_id : String
  loop_path : String
  status : String
  accepted : String
  advanced_count : String
  blocked_count : String
  turn : RoboTurnResult?
  steps : Array[RoboStepResult]
  final_owner : String
  final_kind : String
  final_route : String
}

///|
struct RoboLoopHistoryResult {
  message : String
  loop_count : String
  loops : Array[RoboLoopResult]
}

///|
struct RoboTurnHistoryResult {
  message : String
  turn_count : String
  turns : Array[RoboTurnResult]
}

///|
struct TaskExecutionProofResult {
  message : String
  execution_count : String
  verified_count : String
  latest_snapshot_id : String
  latest_status : String
  latest_task_id : String
  latest_bridge_status : String
  latest_runtime_status : String
  latest_runtime_health_persisted : String
}

///|
struct PlatformLoopProofCheckResult {
  code : String
  label : String
  ready : String
  evidence_route : String
  evidence_path : String
  message : String
}

///|
struct PlatformLoopProofResult {
  message : String
  status : String
  ready : String
  completed_count : String
  total_count : String
  percent : String
  robot_id : String
  readiness_status : String
  readiness_pass_count : String
  readiness_fail_count : String
  latest_task_execution_path : String
  latest_routine_path : String
  latest_robo_loop_path : String
  next_route : String
  checks : Array[PlatformLoopProofCheckResult]
  auto_feedback_attempted : String
  auto_feedback_status : String
  auto_feedback_message : String
}

///|
struct MoonroboLiveReadinessResult {
  message : String
  status : String
  ready_for_live_sdk : String
  can_run_proof_session : String
  can_run_robot_routine : String
  physical_execution_allowed : String
  robot_id : String
  bridge_id : String
  runtime_status : String
  runtime_bridge_base_url : String
  runtime_health_path : String
  runtime_validation_session_path : String
  calibration_status : String
  calibration_path : String
  calibration_pending_revalidation : String
  proof_session_count : String
  latest_proof_session_path : String
  next_method : String
  next_route : String
  next_title : String
}

///|
struct PlatformProofSessionResult {
  message : String
  session_id : String
  session_path : String
  persisted : String
  status : String
  ready : String
  attempted_count : String
  requested_iterations : String
  stop_reason : String
  latest_proof_path : String
  next_route : String
  auto_feedback_attempted_count : String
  auto_feedback_success_count : String
  latest_auto_feedback_status : String
  latest_auto_feedback_message : String
}

///|
struct PlatformProofSessionListResult {
  message : String
  session_count : String
  sessions : Array[PlatformProofSessionResult]
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
struct RuntimeLogResult {
  active : String
  running : String
  status : String
  log_path : String
  exists : String
  truncated : String
  line_count : String
  max_lines : String
  tail : String
}

///|
struct RuntimeValidationResult {
  status : String
  ready_for_live_sdk : String
  persisted : String
  report_path : String
  latest_report_path : String
  calibration_path : String
  latest_calibration_path : String
  pass_count : String
  fail_count : String
  check_count : String
}

///|
struct RuntimeValidationSessionResult {
  message : String
  persisted : String
  sample_count : String
  session_path : String
  latest_session_path : String
  calibration_path : String
  latest_calibration_path : String
  status : String
  ready_for_live_sdk : String
  required_sample_count : String
  ready_sample_count : String
  blocked_sample_count : String
  first_blocker_code : String
  mapping_status : String
  mapping_stable : String
  mapping_matching_sample_count : String
  mapping_mismatch_sample_count : String
  mapping_message : String
  calibration_status : String
  calibration_action_count : String
  calibration_blocking_action_count : String
}

///|
struct RuntimeCalibrationActionResult {
  action_id : String
  blocker_code : String
  severity : String
  owner : String
  evidence_path : String
  summary : String
  next_step : String
}

///|
struct RuntimeCalibrationResult {
  message : String
  plan_id : String
  status : String
  runtime_id : String
  robot_id : String
  bridge_id : String
  action_count : String
  blocking_action_count : String
  actions : Array[RuntimeCalibrationActionResult]
}

///|
struct RuntimeCalibrationResolutionResult {
  message : String
  action_id : String
  blocker_code : String
  status : String
  resolution_path : String
  latest_resolution_path : String
  next_validation_route : String
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
  runtime_log_url : String
  runtime_validation_url : String
  runtime_validation_session_url : String
  runtime_calibration_resolution_url : String
  platform_readiness_url : String
  moonrobo_live_readiness_url : String
  platform_loop_proof_url : String
  platform_proof_session_url : String
  platform_proof_sessions_url : String
  platform_prove_loop_url : String
  task_executions_url : String
  platform_bootstrap_url : String
  platform_advance_url : String
  platform_runtime_proof_url : String
  runtime_supervisor_status : RuntimeSupervisorStatus
  latest_runtime_health : RuntimeHealthResult?
  latest_runtime_log : RuntimeLogResult?
  latest_runtime_validation : RuntimeValidationResult?
  latest_runtime_validation_session : RuntimeValidationSessionResult?
  latest_runtime_calibration : RuntimeCalibrationResult?
  latest_runtime_calibration_resolution : RuntimeCalibrationResolutionResult?
  latest_platform_readiness : @readiness.PlatformReadinessReport?
  latest_platform_readiness_plan : @readiness.PlatformReadinessPlan?
  latest_moonrobo_live_readiness : MoonroboLiveReadinessResult?
  latest_platform_loop_proof : PlatformLoopProofResult?
  latest_platform_proof_session : PlatformProofSessionResult?
  latest_platform_proof_sessions : PlatformProofSessionListResult?
  latest_task_execution_proof : TaskExecutionProofResult?
  work_queue : @work_queue.AgentWorkQueue
  next_action_url : String
  agent_dispatch_url : String
  next_action : @work_queue.AgentNextAction?
  intent_url : String
  dry_run_url : String
  approval_url : String
  execute_url : String
  task_message_url : String
  robo_session_url : String
  robo_loop_url : String
  robo_step_url : String
  robo_loops_url : String
  robo_turns_url : String
  robo_steps_url : String
  robot_routine_url : String
  task_message_ledger_url : String
  task_conversation_url : String
  observe_run_url : String
  moonclaw_context_url : String
  moonclaw_run_next_url : String
  evaluating : Bool
  collecting_dry_run : Bool
  approving : Bool
  executing : Bool
  submitting_task_message : Bool
  stepping_robo : Bool
  running_observation : Bool
  refreshing_process_plan : Bool
  preparing_runtime_launch : Bool
  starting_runtime : Bool
  stopping_runtime : Bool
  stopping_emergency : Bool
  validating_runtime_session : Bool
  resolving_runtime_calibration : Bool
  bootstrapping_platform : Bool
  advancing_platform : Bool
  proving_runtime : Bool
  proving_loop : Bool
  running_proof_session : Bool
  running_next_process : Bool
  resolving_review : Bool
  dispatching_next_action : Bool
  loading_task_message_review : Bool
  loading_task_messages : Bool
  loading_task_conversation : Bool
  intent_status : String
  observation_status : String
  task_message_status : String
  task_message_ledger_status : String
  task_conversation_status : String
  task_message_review_status : String
  robo_session_status : String
  robo_loop_history_status : String
  robo_turn_history_status : String
  robo_step_history_status : String
  process_status : String
  runtime_launch_status : String
  runtime_health_status : String
  runtime_log_status : String
  runtime_validation_status : String
  runtime_validation_session_status : String
  runtime_calibration_status : String
  platform_readiness_status : String
  moonrobo_live_readiness_status : String
  platform_loop_proof_status : String
  platform_proof_session_status : String
  platform_proof_sessions_status : String
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
  latest_task_message_ledger : TaskMessageLedgerResult?
  latest_task_conversation : TaskConversationResult?
  latest_task_message_review : TaskMessageReviewResult?
  latest_task_message_status : TaskMessageStatusResult?
  latest_task_loop : TaskLoopResult?
  latest_robo_session : RoboSessionResult?
  latest_robo_loop : RoboLoopResult?
  latest_robo_turn : RoboTurnResult?
  latest_robo_step : RoboStepResult?
  latest_robo_loop_history : RoboLoopHistoryResult?
  latest_robo_turn_history : RoboTurnHistoryResult?
  latest_robo_step_history : RoboStepHistoryResult?
  active_reviewed_intent : ReviewedIntentDraft?
  pending_task_message_task_id : String
  pending_task_message_stage : String
  focused_task_message_task_id : String
  latest_process_plan : MoonClawPlanResult?
}

///|
enum Msg {
  RefreshSnapshot
  SnapshotLoaded(Result[@cockpit.CockpitSnapshot, String])
  RuntimeSupervisorLoaded(Result[RuntimeSupervisorStatus, String])
  PollRuntimeHealth
  RuntimeHealthLoaded(Result[RuntimeHealthResult, String])
  RuntimeLogLoaded(Result[RuntimeLogResult, String])
  RuntimeValidationLoaded(Result[RuntimeValidationResult, String])
  ValidateRuntimeSession
  RuntimeValidationSessionLoaded(Result[RuntimeValidationSessionResult, String])
  RuntimeCalibrationLoaded(Result[RuntimeCalibrationResult, String])
  ResolveRuntimeCalibration
  RuntimeCalibrationResolved(Result[RuntimeCalibrationResolutionResult, String])
  PlatformReadinessLoaded(Result[PlatformReadinessResult, String])
  MoonroboLiveReadinessLoaded(Result[MoonroboLiveReadinessResult, String])
  PlatformLoopProofLoaded(Result[PlatformLoopProofResult, String])
  ProofSessionsLoaded(Result[PlatformProofSessionListResult, String])
  RunProofSession
  ProofSessionRan(Result[PlatformProofSessionResult, String])
  ProveLoop
  LoopProven(Result[PlatformLoopProofResult, String])
  TaskExecutionProofLoaded(Result[TaskExecutionProofResult, String])
  BootstrapPlatform
  PlatformBootstrapped(Result[CommandResult, String])
  AdvancePlatform
  PlatformAdvanced(Result[CommandResult, String])
  ProveRuntime
  RuntimeProven(Result[CommandResult, String])
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
  OpenTaskMessageReviewRoute(String)
  ContinueTaskMessage(String, String)
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
  RunTaskLoop
  RunRoboStep
  DispatchTaskLoop
  TaskLoopRan(Result[TaskLoopResult, String])
  RoboSessionLoaded(Result[RoboSessionResult, String])
  RoboLoopRan(Result[RoboLoopResult, String])
  RoboStepRan(Result[RoboStepResult, String])
  RoboLoopHistoryLoaded(Result[RoboLoopHistoryResult, String])
  RoboTurnHistoryLoaded(Result[RoboTurnHistoryResult, String])
  RoboStepHistoryLoaded(Result[RoboStepHistoryResult, String])
  RefreshTaskMessages
  TaskMessagesLoaded(Result[TaskMessageLedgerResult, String])
  TaskConversationLoaded(Result[TaskConversationResult, String])
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
fn default_robo_session_url() -> String {
  "/api/moonrobo/session"
}

///|
fn default_robo_loop_url() -> String {
  "/api/moonrobo/loop"
}

///|
fn default_robo_step_url() -> String {
  "/api/moonrobo/step"
}

///|
fn default_robo_turns_url() -> String {
  "/api/moonrobo/turns"
}

///|
fn default_robo_steps_url() -> String {
  "/api/moonrobo/steps"
}

///|
fn default_robo_loops_url() -> String {
  "/api/moonrobo/loops"
}

///|
fn default_robot_routine_url() -> String {
  "/api/moonclaw/robot-routine"
}

///|
fn default_task_message_ledger_url() -> String {
  "/api/moonbook/task-messages"
}

///|
fn default_task_conversation_url() -> String {
  "/api/moonbook/conversation"
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
fn default_runtime_log_url() -> String {
  "/api/runtime/log"
}

///|
fn default_runtime_validation_url() -> String {
  "/api/runtime/validation"
}

///|
fn default_runtime_validation_session_url() -> String {
  "/api/runtime/validation/session"
}

///|
fn default_runtime_calibration_resolution_url() -> String {
  "/api/agent/runtime-calibration/resolve"
}

///|
fn default_platform_readiness_url() -> String {
  "/api/moonrobo/readiness"
}

///|
fn default_moonrobo_live_readiness_url() -> String {
  "/api/moonrobo/live-readiness"
}

///|
fn default_platform_loop_proof_url() -> String {
  "/api/moonrobo/loop-proof"
}

///|
fn default_platform_proof_session_url() -> String {
  "/api/moonrobo/proof-session"
}

///|
fn default_platform_proof_sessions_url() -> String {
  "/api/moonrobo/proof-sessions"
}

///|
fn default_platform_prove_loop_url() -> String {
  "/api/moonrobo/prove-loop"
}

///|
fn default_task_executions_url() -> String {
  "/api/moonrobo/executions"
}

///|
fn default_platform_bootstrap_url() -> String {
  "/api/moonrobo/bootstrap"
}

///|
fn default_platform_advance_url() -> String {
  "/api/moonrobo/advance"
}

///|
fn default_platform_runtime_proof_url() -> String {
  "/api/moonrobo/runtime-proof"
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
    runtime_log_url: default_runtime_log_url(),
    runtime_validation_url: default_runtime_validation_url(),
    runtime_validation_session_url: default_runtime_validation_session_url(),
    runtime_calibration_resolution_url: default_runtime_calibration_resolution_url(),
    platform_readiness_url: default_platform_readiness_url(),
    moonrobo_live_readiness_url: default_moonrobo_live_readiness_url(),
    platform_loop_proof_url: default_platform_loop_proof_url(),
    platform_proof_session_url: default_platform_proof_session_url(),
    platform_proof_sessions_url: default_platform_proof_sessions_url(),
    platform_prove_loop_url: default_platform_prove_loop_url(),
    task_executions_url: default_task_executions_url(),
    platform_bootstrap_url: default_platform_bootstrap_url(),
    platform_advance_url: default_platform_advance_url(),
    platform_runtime_proof_url: default_platform_runtime_proof_url(),
    runtime_supervisor_status: sample_runtime_supervisor_status(),
    latest_runtime_health: None,
    latest_runtime_log: None,
    latest_runtime_validation: None,
    latest_runtime_validation_session: None,
    latest_runtime_calibration: None,
    latest_runtime_calibration_resolution: None,
    latest_platform_readiness: None,
    latest_platform_readiness_plan: None,
    latest_moonrobo_live_readiness: None,
    latest_platform_loop_proof: None,
    latest_platform_proof_session: None,
    latest_platform_proof_sessions: None,
    latest_task_execution_proof: None,
    work_queue: sample_work_queue(),
    next_action_url: default_next_action_url(),
    agent_dispatch_url: default_agent_dispatch_url(),
    next_action: sample_next_action(),
    intent_url: default_intent_url(),
    dry_run_url: default_dry_run_url(),
    approval_url: default_approval_url(),
    execute_url: default_execute_url(),
    task_message_url: default_task_message_url(),
    robo_session_url: default_robo_session_url(),
    robo_loop_url: default_robo_loop_url(),
    robo_step_url: default_robo_step_url(),
    robo_loops_url: default_robo_loops_url(),
    robo_turns_url: default_robo_turns_url(),
    robo_steps_url: default_robo_steps_url(),
    robot_routine_url: default_robot_routine_url(),
    task_message_ledger_url: default_task_message_ledger_url(),
    task_conversation_url: default_task_conversation_url(),
    observe_run_url: default_observe_run_url(),
    moonclaw_context_url: default_moonclaw_context_url(),
    moonclaw_run_next_url: default_moonclaw_run_next_url(),
    evaluating: false,
    collecting_dry_run: false,
    approving: false,
    executing: false,
    submitting_task_message: false,
    stepping_robo: false,
    running_observation: false,
    refreshing_process_plan: false,
    preparing_runtime_launch: false,
    starting_runtime: false,
    stopping_runtime: false,
    stopping_emergency: false,
    validating_runtime_session: false,
    resolving_runtime_calibration: false,
    bootstrapping_platform: false,
    advancing_platform: false,
    proving_runtime: false,
    proving_loop: false,
    running_proof_session: false,
    running_next_process: false,
    resolving_review: false,
    dispatching_next_action: false,
    loading_task_message_review: false,
    loading_task_messages: false,
    loading_task_conversation: false,
    intent_status: "No command submitted",
    observation_status: "No observation run submitted",
    task_message_status: "No task message submitted",
    task_message_ledger_status: "No task-message ledger loaded",
    task_conversation_status: "No Robo conversation loaded",
    task_message_review_status: "No task-message review loaded",
    robo_session_status: "No Robo session loaded",
    robo_loop_history_status: "No Robo loop history loaded",
    robo_turn_history_status: "No Robo turn history loaded",
    robo_step_history_status: "No Robo step history loaded",
    process_status: "No process plan loaded",
    runtime_launch_status: "Runtime launch not prepared",
    runtime_health_status: "Runtime health not polled",
    runtime_log_status: "Runtime log not polled",
    runtime_validation_status: "Runtime validation not polled",
    runtime_validation_session_status: "Runtime validation session not run",
    runtime_calibration_status: "Runtime calibration not loaded",
    platform_readiness_status: "Platform readiness not loaded",
    moonrobo_live_readiness_status: "Live readiness not loaded",
    platform_loop_proof_status: "Loop proof not loaded",
    platform_proof_session_status: "Proof session not run",
    platform_proof_sessions_status: "Proof-session history not loaded",
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
    latest_task_message_ledger: None,
    latest_task_conversation: None,
    latest_task_message_review: None,
    latest_task_message_status: None,
    latest_task_loop: None,
    latest_robo_session: None,
    latest_robo_loop: None,
    latest_robo_turn: None,
    latest_robo_step: None,
    latest_robo_loop_history: None,
    latest_robo_turn_history: None,
    latest_robo_step_history: None,
    active_reviewed_intent: None,
    pending_task_message_task_id: "",
    pending_task_message_stage: "",
    focused_task_message_task_id: "",
    latest_process_plan: None,
  }
}

///|
fn latest_step_from_loop(steps : Array[RoboStepResult]) -> RoboStepResult? {
  if steps.is_empty() {
    None
  } else {
    steps.get(steps.length() - 1)
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
        @rabbita.batch([
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
        ]),
        { ..model, runtime_supervisor_status: status },
      )
    RuntimeSupervisorLoaded(Err(error)) =>
      (
        @rabbita.batch([
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
        ]),
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
          fetch_runtime_log(dispatch, model.runtime_log_url),
          fetch_runtime_validation(dispatch, model.runtime_validation_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          schedule_runtime_health_poll(dispatch),
        ]),
        {
          ..model,
          runtime_health_status: "Polling runtime health",
          runtime_validation_status: "Polling runtime validation",
          platform_readiness_status: "Loading platform readiness",
          moonrobo_live_readiness_status: "Loading live readiness",
          robo_session_status: "Loading Robo session",
          robo_loop_history_status: "Loading Robo loop history",
          robo_turn_history_status: "Loading Robo turn history",
        },
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
    RuntimeLogLoaded(Ok(log)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_runtime_log: Some(log),
          runtime_log_status: if log.exists == "true" {
            "Runtime log \{log.status}; \{log.line_count} lines"
          } else {
            "Runtime log unavailable"
          },
        },
      )
    RuntimeLogLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, runtime_log_status: "Runtime log rejected: \{error}" },
      )
    RuntimeValidationLoaded(Ok(validation)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_runtime_validation: Some(validation),
          runtime_validation_status: "Runtime validation \{validation.status}; failures \{validation.fail_count}",
        },
      )
    RuntimeValidationLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          runtime_validation_status: "Runtime validation rejected: \{error}",
        },
      )
    ValidateRuntimeSession =>
      (
        submit_runtime_validation_session(
          dispatch,
          model.runtime_validation_session_url,
        ),
        {
          ..model,
          validating_runtime_session: true,
          runtime_validation_session_status: "Running runtime validation session",
        },
      )
    RuntimeValidationSessionLoaded(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_runtime_validation(dispatch, model.runtime_validation_url),
          fetch_runtime_calibration(
            dispatch,
            "/api/agent/runtime-calibration/latest",
          ),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
        ]),
        {
          ..model,
          validating_runtime_session: false,
          latest_runtime_validation_session: Some(result),
          runtime_validation_session_status: result.message,
          runtime_validation_status: result.message,
        },
      )
    RuntimeValidationSessionLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          validating_runtime_session: false,
          runtime_validation_session_status: "Runtime validation session rejected: \{error}",
        },
      )
    PlatformReadinessLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_platform_readiness: Some(result.report),
          latest_platform_readiness_plan: result.plan,
          platform_readiness_status: "Platform readiness \{result.report.status}; \{result.report.pass_count} pass / \{result.report.fail_count} fail",
        },
      )
    PlatformReadinessLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          platform_readiness_status: "Platform readiness rejected: \{error}",
        },
      )
    MoonroboLiveReadinessLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_moonrobo_live_readiness: Some(result),
          moonrobo_live_readiness_status: "Live readiness \{result.status}; next \{result.next_method} \{result.next_route}",
        },
      )
    MoonroboLiveReadinessLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          moonrobo_live_readiness_status: "Live readiness rejected: \{error}",
        },
      )
    PlatformLoopProofLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_platform_loop_proof: Some(result),
          platform_loop_proof_status: "Loop proof \{result.status}; \{result.completed_count} / \{result.total_count} checks; \{result.percent}%",
        },
      )
    PlatformLoopProofLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          platform_loop_proof_status: "Loop proof rejected: \{error}",
        },
      )
    ProofSessionsLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_platform_proof_sessions: Some(result),
          platform_proof_sessions_status: result.message,
        },
      )
    ProofSessionsLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          platform_proof_sessions_status: "Proof-session history rejected: \{error}",
        },
      )
    RunProofSession =>
      (
        submit_platform_proof_session(
          dispatch,
          model.platform_proof_session_url,
          model,
        ),
        {
          ..model,
          running_proof_session: true,
          platform_proof_session_status: "Running sustained proof session",
        },
      )
    ProofSessionRan(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          running_proof_session: false,
          latest_platform_proof_session: Some(result),
          platform_proof_session_status: "Proof session \{result.status}; \{result.attempted_count} / \{result.requested_iterations} attempt(s)",
        },
      )
    ProofSessionRan(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          running_proof_session: false,
          platform_proof_session_status: "Proof session rejected: \{error}",
        },
      )
    ProveLoop =>
      (
        submit_platform_prove_loop(
          dispatch,
          model.platform_prove_loop_url,
          model,
        ),
        {
          ..model,
          proving_loop: true,
          platform_loop_proof_status: "Proving closed loop",
        },
      )
    LoopProven(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          proving_loop: false,
          latest_platform_loop_proof: Some(result),
          platform_loop_proof_status: "Loop proof \{result.status}; \{result.completed_count} / \{result.total_count} checks; \{result.percent}%",
        },
      )
    LoopProven(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          proving_loop: false,
          platform_loop_proof_status: "Loop proof rejected: \{error}",
        },
      )
    TaskExecutionProofLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_task_execution_proof: Some(result),
        },
      )
    TaskExecutionProofLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_task_execution_proof: Some({
            message: "Execution proof rejected: \{error}",
            execution_count: "0",
            verified_count: "0",
            latest_snapshot_id: "",
            latest_status: "error",
            latest_task_id: "-",
            latest_bridge_status: "-",
            latest_runtime_status: "-",
            latest_runtime_health_persisted: "false",
          }),
        },
      )
    BootstrapPlatform =>
      (
        submit_platform_bootstrap(dispatch, model.platform_bootstrap_url),
        {
          ..model,
          bootstrapping_platform: true,
          platform_readiness_status: "Bootstrapping non-physical platform substrate",
        },
      )
    PlatformBootstrapped(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
        ]),
        {
          ..model,
          bootstrapping_platform: false,
          platform_readiness_status: result.message,
        },
      )
    PlatformBootstrapped(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          bootstrapping_platform: false,
          platform_readiness_status: "Platform bootstrap rejected: \{error}",
        },
      )
    AdvancePlatform =>
      (
        submit_platform_advance(dispatch, model.platform_advance_url),
        {
          ..model,
          advancing_platform: true,
          platform_readiness_status: "Advancing reviewed task-message gate",
        },
      )
    PlatformAdvanced(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          advancing_platform: false,
          platform_readiness_status: result.message,
        },
      )
    PlatformAdvanced(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          advancing_platform: false,
          platform_readiness_status: "Platform advance rejected: \{error}",
        },
      )
    ProveRuntime =>
      (
        submit_platform_runtime_proof(
          dispatch,
          model.platform_runtime_proof_url,
          model,
        ),
        {
          ..model,
          proving_runtime: true,
          platform_readiness_status: "Submitting one-to-one runtime proof",
        },
      )
    RuntimeProven(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_moonrobo_live_readiness(
            dispatch,
            model.moonrobo_live_readiness_url,
          ),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_platform_proof_sessions(
            dispatch,
            model.platform_proof_sessions_url,
          ),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_runtime_health(dispatch, model.runtime_health_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          proving_runtime: false,
          platform_readiness_status: result.message,
          runtime_health_status: result.message,
        },
      )
    RuntimeProven(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          proving_runtime: false,
          platform_readiness_status: "Runtime proof rejected: \{error}",
        },
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
          fetch_runtime_log(dispatch, model.runtime_log_url),
          fetch_runtime_validation(dispatch, model.runtime_validation_url),
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
          fetch_runtime_log(dispatch, model.runtime_log_url),
          fetch_runtime_validation(dispatch, model.runtime_validation_url),
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
          fetch_runtime_log(dispatch, model.runtime_log_url),
          fetch_runtime_validation(dispatch, model.runtime_validation_url),
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
        runtime_calibration_command_for_action(dispatch, plan.action),
        {
          ..model,
          work_queue: plan.queue,
          next_action: plan.action,
          work_queue_status: "Loaded \{plan.queue.item_count} work item(s)",
          latest_runtime_calibration: match plan.action {
            Some(action) if action.kind == "calibrate-runtime" =>
              model.latest_runtime_calibration
            _ => None
          },
          runtime_calibration_status: match plan.action {
            Some(action) if action.kind == "calibrate-runtime" =>
              "Loading runtime calibration plan"
            _ => "Runtime calibration not loaded"
          },
        },
      )
    NextActionLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, work_queue_status: "Next action rejected: \{error}" },
      )
    RuntimeCalibrationLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_runtime_calibration: Some(result),
          runtime_calibration_status: result.message,
        },
      )
    RuntimeCalibrationLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          runtime_calibration_status: "Runtime calibration rejected: \{error}",
        },
      )
    ResolveRuntimeCalibration =>
      (
        submit_runtime_calibration_resolution(
          dispatch,
          model.runtime_calibration_resolution_url,
          model,
        ),
        {
          ..model,
          resolving_runtime_calibration: true,
          runtime_calibration_status: "Persisting runtime calibration resolution",
        },
      )
    RuntimeCalibrationResolved(Ok(result)) =>
      (
        @rabbita.batch([
          submit_runtime_validation_session(
            dispatch,
            result.next_validation_route,
          ),
          fetch_next_action(dispatch, model.next_action_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
        ]),
        {
          ..model,
          resolving_runtime_calibration: false,
          validating_runtime_session: true,
          latest_runtime_calibration_resolution: Some(result),
          runtime_calibration_status: result.message,
          runtime_validation_session_status: "Revalidating after runtime calibration resolution",
        },
      )
    RuntimeCalibrationResolved(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          resolving_runtime_calibration: false,
          runtime_calibration_status: "Runtime calibration resolution rejected: \{error}",
        },
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
    OpenTaskMessageReviewRoute(route) =>
      (
        fetch_task_message_review(dispatch, route),
        {
          ..model,
          loading_task_message_review: true,
          task_message_review_status: "Loading task-message review",
        },
      )
    ContinueTaskMessage(task_id, stage) =>
      if !task_message_stage_is_continuable(stage) {
        (
          @rabbita.none,
          {
            ..model,
            task_message_review_status: "Task message \{task_id} has no runnable next step",
          },
        )
      } else {
        let next_model = {
          ..model,
          pending_task_message_task_id: task_id,
          pending_task_message_stage: stage,
        }
        match model.latest_task_message_review {
          Some(review) if review.task_id == task_id =>
            (
              fetch_task_message_status(
                dispatch,
                task_message_status_route(task_id),
              ),
              {
                ..next_model,
                active_reviewed_intent: review.intent_draft,
                task_message_review_status: "Checking task-message next step",
              },
            )
          _ =>
            (
              fetch_task_message_review(
                dispatch,
                task_message_detail_route(task_id),
              ),
              {
                ..next_model,
                loading_task_message_review: true,
                task_message_review_status: "Opening task-message next step",
              },
            )
        }
      }
    TaskMessageReviewLoaded(Ok(result)) =>
      (
        fetch_task_message_status(dispatch, task_message_status_route(result.task_id)),
        {
          ..model,
          loading_task_message_review: false,
          task_message_review_status: result.message,
          latest_task_message_review: Some(result),
          active_reviewed_intent: result.intent_draft,
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
        if model.pending_task_message_task_id == result.task_id {
          continue_task_message_step(dispatch, next_model, result)
        } else if should_auto_dispatch_task_message(model, result) {
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
          task_message_status: "Saving task message",
        },
      )
    TaskMessageSubmitted(Ok(result)) =>
      {
        let auto_review = task_message_result_requires_review(result)
        let commands = if auto_review {
          [
            fetch_snapshot(dispatch, model.source_url),
            fetch_task_messages(dispatch, model.task_message_ledger_url),
            fetch_task_conversation(dispatch, model.task_conversation_url),
            fetch_task_message_review(
              dispatch,
              task_message_detail_route(result.task_id),
            ),
          ]
        } else {
          [
            fetch_snapshot(dispatch, model.source_url),
            fetch_task_messages(dispatch, model.task_message_ledger_url),
            fetch_task_conversation(dispatch, model.task_conversation_url),
          ]
        }
        (
          @rabbita.batch(commands),
          {
            ..model,
            loading: true,
            submitting_task_message: false,
            loading_task_message_review: auto_review,
            task_message_status: result.message,
            task_message_review_status: if auto_review {
              "Opening submitted task-message review"
            } else {
              model.task_message_review_status
            },
            latest_task_message: Some(result),
            focused_task_message_task_id: result.task_id,
          },
        )
      }
    TaskMessageSubmitted(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          submitting_task_message: false,
          task_message_status: "Task message rejected: \{error}",
        },
      )
    RunTaskLoop =>
      (
        submit_robo_loop(dispatch, model.robo_loop_url, model),
        {
          ..model,
          submitting_task_message: true,
          task_message_status: "Running Robo loop",
          robo_session_status: "Running canonical Robo loop",
          platform_readiness_status: "Running bounded Moonrobo product loop",
        },
      )
    RunRoboStep =>
      (
        submit_robo_step(dispatch, model.robo_step_url, model),
        {
          ..model,
          stepping_robo: true,
          robo_session_status: "Advancing current Robo decision",
          task_message_status: "Stepping Robo",
        },
      )
    DispatchTaskLoop =>
      (
        submit_robot_routine(dispatch, model.robot_routine_url, model),
        {
          ..model,
          submitting_task_message: true,
          task_message_status: "Asking Robo through MoonClaw routine",
          platform_readiness_status: "Running MoonClaw robot routine through canonical loop",
        },
      )
    TaskLoopRan(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          loading: true,
          submitting_task_message: false,
          task_message_status: result.message,
          platform_readiness_status: result.message,
          latest_task_loop: Some(result),
          focused_task_message_task_id: result.task_id,
        },
      )
    TaskLoopRan(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          submitting_task_message: false,
          task_message_status: "Robo routine rejected: \{error}",
          platform_readiness_status: "Robo routine rejected: \{error}",
        },
      )
    RoboSessionLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_robo_session: Some(result),
          robo_session_status: "Robo session \{result.status}; stage \{result.session.stage}; loops \{result.loop_count}; turns \{result.turn_count}; steps \{result.step_count}",
        },
      )
    RoboSessionLoaded(Err(error)) =>
      (
        @rabbita.none,
        { ..model, robo_session_status: "Robo session rejected: \{error}" },
      )
    RoboLoopRan(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          loading: true,
          submitting_task_message: false,
          task_message_status: result.message,
          robo_session_status: "Robo loop \{result.status}; advanced \{result.advanced_count}; next \{result.final_owner} \{result.final_route}",
          latest_robo_loop: Some(result),
          latest_robo_turn: result.turn,
          latest_robo_step: latest_step_from_loop(result.steps),
          focused_task_message_task_id: match result.turn {
            Some(turn) => turn.task_id
            None => model.focused_task_message_task_id
          },
        },
      )
    RoboLoopRan(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          submitting_task_message: false,
          task_message_status: "Robo loop rejected: \{error}",
          robo_session_status: "Robo loop rejected: \{error}",
        },
      )
    RoboStepRan(Ok(result)) =>
      (
        @rabbita.batch([
          fetch_snapshot(dispatch, model.source_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_platform_readiness(dispatch, model.platform_readiness_url),
          fetch_platform_loop_proof(dispatch, model.platform_loop_proof_url),
          fetch_task_execution_proof(dispatch, model.task_executions_url),
          fetch_moonstat_status(dispatch, model.moonstat_url),
          fetch_next_action(dispatch, model.next_action_url),
        ]),
        {
          ..model,
          loading: true,
          stepping_robo: false,
          task_message_status: result.message,
          robo_session_status: "Robo step \{result.status}; next \{result.after_owner} \{result.after_route}",
          latest_robo_step: Some(result),
        },
      )
    RoboStepRan(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          stepping_robo: false,
          task_message_status: "Robo step rejected: \{error}",
          robo_session_status: "Robo step rejected: \{error}",
        },
      )
    RoboLoopHistoryLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_robo_loop_history: Some(result),
          robo_loop_history_status: result.message,
        },
      )
    RoboLoopHistoryLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          robo_loop_history_status: "Robo loop history rejected: \{error}",
        },
      )
    RoboTurnHistoryLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_robo_turn_history: Some(result),
          robo_turn_history_status: result.message,
        },
      )
    RoboTurnHistoryLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          robo_turn_history_status: "Robo turn history rejected: \{error}",
        },
      )
    RoboStepHistoryLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          latest_robo_step_history: Some(result),
          robo_step_history_status: result.message,
        },
      )
    RoboStepHistoryLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          robo_step_history_status: "Robo step history rejected: \{error}",
        },
      )
    RefreshTaskMessages =>
      (
        @rabbita.batch([
          fetch_task_messages(dispatch, model.task_message_ledger_url),
          fetch_task_conversation(dispatch, model.task_conversation_url),
          fetch_robo_session(dispatch, model.robo_session_url),
          fetch_robo_loop_history(dispatch, model.robo_loops_url),
          fetch_robo_turn_history(dispatch, model.robo_turns_url),
          fetch_robo_step_history(dispatch, model.robo_steps_url),
        ]),
        {
          ..model,
          loading_task_messages: true,
          loading_task_conversation: true,
          task_message_ledger_status: "Loading task-message ledger",
          task_conversation_status: "Loading Robo conversation",
          robo_session_status: "Loading Robo session",
          robo_loop_history_status: "Loading Robo loop history",
          robo_turn_history_status: "Loading Robo turn history",
          robo_step_history_status: "Loading Robo step history",
        },
      )
    TaskMessagesLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading_task_messages: false,
          task_message_ledger_status: result.message,
          latest_task_message_ledger: Some(result),
        },
      )
    TaskMessagesLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading_task_messages: false,
          task_message_ledger_status: "Task-message ledger rejected: \{error}",
        },
      )
    TaskConversationLoaded(Ok(result)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading_task_conversation: false,
          task_conversation_status: result.message,
          latest_task_conversation: Some(result),
        },
      )
    TaskConversationLoaded(Err(error)) =>
      (
        @rabbita.none,
        {
          ..model,
          loading_task_conversation: false,
          task_conversation_status: "Robo conversation rejected: \{error}",
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
    "ok" | "ready" | "fresh" | "ready-for-execution" | "launchable" | "healthy" | "proposal-only" | "Observe" | "evaluate-policy" | "clear" | "bridge-ready" | "completed" =>
      "ok"
    "needs-evaluation" | "needs-dry-run" | "needs-approval" | "ready-to-dispatch" | "dry-run-required" | "waiting-for-dry-run" | "approval-required" | "waiting-for-approval" | "stale" | "missing-command" | "degraded" | "requires-dry-run" | "requires-approval" | "ReviewEvidence" | "start-runtime" | "connect-bridge" | "review-evidence" | "annotate-replay" | "repair-dataset" | "dry-run-policy-proposal" | "approve-policy-proposal" | "collector-ready" | "command-intent-review" | "maintenance-review" =>
      "warning"
    "runtime-required" | "runtime-unhealthy" | "blocked" | "blocked-quality" | "blocked-safety" | "error" | "not-ready" | "attention" | "Hold" | "repair-policy-quality" | "review-policy-safety" =>
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
fn task_message_result_requires_review(result : TaskMessageResult) -> Bool {
  result.requires_review == "true"
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
fn task_message_stage_is_continuable(stage : String) -> Bool {
  match stage {
    "needs-evaluation" | "needs-dry-run" | "needs-approval" | "runtime-required" | "runtime-unhealthy" | "ready-to-dispatch" =>
      true
    _ => false
  }
}

///|
fn clear_pending_task_message(model : AppModel) -> AppModel {
  { ..model, pending_task_message_task_id: "", pending_task_message_stage: "" }
}

///|
fn task_message_continue_button_label(
  model : AppModel,
  task_id : String,
  stage : String,
) -> String {
  if model.pending_task_message_stage == stage &&
    model.pending_task_message_task_id == task_id {
    "Continuing..."
  } else {
    match stage {
      "needs-evaluation" => "Evaluate"
      "needs-dry-run" => "Dry Run"
      "needs-approval" => "Approve"
      "runtime-required" => "Start Runtime"
      "runtime-unhealthy" => "Check Runtime"
      "ready-to-dispatch" => "Execute"
      _ => "Continue"
    }
  }
}

///|
fn continue_task_message_step(
  dispatch : (Msg) -> @rabbita.Cmd,
  model : AppModel,
  status : TaskMessageStatusResult,
) -> (@rabbita.Cmd, AppModel) {
  let cleared = clear_pending_task_message(model)
  match (status.stage, model.latest_task_message_review) {
    ("runtime-required", _) =>
      (
        submit_runtime_start(dispatch, model.runtime_supervisor_start_url),
        {
          ..cleared,
          starting_runtime: true,
          runtime_launch_status: "Starting runtime for reviewed task",
        },
      )
    ("runtime-unhealthy", _) =>
      (
        fetch_runtime_health(dispatch, model.runtime_health_url),
        {
          ..cleared,
          runtime_health_status: "Refreshing runtime health for reviewed task",
        },
      )
    (_, Some({ task_id, intent_draft: Some(draft), .. })) if task_id == status.task_id => {
      let active_model = { ..cleared, active_reviewed_intent: Some(draft) }
      match status.stage {
        "needs-evaluation" =>
          (
            submit_intent(
              dispatch,
              task_message_evaluate_route(status.task_id),
              active_model,
              receipt_id=draft.receipt_id,
            ),
            {
              ..active_model,
              evaluating: true,
              intent_status: "Evaluating reviewed task intent",
            },
          )
        "needs-dry-run" =>
          (
            submit_intent(
              dispatch,
              task_message_action_route(status.task_id, "dry-run"),
              active_model,
              receipt_id=active_receipt_id(active_model, "dry-run"),
            ),
            {
              ..active_model,
              collecting_dry_run: true,
              intent_status: "Collecting reviewed task dry-run evidence",
            },
          )
        "needs-approval" =>
          (
            submit_intent(
              dispatch,
              task_message_action_route(status.task_id, "approve"),
              active_model,
              receipt_id=active_receipt_id(active_model, "approval"),
            ),
            {
              ..active_model,
              approving: true,
              intent_status: "Recording reviewed task approval",
            },
          )
        "ready-to-dispatch" =>
          (
            submit_intent(
              dispatch,
              task_message_action_route(status.task_id, "execute"),
              active_model,
              receipt_id=active_receipt_id(active_model, "executed"),
            ),
            {
              ..active_model,
              executing: true,
              intent_status: "Dispatching reviewed task through healthy runtime",
            },
          )
        _ =>
          (
            @rabbita.none,
            {
              ..active_model,
              task_message_review_status: "Task message \{status.task_id} has no runnable next step",
            },
          )
      }
    }
    _ =>
      (
        @rabbita.none,
        {
          ..cleared,
          task_message_review_status: "Task message \{status.task_id} does not include a runnable intent draft",
        },
      )
  }
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
fn task_message_detail_route(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}"
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
