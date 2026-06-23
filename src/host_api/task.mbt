///|
pub(all) struct MoontownTaskSubmissionResponse {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : @pipeline.ObservationSubmission
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoontownTaskMessageResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  plan : @task.ObservationTaskPlan?
  observation : @pipeline.ObservationSubmission?
  resident : @resident.ResidentRobotAgent
  memory : MoonBookMemoryResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageRecord {
  message_path : String
  plan : @task.RobotTaskMessagePlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageListResponse {
  message_count : Int
  messages : Array[MoonBookTaskMessageRecord]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageStatusResponse {
  status : @moonbook.TaskMessageExecutionStatus
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageIntentEvaluationResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  receipt_path : String
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageIntentDryRunResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  receipt_path : String
  dry_run_path : String
  dry_run : @core.DryRunEvidence
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageIntentApprovalResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  receipt_path : String
  approval_path : String
  approval : @core.ApprovalRecord
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookTaskMessageIntentExecutionResponse {
  persisted : Bool
  message_path : String
  message_plan : @task.RobotTaskMessagePlan
  receipt_path : String
  dispatch_path : String
  memory : MoonBookMemoryResponse
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moontown_observe_task_path() -> String {
  "/api/moontown/tasks/observe"
}

///|
pub fn moontown_task_message_path() -> String {
  "/api/moontown/tasks/message"
}

///|
pub fn moonbook_task_messages_path() -> String {
  "/api/moonbook/task-messages"
}

///|
pub fn moonbook_task_message_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}"
}

///|
pub fn moonbook_task_message_status_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/status"
}

///|
pub fn moonbook_task_message_evaluate_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/evaluate"
}

///|
pub fn moonbook_task_message_dry_run_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/dry-run"
}

///|
pub fn moonbook_task_message_approve_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/approve"
}

///|
pub fn moonbook_task_message_execute_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/execute"
}

///|
pub fn moonbook_task_message_execute_sidecar_path(task_id : String) -> String {
  "/api/moonbook/task-messages/\{task_id}/execute-sidecar"
}

///|
fn task_id_from_moonbook_task_message_path(path : String) -> String? {
  let prefix = moonbook_task_messages_path() + "/"
  if path.has_prefix(prefix) &&
    !path.contains("/evaluate") &&
    !path.contains("/dry-run") &&
    !path.contains("/approve") &&
    !path.contains("/status") &&
    !path.contains("/execute") &&
    !path.contains("/execute-sidecar") {
    let value = path[prefix.length():].to_owned()
    if value == "" {
      None
    } else {
      Some(value)
    }
  } else {
    None
  }
}

///|
fn task_id_from_moonbook_task_message_action_path(
  path : String,
  action : String,
) -> String? {
  let prefix = moonbook_task_messages_path() + "/"
  let suffix = "/\{action}"
  if path.has_prefix(prefix) && path.has_suffix(suffix) {
    let value = path[prefix.length():path.length() - suffix.length()].to_owned()
    if value == "" {
      None
    } else {
      Some(value)
    }
  } else {
    None
  }
}

///|
fn task_id_from_moonbook_task_message_evaluate_path(path : String) -> String? {
  task_id_from_moonbook_task_message_action_path(path, "evaluate")
}

///|
fn task_id_from_moonbook_task_message_status_path(path : String) -> String? {
  task_id_from_moonbook_task_message_action_path(path, "status")
}

///|
fn task_id_from_moonbook_task_message_dry_run_path(path : String) -> String? {
  task_id_from_moonbook_task_message_action_path(path, "dry-run")
}

///|
fn task_id_from_moonbook_task_message_approve_path(path : String) -> String? {
  task_id_from_moonbook_task_message_action_path(path, "approve")
}

///|
fn task_id_from_moonbook_task_message_execute_path(path : String) -> String? {
  task_id_from_moonbook_task_message_action_path(path, "execute")
}

///|
fn is_moonbook_task_message_evaluate_path(path : String) -> Bool {
  task_id_from_moonbook_task_message_evaluate_path(path) is Some(_)
}

