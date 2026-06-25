///|
pub fn agent_work_queue_path() -> String {
  "/api/agent/work-queue"
}

///|
pub fn agent_next_action_path() -> String {
  "/api/agent/next-action"
}

///|
pub fn agent_dispatch_next_path() -> String {
  "/api/agent/dispatch-next"
}

///|
pub fn agent_runtime_calibration_path() -> String {
  "/api/agent/runtime-calibration/latest"
}

///|
pub fn agent_runtime_calibration_resolve_path() -> String {
  "/api/agent/runtime-calibration/resolve"
}

///|
pub(all) struct RuntimeCalibrationActionRecord {
  action_id : String
  blocker_code : String
  severity : String
  owner : String
  evidence_path : String
  summary : String
  next_step : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationPlanRecord {
  plan_id : String
  generated_at_ms : Int64
  session_id : String
  runtime_id : String
  robot_id : String
  bridge_id : String
  status : String
  action_count : Int
  blocking_action_count : Int
  actions : Array[RuntimeCalibrationActionRecord]
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct RuntimeValidationSessionRecord {
  generated_at_ms : Int64
  ready_for_live_sdk : Bool
} derive(FromJson)

///|
pub(all) struct AgentDispatchRequest {
  work_id : String
  body : Json?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AgentDispatchResponse {
  dispatched : Bool
  action : @work_queue.AgentNextAction
  request_body : Json
  downstream_status : Int
  downstream : Json
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationResolutionRequest {
  action_id : String
  resolved_by : String
  resolved_at_ms : Int64
  note : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationResolutionRecord {
  resolution_id : String
  plan_id : String
  action_id : String
  blocker_code : String
  owner : String
  resolved_by : String
  resolved_at_ms : Int64
  note : String
  evidence_path : String
  next_validation_route : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationResolutionResponse {
  persisted : Bool
  plan_path : String
  resolution_path : String
  latest_resolution_path : String
  plan : RuntimeCalibrationPlanRecord
  action : RuntimeCalibrationActionRecord
  resolution : RuntimeCalibrationResolutionRecord
} derive(Debug, Eq, ToJson, FromJson)

///|
fn dataset_work_evidence_or_response(
  root : String,
  session : @core.ObservationSession,
) -> Result[@work_queue.DatasetWorkEvidence, HostApiResponse] {
  let episode = match build_dataset_episode(root, session.session_id) {
    Ok(episode) => episode
    Err(response) => return Err(response)
  }
  Ok(
    @work_queue.dataset_work_evidence(episode, @dataset.quality_report(episode)),
  )
}

///|
fn dataset_work_evidence_list(
  root : String,
  sessions : Array[@core.ObservationSession],
) -> Result[Array[@work_queue.DatasetWorkEvidence], HostApiResponse] {
  let evidence : Array[@work_queue.DatasetWorkEvidence] = []
  for session in sessions {
    if session.status == Stopped {
      match dataset_work_evidence_or_response(root, session) {
        Ok(value) => evidence.push(value)
        Err(response) => return Err(response)
      }
    }
  }
  Ok(evidence)
}

///|
fn task_message_work_evidence_list(
  root : String,
) -> Result[Array[@work_queue.TaskMessageWorkEvidence], HostApiResponse] {
  let paths = match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let evidence : Array[@work_queue.TaskMessageWorkEvidence] = []
  for path in paths {
    let text = match @runtime.read_moonbook_task_message_json_file(path) {
      Ok(text) => text
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
    let json = @json.parse(text) catch {
      _ =>
        return Err(
          error_response(
            500, "parse-task-message-plan", path, "failed to parse MoonBook task message plan",
          ),
        )
    }
    let plan : @task.RobotTaskMessagePlan = @json.from_json(json) catch {
      _ =>
        return Err(
          error_response(
            500, "decode-task-message-plan", path, "failed to decode MoonBook task message plan",
          ),
        )
    }
    evidence.push(task_message_work_evidence(root, path, plan))
  }
  Ok(evidence)
}

///|
fn latest_runtime_calibration_json(
  root : String,
) -> Result[Json, HostApiResponse] {
  let path = @runtime.latest_runtime_calibration_plan_path(root)
  if !@fsx.path_exists(path) {
    return Err(
      error_response(
        404, "runtime-calibration-missing", path, "latest runtime calibration plan is not persisted",
      ),
    )
  }
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        error_response(
          500, "read-runtime-calibration", path, "failed to read latest runtime calibration plan",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-runtime-calibration", path, "failed to parse latest runtime calibration plan",
        ),
      )
  }
  Ok(json)
}

///|
fn latest_runtime_calibration_resolution(
  root : String,
) -> RuntimeCalibrationResolutionRecord? {
  let path = @runtime.latest_runtime_calibration_resolution_path(root)
  if !@fsx.path_exists(path) {
    return None
  }
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
fn latest_runtime_validation_session(
  root : String,
) -> RuntimeValidationSessionRecord? {
  let path = @runtime.latest_runtime_validation_session_path(root)
  if !@fsx.path_exists(path) {
    return None
  }
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
fn calibration_pending_revalidation(
  root : String,
  plan : RuntimeCalibrationPlanRecord,
) -> RuntimeCalibrationResolutionRecord? {
  let resolution = match latest_runtime_calibration_resolution(root) {
    Some(value) if value.plan_id == plan.plan_id &&
      value.status == "resolved-pending-validation" => value
    _ => return None
  }
  match latest_runtime_validation_session(root) {
    Some(session) if session.generated_at_ms > resolution.resolved_at_ms => None
    _ => Some(resolution)
  }
}

///|
fn calibration_cleared_by_ready_session(
  root : String,
  plan : RuntimeCalibrationPlanRecord,
) -> Bool {
  match latest_runtime_validation_session(root) {
    Some(session) =>
      session.ready_for_live_sdk &&
      session.generated_at_ms > plan.generated_at_ms
    None => false
  }
}

///|
fn latest_runtime_calibration_work(
  root : String,
) -> Result[@work_queue.RuntimeCalibrationWorkEvidence?, HostApiResponse] {
  let path = @runtime.latest_runtime_calibration_plan_path(root)
  if !@fsx.path_exists(path) {
    return Ok(None)
  }
  let json = match latest_runtime_calibration_json(root) {
    Ok(json) => json
    Err(response) => return Err(response)
  }
  let plan : RuntimeCalibrationPlanRecord = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-runtime-calibration", path, "failed to decode latest runtime calibration plan",
        ),
      )
  }
  if plan.actions.is_empty() || calibration_cleared_by_ready_session(root, plan) {
    Ok(None)
  } else {
    let action = plan.actions[0]
    let pending_resolution = calibration_pending_revalidation(root, plan)
    Ok(
      Some(
        @work_queue.runtime_calibration_work_evidence(
          plan.plan_id,
          plan.status,
          plan.action_count,
          plan.blocking_action_count,
          action.action_id,
          action.blocker_code,
          action.owner,
          action.summary,
          action.next_step,
          agent_runtime_calibration_path(),
          pending_revalidation=pending_resolution is Some(_),
          resolution_id=match pending_resolution {
            Some(resolution) => resolution.resolution_id
            None => ""
          },
          resolution_status=match pending_resolution {
            Some(resolution) => resolution.status
            None => ""
          },
          validation_path=runtime_validation_session_path(),
        ),
      ),
    )
  }
}

///|
pub fn bridge_contract_validation_work(
  root : String,
  book : @runtime.LoadedRoboBook,
  resident : @resident.ResidentRobotAgent,
) -> @work_queue.RuntimeCalibrationWorkEvidence? {
  if resident.availability != "ready" && !latest_runtime_running(root) {
    return None
  }
  let report = @readiness.report(root, book)
  for check in report.checks {
    if check.code == "bridge-contract-ready" && check.status == "fail" {
      return Some(
        @work_queue.runtime_calibration_work_evidence(
          "readiness-\{book.profile.id}-bridge-contract",
          "needs-validation",
          1,
          1,
          "persist-live-bridge-contract",
          "bridge-contract-ready",
          "bridge",
          check.message,
          "Run repeated runtime validation so Moonrobo persists the live bridge authority contract before physical dispatch",
          @runtime.latest_bridge_contract_path(root),
          pending_revalidation=true,
          validation_path=runtime_validation_session_path(),
        ),
      )
    }
  }
  None
}

///|
fn latest_runtime_running(root : String) -> Bool {
  match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) => record.active && record.running
    _ => false
  }
}

///|
fn latest_proof_session_work(
  root : String,
) -> Result[@work_queue.ProofSessionWorkEvidence?, HostApiResponse] {
  let proof = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return Err(response)
  }
  if proof.ready {
    Ok(None)
  } else {
    Ok(
      Some(
        @work_queue.proof_session_work_evidence(
          proof.status,
          proof.ready,
          proof.completed_count,
          proof.total_count,
          proof.percent,
          proof.next_route,
          proof.message,
        ),
      ),
    )
  }
}

///|
fn latest_robot_routine_work(
  root : String,
) -> @work_queue.RobotRoutineWorkEvidence? {
  let live : MoonroboLiveReadinessResponse = match
    decode_gateway_response(
      moonrobo_live_readiness_response(root),
      moonrobo_live_readiness_path(),
      "agent-robot-routine-readiness",
      "live readiness",
    ) {
    Ok(value) => value
    Err(_) => return None
  }
  let proof = match platform_loop_proof(root) {
    Ok(value) => value
    Err(_) => return None
  }
  if live.can_run_robot_routine && !proof.ready {
    Some(
      @work_queue.robot_routine_work_evidence(
        "ready-for-routine",
        true,
        moonclaw_robot_routine_path(),
        "Moonrobo live readiness is \{live.status}; run the closed MoonClaw robot routine before sustained proof.",
        latest_routine_path=proof.latest_routine_path,
      ),
    )
  } else {
    None
  }
}

///|
fn latest_live_exercise_work(
  root : String,
) -> @work_queue.LiveExerciseWorkEvidence? {
  let live : MoonroboLiveReadinessResponse = match
    decode_gateway_response(
      moonrobo_live_readiness_response(root),
      moonrobo_live_readiness_path(),
      "agent-live-exercise-readiness",
      "live readiness",
    ) {
    Ok(value) => value
    Err(_) => return None
  }
  if !live.can_run_robot_routine {
    return None
  }
  match latest_live_exercise_for_product(root) {
    Some(exercise) =>
      if exercise.closure.closed {
        None
      } else {
        Some(
          @work_queue.live_exercise_work_evidence(
            exercise.closure.status,
            exercise.closure.closed,
            exercise.closure.missing_count,
            if exercise.closure.next_route == "" {
              moonrobo_live_exercise_path()
            } else {
              exercise.closure.next_route
            },
            latest_exercise_path=exercise.exercise_path,
            message=exercise.closure.message,
          ),
        )
      }
    None =>
      Some(
        @work_queue.live_exercise_work_evidence(
          "missing",
          false,
          1,
          moonrobo_live_exercise_path(),
          message="No aggregate live exercise closure has been recorded for this live-ready robot loop.",
        ),
      )
  }
}

///|
pub fn runtime_calibration_response(root : String) -> HostApiResponse {
  match latest_runtime_calibration_json(root) {
    Ok(json) => json_response(200, json)
    Err(response) => response
  }
}

///|
fn runtime_calibration_action_for_request(
  plan : RuntimeCalibrationPlanRecord,
  action_id : String,
) -> Result[RuntimeCalibrationActionRecord, HostApiResponse] {
  if action_id == "" {
    match plan.actions.get(0) {
      Some(action) => Ok(action)
      None =>
        Err(
          error_response(
            409,
            "runtime-calibration-empty",
            plan.plan_id,
            "runtime calibration plan has no action to resolve",
          ),
        )
    }
  } else {
    for action in plan.actions {
      if action.action_id == action_id {
        return Ok(action)
      }
    }
    Err(
      error_response(
        404, "runtime-calibration-action-missing", action_id, "runtime calibration action is not in the latest plan",
      ),
    )
  }
}

///|
fn runtime_calibration_resolution_record(
  plan : RuntimeCalibrationPlanRecord,
  action : RuntimeCalibrationActionRecord,
  request : RuntimeCalibrationResolutionRequest,
) -> RuntimeCalibrationResolutionRecord {
  {
    resolution_id: "runtime-calibration-resolution-\{action.action_id}-\{request.resolved_at_ms}",
    plan_id: plan.plan_id,
    action_id: action.action_id,
    blocker_code: action.blocker_code,
    owner: action.owner,
    resolved_by: request.resolved_by,
    resolved_at_ms: request.resolved_at_ms,
    note: request.note,
    evidence_path: action.evidence_path,
    next_validation_route: runtime_validation_session_path(),
    status: "resolved-pending-validation",
  }
}

///|
pub fn runtime_calibration_resolve_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request_json = @json.parse(body) catch {
    _ =>
      return error_response(
        400,
        "parse-runtime-calibration-resolution",
        agent_runtime_calibration_resolve_path(),
        "failed to parse runtime calibration resolution request",
      )
  }
  let request : RuntimeCalibrationResolutionRequest = @json.from_json(
    request_json,
  ) catch {
    _ =>
      return error_response(
        400,
        "decode-runtime-calibration-resolution",
        agent_runtime_calibration_resolve_path(),
        "failed to decode runtime calibration resolution request",
      )
  }
  let plan_json = match latest_runtime_calibration_json(root) {
    Ok(json) => json
    Err(response) => return response
  }
  let plan_path = @runtime.latest_runtime_calibration_plan_path(root)
  let plan : RuntimeCalibrationPlanRecord = @json.from_json(plan_json) catch {
    _ =>
      return error_response(
        500, "decode-runtime-calibration", plan_path, "failed to decode latest runtime calibration plan",
      )
  }
  let action = match
    runtime_calibration_action_for_request(plan, request.action_id) {
    Ok(action) => action
    Err(response) => return response
  }
  let resolution = runtime_calibration_resolution_record(plan, action, request)
  let resolution_json = resolution.to_json().stringify(indent=2)
  let resolution_path = match
    @runtime.write_runtime_calibration_resolution(
      root,
      resolution.resolution_id,
      resolution_json,
    ) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      plan_path,
      resolution_path,
      latest_resolution_path: @runtime.latest_runtime_calibration_resolution_path(
        root,
      ),
      plan,
      action,
      resolution,
    }.to_json(),
  )
}

