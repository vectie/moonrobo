///|
pub(all) struct BridgeExecutionIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SidecarTaskMessageExecution {
  task_id : String
  message_path : String
  receipt_path : String
  dispatch_path : String
  memory : @host_api.MoonBookMemoryResponse
  receipt : @core.RunReceipt
  bridge_request : @bridge_protocol.BridgeRequest
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReviewedMessageSidecarRun {
  message_id : String
  task_id : String
  evaluate_status : Int
  dry_run_status : Int
  approval_status : Int
  execution : SidecarTaskMessageExecution
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReviewedMessagePreparation {
  message_id : String
  task_id : String
  evaluate_status : Int
  dry_run_status : Int
  approval_status : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  code : String,
  path : String,
  message : String,
) -> BridgeExecutionIssue {
  { code, path, message }
}

///|
fn operation_label(operation : @bridge_protocol.BridgeOperation) -> String {
  match operation {
    Health => "Health"
    Metadata => "Metadata"
    Capabilities => "Capabilities"
    LatestTelemetry => "LatestTelemetry"
    StartObserve => "StartObserve"
    StopSession => "StopSession"
    DryRunIntent => "DryRunIntent"
    ExecuteIntent => "ExecuteIntent"
    EmergencyStop => "EmergencyStop"
  }
}

///|
fn response_status_label(
  status : @bridge_protocol.BridgeResponseStatus,
) -> String {
  match status {
    Accepted => "Accepted"
    Rejected => "Rejected"
    Error => "Error"
  }
}

///|
fn same_intent_identity(
  left : @core.CommandIntent,
  right : @core.CommandIntent,
) -> Bool {
  left.intent_id == right.intent_id &&
  left.robot_id == right.robot_id &&
  left.capability == right.capability &&
  left.parameters == right.parameters
}

///|
fn task_message_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/execute-sidecar"
}

///|
fn message_task_id(message_id : String, now_ms : Int64) -> String {
  if message_id == "" {
    "message-\{now_ms}"
  } else {
    "message-\{message_id}"
  }
}

///|
fn generated_dry_run_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "dry-run-\{draft.intent_id}-\{now_ms}"
}

///|
fn generated_approval_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "approval-\{draft.intent_id}-\{now_ms}"
}

///|
fn execution_receipt_id(draft : @task.RobotTaskIntentDraft) -> String {
  "receipt-\{draft.intent_id}-executed"
}

///|
fn request_id(intent_id : String, now_ms : Int64) -> String {
  "request-execute-\{intent_id}-\{now_ms}"
}

///|
fn dispatch_id(request : @bridge_protocol.BridgeRequest) -> String {
  "dispatch-\{request.request_id}"
}

///|
fn read_task_message_plan(
  root : String,
  task_id : String,
) -> Result[@task.RobotTaskMessagePlan, BridgeExecutionIssue] {
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-task-message-plan",
          @runtime.moonbook_task_message_path(root, task_id),
          "failed to parse MoonBook task message plan",
        ),
      )
  }
  let plan : @task.RobotTaskMessagePlan = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-task-message-plan",
          @runtime.moonbook_task_message_path(root, task_id),
          "failed to decode MoonBook task message plan",
        ),
      )
  }
  Ok(plan)
}