///|
pub fn is_moonbook_task_message_status_path(path : String) -> Bool {
  task_id_from_moonbook_task_message_status_path(path) is Some(_)
}

///|
fn is_moonbook_task_message_dry_run_path(path : String) -> Bool {
  task_id_from_moonbook_task_message_dry_run_path(path) is Some(_)
}

///|
fn is_moonbook_task_message_approve_path(path : String) -> Bool {
  task_id_from_moonbook_task_message_approve_path(path) is Some(_)
}

///|
fn is_moonbook_task_message_execute_path(path : String) -> Bool {
  task_id_from_moonbook_task_message_execute_path(path) is Some(_)
}

///|
fn decode_task_message_plan_text(
  path : String,
  text : String,
) -> Result[@task.RobotTaskMessagePlan, HostApiResponse] {
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
  Ok(plan)
}

///|
fn read_task_message_record(
  path : String,
  text : String,
) -> Result[MoonBookTaskMessageRecord, HostApiResponse] {
  match decode_task_message_plan_text(path, text) {
    Ok(plan) => Ok({ message_path: path, plan })
    Err(response) => Err(response)
  }
}

///|
fn task_message_records(
  root : String,
) -> Result[Array[MoonBookTaskMessageRecord], HostApiResponse] {
  let paths = match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let records : Array[MoonBookTaskMessageRecord] = []
  for path in paths {
    let text = match @runtime.read_moonbook_task_message_json_file(path) {
      Ok(text) => text
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
    match read_task_message_record(path, text) {
      Ok(record) => records.push(record)
      Err(response) => return Err(response)
    }
  }
  Ok(records)
}

///|
pub fn moonbook_task_messages_response(root : String) -> HostApiResponse {
  match task_message_records(root) {
    Ok(messages) =>
      json_response(
        200,
        { message_count: messages.length(), messages }.to_json(),
      )
    Err(response) => response
  }
}

///|
fn load_task_message_record(
  root : String,
  path : String,
) -> Result[MoonBookTaskMessageRecord, HostApiResponse] {
  let task_id = match task_id_from_moonbook_task_message_path(path) {
    Some(value) => value
    None =>
      return Err(
        error_response(404, "not-found", path, "No task message route"),
      )
  }
  let file_path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  read_task_message_record(file_path, text)
}

///|
fn load_task_message_record_for_action(
  root : String,
  path : String,
  action : String,
) -> Result[MoonBookTaskMessageRecord, HostApiResponse] {
  let task_id = match
    task_id_from_moonbook_task_message_action_path(path, action) {
    Some(value) => value
    None =>
      return Err(
        error_response(
          404,
          "not-found",
          path,
          "No task-message \{action} route",
        ),
      )
  }
  let file_path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  read_task_message_record(file_path, text)
}

///|
pub fn moonbook_task_message_response(
  root : String,
  path : String,
) -> HostApiResponse {
  match load_task_message_record(root, path) {
    Ok(record) => json_response(200, record.to_json())
    Err(response) => response
  }
}

///|
fn optional_run_receipt(
  root : String,
  receipt_id : @core.ReceiptId,
) -> @core.RunReceipt? {
  if @fsx.path_exists(@runtime.receipt_path(root, receipt_id)) {
    match @runtime.read_run_receipt(root, receipt_id) {
      Ok(value) => Some(value)
      Err(_) => None
    }
  } else {
    None
  }
}

///|
fn optional_dry_run(
  root : String,
  dry_run_id : @core.ReceiptId,
) -> @core.DryRunEvidence? {
  if @fsx.path_exists(@runtime.dry_run_evidence_path(root, dry_run_id)) {
    match @runtime.read_dry_run_evidence(root, dry_run_id) {
      Ok(value) => Some(value)
      Err(_) => None
    }
  } else {
    None
  }
}

///|
fn optional_approval(
  root : String,
  approval_id : String,
) -> @core.ApprovalRecord? {
  if @fsx.path_exists(@runtime.approval_record_path(root, approval_id)) {
    match @runtime.read_approval_record(root, approval_id) {
      Ok(value) => Some(value)
      Err(_) => None
    }
  } else {
    None
  }
}

///|
fn optional_bridge_dispatch(
  root : String,
  dispatch_id : String,
) -> @core.BridgeDispatchEvidence? {
  if @fsx.path_exists(@runtime.bridge_dispatch_evidence_path(root, dispatch_id)) {
    match @runtime.read_bridge_dispatch_evidence(root, dispatch_id) {
      Ok(value) => Some(value)
      Err(_) => None
    }
  } else {
    None
  }
}

///|
fn task_message_execution_evidence(
  root : String,
  plan : @task.RobotTaskMessagePlan,
  runtime_status : String,
  runtime_bridge_base_url : String,
) -> @moonbook.TaskMessageExecutionEvidence {
  match plan.intent_draft {
    Some(draft) => {
      let now_ms = plan.task.now_ms
      @moonbook.task_message_execution_evidence(
        evaluated_receipt=optional_run_receipt(root, draft.receipt_id),
        dry_run=optional_dry_run(
          root,
          @moonbook.task_message_dry_run_id(draft, now_ms),
        ),
        approval=optional_approval(
          root,
          @moonbook.task_message_approval_id(draft, now_ms),
        ),
        execution_receipt=optional_run_receipt(
          root,
          @moonbook.task_message_execution_receipt_id(draft),
        ),
        bridge_dispatch=optional_bridge_dispatch(
          root,
          @moonbook.task_message_bridge_dispatch_id(draft, now_ms),
        ),
        runtime_status~,
        runtime_bridge_base_url~,
      )
    }
    None =>
      @moonbook.task_message_execution_evidence(
        runtime_status~,
        runtime_bridge_base_url~,
      )
  }
}

///|
pub fn moonbook_task_message_status_response(
  root : String,
  path : String,
  runtime_status? : String = "unknown",
  runtime_bridge_base_url? : String = "",
) -> HostApiResponse {
  let task_id = match task_id_from_moonbook_task_message_status_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No task-message status route",
      )
  }
  let message_path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  let record = match read_task_message_record(message_path, text) {
    Ok(record) => record
    Err(response) => return response
  }
  let evidence = task_message_execution_evidence(
    root,
    record.plan,
    runtime_status,
    runtime_bridge_base_url,
  )
  json_response(
    200,
    {
      status: @moonbook.project_task_message_execution_status(
        record.message_path,
        record.plan,
        evidence,
      ),
    }.to_json(),
  )
}