///|
fn task_message_dry_run_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "dry-run-\{draft.intent_id}-\{now_ms}"
}

///|
fn task_message_approval_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "approval-\{draft.intent_id}-\{now_ms}"
}

///|
fn task_message_execution_receipt_id(
  draft : @task.RobotTaskIntentDraft,
) -> String {
  "receipt-\{draft.intent_id}-executed"
}

///|
fn task_message_bridge_dispatch_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "dispatch-request-execute-\{draft.intent_id}-\{now_ms}"
}

///|
fn run_receipt_exists(root : String, receipt_id : String) -> Bool {
  match @runtime.read_run_receipt(root, receipt_id) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn dry_run_exists(root : String, dry_run_id : String) -> Bool {
  match @runtime.read_dry_run_evidence(root, dry_run_id) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn approval_exists(root : String, approval_id : String) -> Bool {
  match @runtime.read_approval_record(root, approval_id) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn bridge_dispatch_exists(root : String, dispatch_id : String) -> Bool {
  match @runtime.read_bridge_dispatch_evidence(root, dispatch_id) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn task_message_work_evidence(
  root : String,
  path : String,
  plan : @task.RobotTaskMessagePlan,
) -> @work_queue.TaskMessageWorkEvidence {
  match plan.intent_draft {
    None => @work_queue.task_message_work_evidence(path, plan)
    Some(draft) => {
      let now_ms = plan.task.now_ms
      @work_queue.task_message_work_evidence(
        path,
        plan,
        evaluated=run_receipt_exists(root, draft.receipt_id),
        dry_run_collected=dry_run_exists(
          root,
          task_message_dry_run_id(draft, now_ms),
        ),
        approved=approval_exists(root, task_message_approval_id(draft, now_ms)),
        executed=run_receipt_exists(
            root,
            task_message_execution_receipt_id(draft),
          ) &&
          bridge_dispatch_exists(
            root,
            task_message_bridge_dispatch_id(draft, now_ms),
          ),
      )
    }
  }
}

///|
fn project_agent_work_queue(
  root : String,
  generated_at_ms : Int64,
) -> Result[@work_queue.AgentWorkQueue, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let observations = observation_sessions_or_empty(root)
  let reviews = reviews_or_empty(root)
  let resident = resident_projection(
    book,
    sidecar_status(book.profile, root),
    root,
  )
  let queue_resident = if latest_runtime_running(root) &&
    resident.availability == "bridge-missing" {
    { ..resident, availability: "runtime-started" }
  } else {
    resident
  }
  let evidence = match dataset_work_evidence_list(root, observations) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let task_messages = match task_message_work_evidence_list(root) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let runtime_calibration = match latest_runtime_calibration_work(root) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let runtime_readiness = match runtime_calibration {
    Some(_) => runtime_calibration
    None => bridge_contract_validation_work(root, book, resident)
  }
  let proof_session = match latest_proof_session_work(root) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let live_exercise = latest_live_exercise_work(root)
  let robot_routine = latest_robot_routine_work(root)
  Ok(
    @work_queue.project(
      book.profile.id,
      queue_resident,
      reviews,
      task_messages,
      evidence,
      policy_evaluations_or_empty(root),
      generated_at_ms,
      runtime_calibration=runtime_readiness,
      live_exercise~,
      robot_routine~,
      proof_session~,
    ),
  )
}

///|
pub fn agent_work_queue_response(root : String) -> HostApiResponse {
  match project_agent_work_queue(root, 0L) {
    Ok(queue) => json_response(200, queue.to_json())
    Err(response) => response
  }
}

///|
pub fn agent_next_action_response(root : String) -> HostApiResponse {
  let queue = match project_agent_work_queue(root, 0L) {
    Ok(queue) => queue
    Err(response) => return response
  }
  let registry = match tool_registry_or_response(root, 0L) {
    Ok(registry) => registry
    Err(response) => return response
  }
  json_response(
    200,
    @work_queue.next_action_plan_with_registry(queue, registry).to_json(),
  )
}

///|
fn default_dispatch_request() -> AgentDispatchRequest {
  { work_id: "", body: None }
}

///|
fn decode_dispatch_request(
  body : String,
  path : String,
) -> Result[AgentDispatchRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_dispatch_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400, "parse-agent-dispatch", path, "failed to parse agent dispatch JSON",
        ),
      )
  }
  let request : AgentDispatchRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400, "decode-agent-dispatch", path, "failed to decode agent dispatch contract",
        ),
      )
  }
  Ok(request)
}

