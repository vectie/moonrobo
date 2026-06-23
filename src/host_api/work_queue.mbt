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
  let evidence = match dataset_work_evidence_list(root, observations) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let task_messages = match task_message_work_evidence_list(root) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  Ok(
    @work_queue.project(
      book.profile.id,
      resident,
      reviews,
      task_messages,
      evidence,
      policy_evaluations_or_empty(root),
      generated_at_ms,
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
  match project_agent_work_queue(root, 0L) {
    Ok(queue) =>
      json_response(200, @work_queue.next_action_plan(queue).to_json())
    Err(response) => response
  }
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
    "observe" | "annotate-replay" | "evaluate-policy" => true
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
  let action = @work_queue.action_for_item(item)
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
  let request_body = match request.body {
    Some(value) => value
    None =>
      match action.body_template {
        Some(value) => value
        None =>
          return error_response(
            409,
            "missing-agent-body-template",
            action.route,
            "selected agent action does not include a safe request body template",
          )
      }
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