///|
fn task_message_action_context(
  root : String,
  path : String,
  action : String,
) -> Result[
  (
    @runtime.LoadedRoboBook,
    MoonBookTaskMessageRecord,
    @task.RobotTaskIntentDraft,
    IntentSubmissionRequest,
  ),
  HostApiResponse,
] {
  let record = match load_task_message_record_for_action(root, path, action) {
    Ok(record) => record
    Err(response) => return Err(response)
  }
  let draft = match record.plan.intent_draft {
    Some(draft) => draft
    None =>
      return Err(
        error_response(
          400, "missing-intent-draft", path, "task message does not include an evaluable command intent draft",
        ),
      )
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let request = task_message_intent_submission(book.profile, record.plan, draft)
  Ok((book, record, draft, request))
}

///|
fn task_message_intent_submission(
  profile : @core.RobotProfile,
  plan : @task.RobotTaskMessagePlan,
  draft : @task.RobotTaskIntentDraft,
) -> IntentSubmissionRequest {
  {
    intent_id: draft.intent_id,
    robot_id: if plan.task.robot_id == "" {
      profile.id
    } else {
      plan.task.robot_id
    },
    capability: draft.capability,
    parameters: draft.parameters,
    requester: plan.task.requested_by,
    receipt_id: draft.receipt_id,
    now_ms: plan.task.now_ms,
    approval_id: "",
    dry_run_receipt_id: "",
    developer_gate: draft.developer_gate,
    telemetry_age_ms: draft.telemetry_age_ms,
  }
}

///|
pub fn moonbook_task_message_evaluate_response(
  root : String,
  path : String,
) -> HostApiResponse {
  if !is_moonbook_task_message_evaluate_path(path) {
    return error_response(
      404, "not-found", path, "No task-message evaluate route",
    )
  }
  let (book, record, _, request) = match
    task_message_action_context(root, path, "evaluate") {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(book, request, None, None)
  let receipt_path = match @runtime.write_run_receipt(root, result.receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      message_path: record.message_path,
      message_plan: record.plan,
      receipt_path,
      result,
    }.to_json(),
  )
}

///|
pub fn moonbook_task_message_dry_run_response(
  root : String,
  path : String,
) -> HostApiResponse {
  if !is_moonbook_task_message_dry_run_path(path) {
    return error_response(
      404, "not-found", path, "No task-message dry-run route",
    )
  }
  let (book, record, _, request) = match
    task_message_action_context(root, path, "dry-run") {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(book, request, None, None)
  if result.next_action != CollectDryRun {
    return error_response(
      400, "dry-run-not-required", path, "current safety result does not request a dry run",
    )
  }
  let dry_run = @core.dry_run_evidence(
    generated_dry_run_id(request),
    result.receipt,
    "Dry-run evidence captured for reviewed task message; hardware execution was not invoked.",
    request.now_ms,
  )
  let receipt_path = match @runtime.write_run_receipt(root, result.receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let dry_run_path = match @runtime.write_dry_run_evidence(root, dry_run) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      message_path: record.message_path,
      message_plan: record.plan,
      receipt_path,
      dry_run_path,
      dry_run,
      result,
    }.to_json(),
  )
}

///|
pub fn moonbook_task_message_approve_response(
  root : String,
  path : String,
) -> HostApiResponse {
  if !is_moonbook_task_message_approve_path(path) {
    return error_response(
      404, "not-found", path, "No task-message approve route",
    )
  }
  let (book, record, _, request) = match
    task_message_action_context(root, path, "approve") {
    Ok(value) => value
    Err(response) => return response
  }
  let dry_run_receipt_id = generated_dry_run_id(request)
  let expected_intent = intent_for_submission(book.profile, request)
  let _dry_run = match
    matching_dry_run_or_response(
      root, dry_run_receipt_id, expected_intent, path,
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(
    book,
    request,
    None,
    Some(dry_run_receipt_id),
  )
  if result.next_action != RequestApproval {
    return error_response(
      400, "approval-not-required", path, "current safety result does not request approval",
    )
  }
  let approval = @core.approval_record(
    generated_approval_id(request),
    dry_run_receipt_id,
    expected_intent,
    request.requester,
    "Operator approval recorded for reviewed task message.",
    request.now_ms,
  )
  let receipt_path = match @runtime.write_run_receipt(root, result.receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let approval_path = match @runtime.write_approval_record(root, approval) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      persisted: true,
      message_path: record.message_path,
      message_plan: record.plan,
      receipt_path,
      approval_path,
      approval,
      result,
    }.to_json(),
  )
}

///|
pub fn moonbook_task_message_execute_response(
  root : String,
  path : String,
) -> HostApiResponse {
  if !is_moonbook_task_message_execute_path(path) {
    return error_response(
      404, "not-found", path, "No task-message execute route",
    )
  }
  let (book, record, _, request) = match
    task_message_action_context(root, path, "execute") {
    Ok(value) => value
    Err(response) => return response
  }
  let dry_run_receipt_id = generated_dry_run_id(request)
  let approval_id = generated_approval_id(request)
  let expected_intent = intent_for_submission(book.profile, request)
  let _dry_run = match
    matching_dry_run_or_response(
      root, dry_run_receipt_id, expected_intent, path,
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let _approval = match
    matching_approval_or_response(
      root, approval_id, dry_run_receipt_id, expected_intent, path,
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(
    book,
    request,
    Some(approval_id),
    Some(dry_run_receipt_id),
  )
  if result.next_action != Execute || result.receipt.status != ReadyForExecution {
    return error_response(
      400, "not-ready-for-execution", path, "safety pipeline did not produce a ready-for-execution receipt",
    )
  }
  let persisted = match
    persist_bridge_execution(
      root,
      book.profile,
      expected_intent,
      result.receipt,
      "receipt-\{request.intent_id}-executed",
      request.now_ms,
      path,
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let memory = match persist_moonbook_memory(root, request.now_ms) {
    Ok(response) => response
    Err(response) => return response
  }
  json_response(
    200,
    {
      persisted: true,
      message_path: record.message_path,
      message_plan: record.plan,
      receipt_path: persisted.receipt_path,
      dispatch_path: persisted.dispatch_path,
      memory,
      receipt: persisted.receipt,
      bridge_response: persisted.bridge_response,
      bridge_dispatch: persisted.bridge_dispatch,
      result,
    }.to_json(),
  )
}

///|
fn decode_robot_task_request(
  body : String,
  path : String,
) -> Result[@task.RobotTaskRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-robot-task",
        path,
        message: "failed to parse robot task JSON",
      })
  }
  let request : @task.RobotTaskRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-robot-task",
        path,
        message: "failed to decode robot task contract",
      })
  }
  Ok(request)
}