///|
fn selected_work_item(
  queue : @work_queue.AgentWorkQueue,
  request : AgentDispatchRequest,
) -> @work_queue.AgentWorkItem? {
  if request.work_id == "" {
    queue.next_item
  } else {
    queue.items.iter().find_first(item => item.work_id == request.work_id)
  }
}

///|
fn dispatchable_kind(kind : String) -> Bool {
  match kind {
    "observe"
    | "annotate-replay"
    | "evaluate-policy"
    | "bind-execution-feedback"
    | "run-proof-session"
    | "run-live-exercise"
    | "validate-runtime" => true
    _ => false
  }
}

///|
fn downstream_json(response : HostApiResponse) -> Json {
  @json.parse(response.body) catch {
    _ => { "raw_body": response.body }
  }
}

///|
fn dispatch_downstream(
  root : String,
  action : @work_queue.AgentNextAction,
  request_body : Json,
) -> HostApiResponse {
  let body = request_body.stringify()
  match action.route {
    "/api/moonclaw/run-next" => moonclaw_run_next_response(root, body)
    "/api/policies/evaluate" => policy_evaluation_response(root, body)
    "/api/runtime/validation/session" =>
      runtime_validation_session_response(root, body)
    "/api/moonrobo/executions/feedback" =>
      task_execution_feedback_response(root, body)
    "/api/moonrobo/proof-session" => platform_proof_session_response(root, body)
    "/api/moonrobo/live-exercise" => moonrobo_live_exercise_response(root, body)
    _ =>
      if session_id_from_replay_annotations_path(action.route) is Some(_) {
        replay_annotation_submission_response(root, action.route, body)
      } else {
        error_response(
          409,
          "unsupported-agent-dispatch",
          action.route,
          "agent dispatch only supports safe evidence mutation routes",
        )
      }
  }
}

