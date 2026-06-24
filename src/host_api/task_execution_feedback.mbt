///|
pub(all) struct TaskExecutionFeedbackRequest {
  snapshot_id : String
  telemetry : @core.TelemetryFrame
  session_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskExecutionFeedbackResponse {
  persisted : Bool
  verified : Bool
  snapshot_path : String
  feedback_path : String
  memory_path : String
  snapshot : @core.TaskExecutionSnapshot
  execution : TaskExecutionProofRecord
  report : TaskExecutionProofReport
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn task_execution_feedback_path() -> String {
  "/api/moonrobo/executions/feedback"
}

///|
fn default_feedback_session_id() -> String {
  "execution-feedback"
}

///|
fn dispatch_id_for_snapshot(snapshot : @core.TaskExecutionSnapshot) -> String {
  "dispatch-\{snapshot.bridge_request_id}"
}

///|
fn normalize_feedback_request(
  request : TaskExecutionFeedbackRequest,
) -> TaskExecutionFeedbackRequest {
  {
    snapshot_id: request.snapshot_id.trim().to_owned(),
    telemetry: request.telemetry,
    session_id: if request.session_id.trim().to_owned() == "" {
      default_feedback_session_id()
    } else {
      request.session_id.trim().to_owned()
    },
  }
}

///|
fn decode_task_execution_feedback_request(
  body : String,
) -> Result[TaskExecutionFeedbackRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-task-execution-feedback",
          task_execution_feedback_path(),
          "failed to parse task execution feedback JSON",
        ),
      )
  }
  let request : TaskExecutionFeedbackRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-task-execution-feedback",
          task_execution_feedback_path(),
          "failed to decode task execution feedback contract",
        ),
      )
  }
  let request = normalize_feedback_request(request)
  if request.snapshot_id == "" {
    return Err(
      error_response(
        400,
        "missing-feedback-snapshot",
        task_execution_feedback_path(),
        "task execution feedback requires snapshot_id",
      ),
    )
  }
  Ok(request)
}

///|
fn feedback_identity_response(
  request : TaskExecutionFeedbackRequest,
  snapshot : @core.TaskExecutionSnapshot,
  receipt : @core.RunReceipt,
) -> HostApiResponse? {
  if request.telemetry.robot_id != receipt.robot_id {
    Some(
      error_response(
        409,
        "feedback-robot-mismatch",
        task_execution_feedback_path(),
        "feedback robot_id does not match the execution receipt",
      ),
    )
  } else if request.telemetry.bridge_id != receipt.bridge_id {
    Some(
      error_response(
        409,
        "feedback-bridge-mismatch",
        task_execution_feedback_path(),
        "feedback bridge_id does not match the execution receipt",
      ),
    )
  } else if request.telemetry.captured_at_ms < snapshot.captured_at_ms {
    Some(
      error_response(
        409,
        "feedback-stale",
        task_execution_feedback_path(),
        "feedback frame was captured before the execution snapshot",
      ),
    )
  } else {
    None
  }
}

///|
fn updated_execution_snapshot(
  snapshot : @core.TaskExecutionSnapshot,
  receipt : @core.RunReceipt,
  dispatch : @core.BridgeDispatchEvidence,
  feedback_path : String,
  telemetry : @core.TelemetryFrame,
) -> @core.TaskExecutionSnapshot {
  let base = @core.task_execution_snapshot(
    snapshot.snapshot_id,
    snapshot.task_id,
    snapshot.message_path,
    snapshot.receipt_path,
    snapshot.dispatch_path,
    snapshot.memory_path,
    receipt,
    dispatch,
    snapshot.captured_at_ms,
    runtime_health_path=snapshot.runtime_health_path,
    runtime_status=snapshot.runtime_status,
    runtime_health_persisted=snapshot.runtime_health_persisted,
    runtime_log_path=snapshot.runtime_log_path,
    telemetry_frame_id=telemetry.frame_id,
    telemetry_captured_at_ms=telemetry.captured_at_ms,
    physical_feedback_path=feedback_path,
  )
  let outcome = @core.command_outcome_evidence(
    base,
    Some(telemetry),
    intent=Some(receipt.intent),
  )
  @core.task_execution_snapshot(
    snapshot.snapshot_id,
    snapshot.task_id,
    snapshot.message_path,
    snapshot.receipt_path,
    snapshot.dispatch_path,
    snapshot.memory_path,
    receipt,
    dispatch,
    snapshot.captured_at_ms,
    runtime_health_path=snapshot.runtime_health_path,
    runtime_status=snapshot.runtime_status,
    runtime_health_persisted=snapshot.runtime_health_persisted,
    runtime_log_path=snapshot.runtime_log_path,
    telemetry_frame_id=telemetry.frame_id,
    telemetry_captured_at_ms=telemetry.captured_at_ms,
    physical_feedback_path=feedback_path,
    checked_command_outcome_status=outcome.status,
    checked_command_outcome_verified=outcome.verified,
  )
}