///|
fn decode_task_message_request(
  body : String,
  path : String,
) -> Result[@task.RobotTaskMessageRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-task-message",
        path,
        message: "failed to parse task message JSON",
      })
  }
  let request : @task.RobotTaskMessageRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-task-message",
        path,
        message: "failed to decode task message contract",
      })
  }
  Ok(request)
}

///|
fn resident_after_task(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> @resident.ResidentRobotAgent {
  @resident.project(
    book,
    sidecar_status(book.profile, root),
    receipts_or_empty(root),
    observation_sessions_or_empty(root),
    reviews_or_empty(root),
  )
}

///|
fn write_task_message_plan(
  root : String,
  message_plan : @task.RobotTaskMessagePlan,
) -> Result[String, HostApiResponse] {
  match
    @runtime.write_moonbook_task_message_json(
      root,
      message_plan.task.task_id,
      message_plan.to_json().stringify(indent=2),
    ) {
    Ok(path) => Ok(path)
    Err(issue) =>
      Err(error_response(500, issue.code, issue.path, issue.message))
  }
}

///|
pub fn moontown_observe_task_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_robot_task_request(body, moontown_observe_task_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let plan = match @task.plan_observation_task(book.profile, request) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_observe_task_path(),
        issue.message,
      )
  }
  let observation = match
    @pipeline.start_observation(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(error) => return pipeline_error_response(error)
  }
  json_response(
    200,
    {
      persisted: true,
      plan: @task.accepted_plan(plan),
      observation,
      resident: resident_after_task(root, book),
    }.to_json(),
  )
}