///|
fn bridge_request_for_task_message(
  root : String,
  task_id : String,
) -> Result[@bridge_protocol.BridgeRequest, BridgeExecutionIssue] {
  let plan = match read_task_message_plan(root, task_id) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  let draft = match plan.intent_draft {
    Some(draft) => draft
    None =>
      return Err(
        issue(
          "missing-intent-draft",
          task_message_path(task_id),
          "task message does not include an executable command intent draft",
        ),
      )
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  let expected_intent = intent_for_plan(book.profile, plan, draft)
  Ok(
    @bridge_protocol.execute_request(
      request_id(expected_intent.intent_id, plan.task.now_ms),
      book.profile,
      expected_intent,
      plan.task.now_ms,
    ),
  )
}

///|
fn ensure_response_ok(
  response : @host_api.HostApiResponse,
  path : String,
) -> Result[Unit, BridgeExecutionIssue] {
  if response.status == 200 {
    Ok(())
  } else {
    Err(issue("host-api-error", path, response.body))
  }
}

///|
fn intent_for_plan(
  profile : @core.RobotProfile,
  plan : @task.RobotTaskMessagePlan,
  draft : @task.RobotTaskIntentDraft,
) -> @core.CommandIntent {
  @core.command_intent(
    draft.intent_id,
    if plan.task.robot_id == "" {
      profile.id
    } else {
      plan.task.robot_id
    },
    draft.capability,
    plan.task.requested_by,
    parameters=draft.parameters,
  )
}

///|
fn matching_dry_run(
  root : String,
  dry_run_receipt_id : String,
  expected_intent : @core.CommandIntent,
) -> Result[@core.DryRunEvidence, BridgeExecutionIssue] {
  let dry_run = match @runtime.read_dry_run_evidence(root, dry_run_receipt_id) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  if !same_intent_identity(dry_run.intent, expected_intent) {
    Err(
      issue(
        "dry-run-mismatch",
        @runtime.dry_run_evidence_path(root, dry_run_receipt_id),
        "dry-run evidence does not match the task-message intent",
      ),
    )
  } else {
    Ok(dry_run)
  }
}

///|
fn matching_approval(
  root : String,
  approval_id : String,
  dry_run_receipt_id : String,
  expected_intent : @core.CommandIntent,
) -> Result[@core.ApprovalRecord, BridgeExecutionIssue] {
  let approval = match @runtime.read_approval_record(root, approval_id) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  if approval.dry_run_receipt_id != dry_run_receipt_id ||
    !same_intent_identity(approval.intent, expected_intent) {
    Err(
      issue(
        "approval-mismatch",
        @runtime.approval_record_path(root, approval_id),
        "approval record does not match the task-message intent and dry run",
      ),
    )
  } else {
    Ok(approval)
  }
}

///|
fn receipt_for_response(
  receipt_id : String,
  ready_receipt : @core.RunReceipt,
  response : @bridge_protocol.BridgeResponse,
  ended_at_ms : Int64,
) -> @core.RunReceipt {
  match response.status {
    Accepted =>
      @core.executed_receipt(
        receipt_id,
        ready_receipt,
        ended_at_ms,
        telemetry_frame_count=1,
      )
    Rejected | Error =>
      @core.failed_receipt(
        receipt_id,
        ready_receipt,
        ended_at_ms,
        response.message,
      )
  }
}

///|
fn dispatch_for_response(
  request : @bridge_protocol.BridgeRequest,
  response : @bridge_protocol.BridgeResponse,
  receipt : @core.RunReceipt,
  now_ms : Int64,
) -> @core.BridgeDispatchEvidence {
  let route = @bridge_protocol.route_for_request(request)
  let intent_id = match request.intent {
    Some(intent) => intent.intent_id
    None => ""
  }
  @core.bridge_dispatch_evidence(
    dispatch_id(request),
    request.request_id,
    request.bridge_id,
    request.robot_id,
    operation_label(request.operation),
    route.http_method,
    route.path,
    intent_id,
    receipt.receipt_id,
    response_status_label(response.status),
    response.message,
    now_ms,
  )
}

///|
pub fn execute_task_message_with_sidecar(
  root : String,
  task_id : String,
  client : @bridge_client.BridgeClientConfig,
) -> Result[SidecarTaskMessageExecution, BridgeExecutionIssue] {
  let bridge_request = match bridge_request_for_task_message(root, task_id) {
    Ok(request) => request
    Err(error) => return Err(error)
  }
  let bridge_response = match
    @bridge_client.post_execute_intent(client, bridge_request) {
    Ok(response) => response
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  persist_task_message_execution_response(root, task_id, bridge_response)
}

///|
pub async fn execute_task_message_with_sidecar_async(
  root : String,
  task_id : String,
  client : @bridge_client.BridgeClientConfig,
) -> Result[SidecarTaskMessageExecution, BridgeExecutionIssue] {
  let bridge_request = match bridge_request_for_task_message(root, task_id) {
    Ok(request) => request
    Err(error) => return Err(error)
  }
  let bridge_response = match
    @bridge_client.post_execute_intent_async(client, bridge_request) {
    Ok(response) => response
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  persist_task_message_execution_response(root, task_id, bridge_response)
}

///|
pub fn run_reviewed_message_with_sidecar(
  root : String,
  message_id : String,
  message : String,
  requester : @core.Requester,
  now_ms : Int64,
  client : @bridge_client.BridgeClientConfig,
) -> Result[ReviewedMessageSidecarRun, BridgeExecutionIssue] {
  let preparation = match
    prepare_reviewed_message(root, message_id, message, requester, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let execution = match
    execute_task_message_with_sidecar(root, preparation.task_id, client) {
    Ok(execution) => execution
    Err(error) => return Err(error)
  }
  Ok({
    message_id: preparation.message_id,
    task_id: preparation.task_id,
    evaluate_status: preparation.evaluate_status,
    dry_run_status: preparation.dry_run_status,
    approval_status: preparation.approval_status,
    execution,
  })
}

///|
pub fn prepare_reviewed_message(
  root : String,
  message_id : String,
  message : String,
  requester : @core.Requester,
  now_ms : Int64,
) -> Result[ReviewedMessagePreparation, BridgeExecutionIssue] {
  let task_id = message_task_id(message_id, now_ms)
  let request = @task.task_message_request(
    message_id, "", requester, message, now_ms,
  )
  let submit = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    request.to_json().stringify(),
  )
  match ensure_response_ok(submit, @host_api.moontown_task_message_path()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let plan = match read_task_message_plan(root, task_id) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  match plan.intent_draft {
    Some(_) => ()
    None =>
      return Err(
        issue(
          "not-command-review",
          @runtime.moonbook_task_message_path(root, task_id),
          "message did not produce a command intent review plan",
        ),
      )
  }
  let evaluate_path = @host_api.moonbook_task_message_evaluate_path(task_id)
  let evaluate = @host_api.route_with_body(root, "POST", evaluate_path, "")
  match ensure_response_ok(evaluate, evaluate_path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let dry_run_path = @host_api.moonbook_task_message_dry_run_path(task_id)
  let dry_run = @host_api.route_with_body(root, "POST", dry_run_path, "")
  match ensure_response_ok(dry_run, dry_run_path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let approval_path = @host_api.moonbook_task_message_approve_path(task_id)
  let approval = @host_api.route_with_body(root, "POST", approval_path, "")
  match ensure_response_ok(approval, approval_path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    message_id,
    task_id,
    evaluate_status: evaluate.status,
    dry_run_status: dry_run.status,
    approval_status: approval.status,
  })
}

///|
pub fn persist_task_message_execution_response(
  root : String,
  task_id : String,
  bridge_response : @bridge_protocol.BridgeResponse,
) -> Result[SidecarTaskMessageExecution, BridgeExecutionIssue] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  let plan = match read_task_message_plan(root, task_id) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  let draft = match plan.intent_draft {
    Some(draft) => draft
    None =>
      return Err(
        issue(
          "missing-intent-draft",
          task_message_path(task_id),
          "task message does not include an executable command intent draft",
        ),
      )
  }
  let now_ms = plan.task.now_ms
  let expected_intent = intent_for_plan(book.profile, plan, draft)
  let dry_run_receipt_id = generated_dry_run_id(draft, now_ms)
  let approval_id = generated_approval_id(draft, now_ms)
  match matching_dry_run(root, dry_run_receipt_id, expected_intent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    matching_approval(root, approval_id, dry_run_receipt_id, expected_intent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let result = @pipeline.evaluate_request(
    book.profile,
    @core.bridge_ok(
      book.profile.bridge.id,
      book.profile.id,
      last_telemetry_age_ms=draft.telemetry_age_ms,
    ),
    expected_intent,
    draft.receipt_id,
    now_ms,
    approval_id~,
    dry_run_receipt_id~,
    developer_gate=draft.developer_gate,
  )
  if result.next_action != Execute || result.receipt.status != ReadyForExecution {
    return Err(
      issue(
        "not-ready-for-execution",
        task_message_path(task_id),
        "safety pipeline did not produce a ready-for-execution receipt",
      ),
    )
  }
  let bridge_request = @bridge_protocol.execute_request(
    request_id(expected_intent.intent_id, now_ms),
    book.profile,
    expected_intent,
    now_ms,
  )
  if bridge_response.request_id != bridge_request.request_id ||
    bridge_response.operation != ExecuteIntent ||
    bridge_response.bridge_id != bridge_request.bridge_id ||
    bridge_response.robot_id != bridge_request.robot_id {
    return Err(
      issue(
        "bridge-response-mismatch",
        task_message_path(task_id),
        "bridge response does not match the expected ExecuteIntent request",
      ),
    )
  }
  let receipt = receipt_for_response(
    execution_receipt_id(draft),
    result.receipt,
    bridge_response,
    now_ms,
  )
  let bridge_dispatch = dispatch_for_response(
    bridge_request, bridge_response, receipt, now_ms,
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  let dispatch_path = match
    @runtime.write_bridge_dispatch_evidence(root, bridge_dispatch) {
    Ok(path) => path
    Err(error) => return Err(issue(error.code, error.path, error.message))
  }
  let memory = match @host_api.persist_moonbook_memory(root, now_ms) {
    Ok(value) => value
    Err(response) =>
      return Err(
        issue(
          "persist-moonbook-memory",
          task_message_path(task_id),
          response.body,
        ),
      )
  }
  Ok({
    task_id,
    message_path: @runtime.moonbook_task_message_path(root, task_id),
    receipt_path,
    dispatch_path,
    memory,
    receipt,
    bridge_request,
    bridge_response,
    bridge_dispatch,
    result,
  })
}