///|
fn latest_execution_feedback_body(
  root : String,
  item : @work_queue.AgentWorkItem,
) -> Result[Json, HostApiResponse] {
  let health = match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) => record
    Ok(None) =>
      return Err(
        error_response(
          409,
          "agent-feedback-no-runtime-health",
          item.target_path,
          "binding execution feedback requires latest runtime health telemetry",
        ),
      )
    Err(error) =>
      return Err(error_response(500, error.code, error.path, error.message))
  }
  if health.telemetry_path == "" {
    return Err(
      error_response(
        409,
        "agent-feedback-no-telemetry",
        item.target_path,
        "latest runtime health does not include a telemetry artifact",
      ),
    )
  }
  let telemetry = match
    @runtime.read_telemetry_frame_file(health.telemetry_path) {
    Ok(frame) => frame
    Err(error) =>
      return Err(error_response(500, error.code, error.path, error.message))
  }
  Ok(
    TaskExecutionFeedbackRequest::{
      snapshot_id: item.target_id,
      telemetry,
      session_id: "agent-dispatch-next",
    }.to_json(),
  )
}

///|
fn dispatch_request_body(
  root : String,
  item : @work_queue.AgentWorkItem,
  action : @work_queue.AgentNextAction,
  request : AgentDispatchRequest,
) -> Result[Json, HostApiResponse] {
  match request.body {
    Some(value) => Ok(value)
    None =>
      if action.kind == "bind-execution-feedback" {
        latest_execution_feedback_body(root, item)
      } else if action.kind == "validate-runtime" {
        Ok(@runtime.default_runtime_validation_session_request().to_json())
      } else {
        match action.body_template {
          Some(value) => Ok(value)
          None =>
            Err(
              error_response(
                409,
                "missing-agent-body-template",
                action.route,
                "selected agent action does not include a safe request body template",
              ),
            )
        }
      }
  }
}