///|
pub fn moontown_task_message_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_task_message_request(body, moontown_task_message_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let message_plan = match @task.plan_task_message(book.profile, request) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_task_message_path(),
        issue.message,
      )
  }
  let message_path = match write_task_message_plan(root, message_plan) {
    Ok(path) => path
    Err(response) => return response
  }
  if !(message_plan.task.kind is ObserveTelemetry) {
    let resident = resident_after_task(root, book)
    let memory = match persist_moonbook_memory(root, message_plan.task.now_ms) {
      Ok(response) => response
      Err(response) => return response
    }
    return json_response(
      200,
      {
        persisted: true,
        message_path,
        message_plan,
        plan: None,
        observation: None,
        resident,
        memory,
      }.to_json(),
    )
  }
  let plan = match
    @task.plan_observation_task(book.profile, message_plan.task) {
    Ok(plan) => plan
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        moontown_task_message_path(),
        issue.message,
      )
  }
  let observation = match
    @pipeline.start_observation(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(error) => return pipeline_error_response(error)
  }
  let resident = resident_after_task(root, book)
  let memory = match persist_moonbook_memory(root, plan.planned_at_ms) {
    Ok(response) => response
    Err(response) => return response
  }
  json_response(
    200,
    {
      persisted: true,
      message_path,
      message_plan,
      plan: Some(@task.accepted_plan(plan)),
      observation: Some(observation),
      resident,
      memory,
    }.to_json(),
  )
}