///|
pub fn task_execution_feedback_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_task_execution_feedback_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let snapshot = match
    @runtime.read_task_execution_snapshot(root, request.snapshot_id) {
    Ok(snapshot) => snapshot
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  let receipt = match @runtime.read_run_receipt(root, snapshot.receipt_id) {
    Ok(receipt) => receipt
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let dispatch = match
    @runtime.read_bridge_dispatch_evidence(
      root,
      dispatch_id_for_snapshot(snapshot),
    ) {
    Ok(dispatch) => dispatch
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  match feedback_identity_response(request, snapshot, receipt) {
    Some(response) => return response
    None => ()
  }
  let feedback_path = match
    @runtime.write_telemetry_frame(root, request.session_id, request.telemetry) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let updated = updated_execution_snapshot(
    snapshot,
    receipt,
    dispatch,
    feedback_path,
    request.telemetry,
  )
  let snapshot_path = match
    @runtime.write_task_execution_snapshot(root, updated) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let memory = match persist_moonbook_memory(root, updated.captured_at_ms) {
    Ok(memory) => memory
    Err(response) => return response
  }
  let execution = task_execution_proof_record(snapshot_path, updated)
  let report = match task_execution_proof_report(root) {
    Ok(report) => report
    Err(response) => return response
  }
  json_response(
    200,
    TaskExecutionFeedbackResponse::{
      persisted: true,
      verified: execution.verified,
      snapshot_path,
      feedback_path,
      memory_path: memory.memory_path,
      snapshot: updated,
      execution,
      report,
      message: if execution.verified {
        "Physical feedback verified for task execution \{updated.snapshot_id}."
      } else {
        "Physical feedback bound for task execution \{updated.snapshot_id}; \{execution.command_outcome_status}."
      },
    }.to_json(),
  )
}

///|
fn latest_runtime_feedback_request(
  root : String,
  snapshot_id : String,
  session_id : String,
) -> TaskExecutionFeedbackRequest? {
  let health = match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) => record
    _ => return None
  }
  if health.telemetry_path == "" {
    return None
  }
  let telemetry = match
    @runtime.read_telemetry_frame_file(health.telemetry_path) {
    Ok(frame) => frame
    Err(_) => return None
  }
  Some(TaskExecutionFeedbackRequest::{ snapshot_id, telemetry, session_id })
}

///|
fn decode_task_execution_feedback_response(
  response : HostApiResponse,
) -> TaskExecutionFeedbackResponse? {
  if response.status < 200 || response.status >= 300 {
    return None
  }
  let json = @json.parse(response.body) catch { _ => return None }
  let result : TaskExecutionFeedbackResponse = @json.from_json(json) catch {
    _ => return None
  }
  Some(result)
}

///|
fn try_bind_latest_execution_feedback(
  root : String,
  session_id : String,
) -> TaskExecutionFeedbackResponse? {
  let report = match task_execution_proof_report(root) {
    Ok(report) => report
    Err(_) => return None
  }
  let latest = match report.latest {
    Some(record) => record
    None => return None
  }
  if latest.verified {
    return None
  }
  let request = match
    latest_runtime_feedback_request(
      root,
      latest.snapshot.snapshot_id,
      session_id,
    ) {
    Some(request) => request
    None => return None
  }
  decode_task_execution_feedback_response(
    task_execution_feedback_response(root, request.to_json().stringify()),
  )
}