///|
pub fn agent_dispatch_next_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_dispatch_request(body, agent_dispatch_next_path()) {
    Ok(request) => request
    Err(response) => return response
  }
  let queue = match project_agent_work_queue(root, 0L) {
    Ok(queue) => queue
    Err(response) => return response
  }
  let item = match selected_work_item(queue, request) {
    Some(item) => item
    None =>
      return error_response(
        409,
        "no-agent-work",
        agent_dispatch_next_path(),
        "no queued agent work item is available for dispatch",
      )
  }
  let registry = match tool_registry_or_response(root, 0L) {
    Ok(registry) => registry
    Err(response) => return response
  }
  let action = @work_queue.action_for_item_with_registry(item, registry)
  if action.http_method != "POST" ||
    action.physical_execution_allowed ||
    !dispatchable_kind(action.kind) {
    return error_response(
      409,
      "agent-action-not-dispatchable",
      action.route,
      "selected agent action is planning-only or requires operator review",
    )
  }
  let request_body = match dispatch_request_body(root, item, action, request) {
    Ok(value) => value
    Err(response) => return response
  }
  let downstream = dispatch_downstream(root, action, request_body)
  json_response(
    downstream.status,
    {
      dispatched: downstream.status >= 200 && downstream.status < 300,
      action,
      request_body,
      downstream_status: downstream.status,
      downstream: downstream_json(downstream),
    }.to_json(),
  )
}
