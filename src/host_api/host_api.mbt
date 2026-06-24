///|
pub(all) struct HostApiResponse {
  status : Int
  content_type : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostApiError {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HostApiHealth {
  service : String
  robobook_root : String
  status : String
  snapshot_path : String
  read_only : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReviewQueueResponse {
  review_count : Int
  needs_human_count : Int
  reviews : Array[@review.ProcessReview]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawContextResponse {
  result : @moonclaw.MoonClawPlanningResult
  live_readiness : MoonroboLiveReadinessResponse
  proof_sessions : PlatformProofSessionListResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformReadinessResponse {
  report : @readiness.PlatformReadinessReport
  plan : @readiness.PlatformReadinessPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntentSubmissionRequest {
  intent_id : String
  robot_id : String
  capability : String
  parameters : Map[String, String]
  requester : @core.Requester
  receipt_id : String
  now_ms : Int64
  approval_id : String
  dry_run_receipt_id : String
  developer_gate : Bool
  telemetry_age_ms : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct IntentSubmissionResponse {
  persisted : Bool
  receipt_path : String
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DryRunSubmissionResponse {
  persisted : Bool
  receipt_path : String
  dry_run_path : String
  dry_run : @core.DryRunEvidence
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ApprovalSubmissionResponse {
  persisted : Bool
  receipt_path : String
  approval_path : String
  approval : @core.ApprovalRecord
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ExecutionSubmissionResponse {
  persisted : Bool
  receipt_path : String
  dispatch_path : String
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
  result : @pipeline.PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct PersistedBridgeExecution {
  receipt_path : String
  dispatch_path : String
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  bridge_dispatch : @core.BridgeDispatchEvidence
}

///|
pub(all) struct PolicyEvaluationRequest {
  proposal : @policy.PolicyProposal
  evaluation_id : String
  receipt_id : @core.ReceiptId
  now_ms : Int64
  telemetry_age_ms : Int
  quality_report : @dataset.DatasetQualityReport?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PolicyEvaluationResponse {
  persisted : Bool
  evaluation_path : String
  receipt_path : String
  evaluation : @policy.PolicyEvaluationReceipt
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn snapshot_path() -> String {
  "/api/cockpit/snapshot"
}

///|
pub fn health_path() -> String {
  "/api/health"
}

///|
pub fn bridge_sidecar_path() -> String {
  "/api/bridge/sidecar"
}

///|
pub fn runtime_supervisor_path() -> String {
  "/api/runtime/supervisor"
}

///|
pub fn runtime_supervisor_script_path() -> String {
  "/api/runtime/supervisor/script"
}

///|
pub fn runtime_supervisor_launch_path() -> String {
  "/api/runtime/supervisor/launch"
}

///|
pub fn runtime_supervisor_run_path() -> String {
  "/api/runtime/supervisor/run"
}

///|
pub fn runtime_health_path() -> String {
  "/api/runtime/health"
}

///|
pub fn runtime_log_path() -> String {
  "/api/runtime/log"
}

///|
pub fn runtime_validation_path() -> String {
  "/api/runtime/validation"
}

///|
pub fn runtime_validation_session_path() -> String {
  "/api/runtime/validation/session"
}

///|
pub fn runtime_supervisor_start_path() -> String {
  "/api/runtime/supervisor/start"
}

///|
pub fn runtime_supervisor_stop_path() -> String {
  "/api/runtime/supervisor/stop"
}

///|
pub fn runtime_emergency_stop_path() -> String {
  "/api/runtime/emergency-stop"
}

///|
pub fn resident_path() -> String {
  "/api/moontown/resident"
}

///|
pub fn reviews_path() -> String {
  "/api/reviews"
}

///|
pub fn moonclaw_context_path() -> String {
  "/api/moonclaw/context"
}

///|
pub fn moonstat_status_path() -> String {
  "/api/moonstat/status"
}

///|
pub fn platform_readiness_path() -> String {
  "/api/moonrobo/readiness"
}

///|
pub fn intent_evaluate_path() -> String {
  "/api/intents/evaluate"
}

///|
pub fn intent_dry_run_path() -> String {
  "/api/intents/dry-run"
}

///|
pub fn intent_approve_path() -> String {
  "/api/intents/approve"
}

///|
pub fn intent_execute_path() -> String {
  "/api/intents/execute"
}

///|
pub fn policy_evaluate_path() -> String {
  "/api/policies/evaluate"
}

///|
fn json_response(status : Int, body : Json) -> HostApiResponse {
  { status, content_type: "application/json", body: body.stringify(indent=2) }
}

///|
fn text_response(status : Int, body : String) -> HostApiResponse {
  { status, content_type: "text/plain", body }
}

///|
fn error_response(
  status : Int,
  code : String,
  path : String,
  message : String,
) -> HostApiResponse {
  json_response(status, { code, path, message }.to_json())
}

///|
fn pipeline_error_response(error : @pipeline.PipelineIssue) -> HostApiResponse {
  error_response(error.http_status, error.code, error.path, error.message)
}

///|
fn receipts_or_empty(root : String) -> Array[@core.RunReceipt] {
  match @runtime.list_run_receipts(root) {
    Ok(receipts) => receipts
    Err(_) => []
  }
}

///|
fn agent_process_records_or_empty(
  root : String,
) -> Array[@agent_process.AgentProcessRunRecord] {
  match @agent_process.list_agent_process_records(root) {
    Ok(records) => records
    Err(_) => []
  }
}

///|
fn reviews_or_empty(root : String) -> Array[@review.ProcessReview] {
  match @runtime.list_process_reviews(root) {
    Ok(reviews) => reviews
    Err(_) => []
  }
}

///|
fn review_needs_human(review : @review.ProcessReview) -> Bool {
  review.disposition == NeedsHumanReview
}

///|
fn needs_human_count(reviews : Array[@review.ProcessReview]) -> Int {
  let mut count = 0
  for review in reviews {
    if review_needs_human(review) {
      count += 1
    }
  }
  count
}

///|
fn sidecar_spec(
  profile : @core.RobotProfile,
  root : String,
) -> @bridge_sidecar.BridgeSidecarSpec {
  @bridge_sidecar.spec_for_profile(profile, root)
}

///|
fn command_available(command : Array[String]) -> Bool {
  !command.is_empty() && @fsx.path_exists(command[0])
}

///|
fn sidecar_status(
  profile : @core.RobotProfile,
  root : String,
) -> @bridge_sidecar.BridgeSidecarStatus {
  let spec = sidecar_spec(profile, root)
  @bridge_sidecar.status_for_spec(spec, command_available(spec.command))
}

///|
fn physical_runtime_spec(
  profile : @core.RobotProfile,
  root : String,
) -> @bridge_sidecar.PhysicalRuntimeSpec {
  @bridge_sidecar.runtime_spec_for_profile(profile, root)
}

///|
fn maybe_text(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
fn bridge_health_for_submission(
  profile : @core.RobotProfile,
  request : IntentSubmissionRequest,
) -> @core.BridgeHealth {
  if request.telemetry_age_ms < 0 {
    @mock_bridge.health(profile, telemetry_age_ms=-1)
  } else {
    @mock_bridge.health(profile, telemetry_age_ms=request.telemetry_age_ms)
  }
}

///|
fn bridge_health_for_policy(
  profile : @core.RobotProfile,
  telemetry_age_ms : Int,
) -> @core.BridgeHealth {
  if telemetry_age_ms < 0 {
    @mock_bridge.health(profile, telemetry_age_ms=-1)
  } else {
    @mock_bridge.health(profile, telemetry_age_ms~)
  }
}

///|
fn intent_for_submission(
  profile : @core.RobotProfile,
  request : IntentSubmissionRequest,
) -> @core.CommandIntent {
  @core.command_intent(
    request.intent_id,
    if request.robot_id == "" {
      profile.id
    } else {
      request.robot_id
    },
    request.capability,
    request.requester,
    parameters=request.parameters,
  )
}

///|
fn decode_policy_evaluation(
  body : String,
  path : String,
) -> Result[PolicyEvaluationRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-policy-evaluation",
        path,
        message: "failed to parse policy evaluation JSON",
      })
  }
  let request : PolicyEvaluationRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-policy-evaluation",
        path,
        message: "failed to decode policy evaluation contract",
      })
  }
  Ok(request)
}

///|
fn decode_submission(
  body : String,
  path : String,
) -> Result[IntentSubmissionRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-intent-submission",
        path,
        message: "failed to parse intent submission JSON",
      })
  }
  let request : IntentSubmissionRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-intent-submission",
        path,
        message: "failed to decode intent submission contract",
      })
  }
  Ok(request)
}

///|
fn evaluate_submission(
  book : @runtime.LoadedRoboBook,
  request : IntentSubmissionRequest,
  approval_id : String?,
  dry_run_receipt_id : @core.ReceiptId?,
) -> @pipeline.PipelineResult {
  let health = bridge_health_for_submission(book.profile, request)
  let intent = intent_for_submission(book.profile, request)
  match (approval_id, dry_run_receipt_id) {
    (Some(approval_id), Some(dry_run_receipt_id)) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        approval_id~,
        dry_run_receipt_id~,
        developer_gate=request.developer_gate,
      )
    (Some(approval_id), None) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        approval_id~,
        developer_gate=request.developer_gate,
      )
    (None, Some(dry_run_receipt_id)) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        dry_run_receipt_id~,
        developer_gate=request.developer_gate,
      )
    (None, None) =>
      @pipeline.evaluate_request(
        book.profile,
        health,
        intent,
        request.receipt_id,
        request.now_ms,
        developer_gate=request.developer_gate,
      )
  }
}

///|
fn load_submission(
  root : String,
  body : String,
  path : String,
) -> Result[(@runtime.LoadedRoboBook, IntentSubmissionRequest), HostApiResponse] {
  let request = match decode_submission(body, path) {
    Ok(request) => request
    Err(error) =>
      return Err(error_response(400, error.code, error.path, error.message))
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  Ok((book, request))
}

///|
pub fn policy_evaluation_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_policy_evaluation(body, policy_evaluate_path()) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let evaluation = @policy.evaluate_proposal(
    book.profile,
    bridge_health_for_policy(book.profile, request.telemetry_age_ms),
    request.proposal,
    request.evaluation_id,
    request.receipt_id,
    request.now_ms,
    request.quality_report,
  )
  let receipt_path = match
    @runtime.write_run_receipt(root, evaluation.result.receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let evaluation_path = match
    @runtime.write_policy_evaluation_json(
      root,
      evaluation.evaluation_id,
      @policy.evaluation_json(evaluation),
    ) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    { persisted: true, evaluation_path, receipt_path, evaluation }.to_json(),
  )
}

///|
pub fn intent_submission_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let (book, request) = match
    load_submission(root, body, intent_evaluate_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(
    book,
    request,
    maybe_text(request.approval_id),
    maybe_text(request.dry_run_receipt_id),
  )
  match @runtime.write_run_receipt(root, result.receipt) {
    Ok(path) =>
      json_response(
        200,
        { persisted: true, receipt_path: path, result }.to_json(),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
fn generated_dry_run_id(request : IntentSubmissionRequest) -> @core.ReceiptId {
  match maybe_text(request.dry_run_receipt_id) {
    Some(value) => value
    None => "dry-run-\{request.intent_id}-\{request.now_ms}"
  }
}

///|
fn generated_approval_id(request : IntentSubmissionRequest) -> String {
  match maybe_text(request.approval_id) {
    Some(value) => value
    None => "approval-\{request.intent_id}-\{request.now_ms}"
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
fn dry_run_id_or_error(
  request : IntentSubmissionRequest,
  path : String,
) -> Result[@core.ReceiptId, HostApiResponse] {
  match maybe_text(request.dry_run_receipt_id) {
    Some(value) => Ok(value)
    None =>
      Err(
        error_response(
          400, "missing-dry-run", path, "request requires a dry-run receipt id",
        ),
      )
  }
}

///|
fn approval_id_or_error(
  request : IntentSubmissionRequest,
  path : String,
) -> Result[String, HostApiResponse] {
  match maybe_text(request.approval_id) {
    Some(value) => Ok(value)
    None =>
      Err(
        error_response(
          400, "missing-approval", path, "request requires an approval id",
        ),
      )
  }
}

///|
fn matching_dry_run_or_response(
  root : String,
  dry_run_receipt_id : @core.ReceiptId,
  expected_intent : @core.CommandIntent,
  path : String,
) -> Result[@core.DryRunEvidence, HostApiResponse] {
  let dry_run = match @runtime.read_dry_run_evidence(root, dry_run_receipt_id) {
    Ok(value) => value
    Err(issue) =>
      return Err(error_response(400, issue.code, issue.path, issue.message))
  }
  if !same_intent_identity(dry_run.intent, expected_intent) {
    return Err(
      error_response(
        400, "dry-run-mismatch", path, "dry-run evidence does not match the submitted intent",
      ),
    )
  }
  Ok(dry_run)
}

///|
fn matching_approval_or_response(
  root : String,
  approval_id : String,
  dry_run_receipt_id : @core.ReceiptId,
  expected_intent : @core.CommandIntent,
  path : String,
) -> Result[@core.ApprovalRecord, HostApiResponse] {
  let approval = match @runtime.read_approval_record(root, approval_id) {
    Ok(value) => value
    Err(issue) =>
      return Err(error_response(400, issue.code, issue.path, issue.message))
  }
  if approval.dry_run_receipt_id != dry_run_receipt_id ||
    !same_intent_identity(approval.intent, expected_intent) {
    return Err(
      error_response(
        400, "approval-mismatch", path, "approval record does not match the submitted intent and dry run",
      ),
    )
  }
  Ok(approval)
}

///|
fn bridge_operation_label(
  operation : @bridge_protocol.BridgeOperation,
) -> String {
  match operation {
    Contract => "Contract"
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
fn bridge_response_status_label(
  status : @bridge_protocol.BridgeResponseStatus,
) -> String {
  match status {
    Accepted => "Accepted"
    Rejected => "Rejected"
    Error => "Error"
  }
}

///|
fn bridge_dispatch_id(request : @bridge_protocol.BridgeRequest) -> String {
  "dispatch-\{request.request_id}"
}

///|
fn persist_bridge_execution(
  root : String,
  profile : @core.RobotProfile,
  expected_intent : @core.CommandIntent,
  ready_receipt : @core.RunReceipt,
  receipt_id : @core.ReceiptId,
  now_ms : Int64,
  path : String,
) -> Result[PersistedBridgeExecution, HostApiResponse] {
  let bridge_request = @bridge_protocol.execute_request(
    "request-execute-\{expected_intent.intent_id}-\{now_ms}",
    profile,
    expected_intent,
    now_ms,
  )
  match @bridge_protocol.validate_request(profile, bridge_request) {
    Err(issue) =>
      return Err(error_response(400, issue.code, path, issue.message))
    Ok(_) => ()
  }
  let receipt = @core.executed_receipt(
    receipt_id,
    ready_receipt,
    now_ms,
    telemetry_frame_count=1,
  )
  let bridge_response = @bridge_protocol.receipt_response(
    bridge_request, receipt,
  )
  let route = @bridge_protocol.route_for_request(bridge_request)
  let bridge_dispatch = @core.bridge_dispatch_evidence(
    bridge_dispatch_id(bridge_request),
    bridge_request.request_id,
    bridge_request.bridge_id,
    bridge_request.robot_id,
    bridge_operation_label(bridge_request.operation),
    route.http_method,
    route.path,
    expected_intent.intent_id,
    receipt.receipt_id,
    bridge_response_status_label(bridge_response.status),
    bridge_response.message,
    now_ms,
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let dispatch_path = match
    @runtime.write_bridge_dispatch_evidence(root, bridge_dispatch) {
    Ok(path) => path
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  Ok({ receipt_path, dispatch_path, receipt, bridge_response, bridge_dispatch })
}

///|
pub fn dry_run_submission_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let (book, request) = match
    load_submission(root, body, intent_dry_run_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let result = evaluate_submission(book, request, None, None)
  if result.next_action != CollectDryRun {
    return error_response(
      400,
      "dry-run-not-required",
      intent_dry_run_path(),
      "current safety result does not request a dry run",
    )
  }
  let dry_run = @core.dry_run_evidence(
    generated_dry_run_id(request),
    result.receipt,
    "Dry-run evidence captured for command review; hardware execution was not invoked.",
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
    { persisted: true, receipt_path, dry_run_path, dry_run, result }.to_json(),
  )
}

///|
pub fn approval_submission_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let (book, request) = match
    load_submission(root, body, intent_approve_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let dry_run_receipt_id = match
    dry_run_id_or_error(request, intent_approve_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let expected_intent = intent_for_submission(book.profile, request)
  let _dry_run = match
    matching_dry_run_or_response(
      root,
      dry_run_receipt_id,
      expected_intent,
      intent_approve_path(),
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
      400,
      "approval-not-required",
      intent_approve_path(),
      "current safety result does not request approval",
    )
  }
  let approval = @core.approval_record(
    generated_approval_id(request),
    dry_run_receipt_id,
    expected_intent,
    request.requester,
    "Operator approval recorded for ready-for-execution evaluation.",
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
    { persisted: true, receipt_path, approval_path, approval, result }.to_json(),
  )
}

///|
pub fn execution_submission_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let (book, request) = match
    load_submission(root, body, intent_execute_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let dry_run_receipt_id = match
    dry_run_id_or_error(request, intent_execute_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let approval_id = match approval_id_or_error(request, intent_execute_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let expected_intent = intent_for_submission(book.profile, request)
  let _dry_run = match
    matching_dry_run_or_response(
      root,
      dry_run_receipt_id,
      expected_intent,
      intent_execute_path(),
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let _approval = match
    matching_approval_or_response(
      root,
      approval_id,
      dry_run_receipt_id,
      expected_intent,
      intent_execute_path(),
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
      400,
      "not-ready-for-execution",
      intent_execute_path(),
      "safety pipeline did not produce a ready-for-execution receipt",
    )
  }
  let persisted = match
    persist_bridge_execution(
      root,
      book.profile,
      expected_intent,
      result.receipt,
      request.receipt_id,
      request.now_ms,
      intent_execute_path(),
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  json_response(
    200,
    {
      persisted: true,
      receipt_path: persisted.receipt_path,
      dispatch_path: persisted.dispatch_path,
      receipt: persisted.receipt,
      bridge_response: persisted.bridge_response,
      bridge_dispatch: persisted.bridge_dispatch,
      result,
    }.to_json(),
  )
}

///|
fn walk_safety(
  profile : @core.RobotProfile,
  health : @core.BridgeHealth,
) -> @pipeline.PipelineResult {
  let intent = @pipeline.high_walk_intent(
    "intent-host-cockpit-walk",
    profile.id,
    @core.operator_requester("host-api"),
    "0.10",
    "0.00",
    "1000",
  )
  @pipeline.evaluate_request(
    profile, health, intent, "receipt-host-cockpit-walk", 0L,
  )
}

///|
pub fn cockpit_snapshot(
  root : String,
) -> Result[@cockpit.CockpitSnapshot, @runtime.RuntimeIssue] {
  match @runtime.load_robobook(root) {
    Err(issue) => Err(issue)
    Ok(book) => {
      let bridge = @mock_bridge.new(book.profile)
      let health = @mock_bridge.health(book.profile, telemetry_age_ms=0)
      let frame = @mock_bridge.telemetry_frame(book.profile, bridge, 0L)
      Ok(
        @cockpit.snapshot(
          book,
          health,
          sidecar_status(book.profile, root),
          frame,
          walk_safety(book.profile, health),
          receipts_or_empty(root),
        ),
      )
    }
  }
}

///|
pub fn snapshot_response(root : String) -> HostApiResponse {
  match cockpit_snapshot(root) {
    Ok(snapshot) => json_response(200, snapshot.to_json())
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn health_response(root : String) -> HostApiResponse {
  let status = match @runtime.load_robobook(root) {
    Ok(book) => if book.status.ready { "ready" } else { "not-ready" }
    Err(_) => "error"
  }
  json_response(
    200,
    {
      service: "moonrobo",
      robobook_root: root,
      status,
      snapshot_path: snapshot_path(),
      read_only: true,
    }.to_json(),
  )
}

///|
pub fn bridge_sidecar_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) =>
      json_response(200, {
        "spec": sidecar_spec(book.profile, root).to_json(),
        "status": sidecar_status(book.profile, root).to_json(),
        "runtime": physical_runtime_spec(book.profile, root).to_json(),
      })
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn runtime_supervisor_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) =>
      json_response(
        200,
        @supervisor.plan(physical_runtime_spec(book.profile, root)).to_json(),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn runtime_supervisor_script_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) =>
      text_response(
        200,
        @supervisor.shell_script(
          @supervisor.plan(physical_runtime_spec(book.profile, root)),
        ),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn runtime_supervisor_launch_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) => {
      let plan = @supervisor.plan(physical_runtime_spec(book.profile, root))
      match @runtime_launcher.prepare_launch(root, plan) {
        Ok(result) => json_response(200, result.to_json())
        Err(issue) =>
          error_response(
            issue.http_status,
            issue.code,
            issue.path,
            issue.message,
          )
      }
    }
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
fn observation_sessions_or_empty(
  root : String,
) -> Array[@core.ObservationSession] {
  match @runtime.list_observation_sessions(root) {
    Ok(sessions) => sessions
    Err(_) => []
  }
}

///|
fn task_execution_snapshots_or_empty(
  root : String,
) -> Array[@core.TaskExecutionSnapshot] {
  let paths = match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths
    Err(_) => return []
  }
  let snapshots : Array[@core.TaskExecutionSnapshot] = []
  for path in paths {
    match @runtime.read_task_execution_snapshot_file(path) {
      Ok(snapshot) => snapshots.push(snapshot)
      Err(_) => ()
    }
  }
  snapshots
}

///|
fn proof_session_summaries_or_empty(
  root : String,
) -> Array[@resident.ResidentProofSessionSummary] {
  let paths = json_paths(root, "runs/proof-sessions")
  let summaries : Array[@resident.ResidentProofSessionSummary] = []
  for path in paths {
    let text = @fsx.read_file_to_string(path) catch { _ => continue }
    let json = @json.parse(text) catch { _ => continue }
    let session : PlatformProofSessionResponse = @json.from_json(json) catch {
      _ => continue
    }
    summaries.push(
      @resident.proof_session_summary(
        session.session_id,
        session.status,
        session.ready,
        session.attempted_count,
        session.requested_iterations,
        session.stop_reason,
        session.session_path,
        session.latest_proof_path,
        session.next_route,
        session.message,
      ),
    )
  }
  summaries
}

///|
pub fn resident_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) =>
      json_response(
        200,
        resident_projection(book, sidecar_status(book.profile, root), root).to_json(),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
fn resident_projection(
  book : @runtime.LoadedRoboBook,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  root : String,
) -> @resident.ResidentRobotAgent {
  @resident.project(
    book,
    sidecar,
    receipts_or_empty(root),
    observation_sessions_or_empty(root),
    reviews_or_empty(root),
    executions=task_execution_snapshots_or_empty(root),
    proof_sessions=proof_session_summaries_or_empty(root),
  )
}

///|
pub fn moonstat_status_response(root : String) -> HostApiResponse {
  match @runtime.load_robobook(root) {
    Ok(book) => {
      let sidecar = sidecar_status(book.profile, root)
      json_response(
        200,
        @moonstat.project(
          book,
          sidecar,
          resident_projection(book, sidecar, root),
          receipts_or_empty(root),
          observation_sessions_or_empty(root),
          reviews_or_empty(root),
          agent_process_records_or_empty(root),
          policy_evaluations_or_empty(root),
          0L,
        ).to_json(),
      )
    }
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
pub fn reviews_response(root : String) -> HostApiResponse {
  let reviews = match @runtime.list_process_reviews(root) {
    Ok(reviews) => reviews
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    {
      review_count: reviews.length(),
      needs_human_count: needs_human_count(reviews),
      reviews,
    }.to_json(),
  )
}

///|
pub fn moonclaw_context_response(root : String) -> HostApiResponse {
  let result = match moonclaw_planning_result_for(root, 0L) {
    Ok(result) => result
    Err(response) => return response
  }
  let live_readiness = match moonclaw_context_live_readiness(root) {
    Ok(value) => value
    Err(response) => return response
  }
  let proof_sessions = match moonclaw_context_proof_sessions(root) {
    Ok(value) => value
    Err(response) => return response
  }
  json_response(
    200,
    MoonClawContextResponse::{ result, live_readiness, proof_sessions }.to_json(),
  )
}

///|
fn moonclaw_context_live_readiness(
  root : String,
) -> Result[MoonroboLiveReadinessResponse, HostApiResponse] {
  let response = moonrobo_live_readiness_response(root)
  if response.status != 200 {
    return Err(response)
  }
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-moonclaw-live-readiness",
          moonrobo_live_readiness_path(),
          "failed to parse Moonrobo live-readiness context",
        ),
      )
  }
  Ok(@json.from_json(json)) catch {
    _ =>
      Err(
        error_response(
          500,
          "decode-moonclaw-live-readiness",
          moonrobo_live_readiness_path(),
          "failed to decode Moonrobo live-readiness context",
        ),
      )
  }
}

///|
fn moonclaw_context_proof_sessions(
  root : String,
) -> Result[PlatformProofSessionListResponse, HostApiResponse] {
  let response = platform_proof_sessions_response(root)
  if response.status != 200 {
    return Err(response)
  }
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-moonclaw-proof-sessions",
          platform_proof_sessions_path(),
          "failed to parse Moonrobo proof-session context",
        ),
      )
  }
  Ok(@json.from_json(json)) catch {
    _ =>
      Err(
        error_response(
          500,
          "decode-moonclaw-proof-sessions",
          platform_proof_sessions_path(),
          "failed to decode Moonrobo proof-session context",
        ),
      )
  }
}

///|
pub fn platform_readiness_response(root : String) -> HostApiResponse {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let report = @readiness.report(root, book)
  json_response(200, { report, plan: @readiness.plan(report) }.to_json())
}

///|
pub fn route(
  root : String,
  http_method : String,
  path : String,
) -> HostApiResponse {
  route_with_body(root, http_method, path, "")
}

///|
pub fn route_with_body(
  root : String,
  http_method : String,
  path : String,
  body : String,
) -> HostApiResponse {
  if http_method == "GET" {
    match path {
      "/api/cockpit/snapshot" => snapshot_response(root)
      "/api/health" => health_response(root)
      "/api/bridge/sidecar" => bridge_sidecar_response(root)
      "/api/runtime/supervisor" => runtime_supervisor_response(root)
      "/api/runtime/supervisor/script" =>
        runtime_supervisor_script_response(root)
      "/api/moontown/resident" => resident_response(root)
      "/api/moonstat/status" => moonstat_status_response(root)
      "/api/moonrobo/readiness" => platform_readiness_response(root)
      "/api/moonrobo/session" => robo_session_response(root)
      "/api/moonrobo/live-readiness" => moonrobo_live_readiness_response(root)
      "/api/moonrobo/decision" => robo_decision_response(root)
      "/api/moonrobo/loop-proof" => platform_loop_proof_response(root)
      "/api/moonrobo/proof-sessions" => platform_proof_sessions_response(root)
      "/api/moonrobo/loops" => robo_loops_response(root)
      "/api/moonrobo/turns" => robo_turns_response(root)
      "/api/moonrobo/steps" => robo_steps_response(root)
      "/api/moonbook/memory" => moonbook_memory_response(root)
      "/api/moonbook/task-messages" => moonbook_task_messages_response(root)
      "/api/moonbook/conversation" => moonbook_conversation_response(root)
      "/api/moonrobo/executions" => task_executions_response(root)
      "/api/agent/work-queue" => agent_work_queue_response(root)
      "/api/agent/next-action" => agent_next_action_response(root)
      "/api/agent/runtime-calibration/latest" =>
        runtime_calibration_response(root)
      "/api/tools/registry" => tool_registry_response(root)
      "/api/reviews" => reviews_response(root)
      "/api/moonclaw/context" => moonclaw_context_response(root)
      "/api/moonclaw/runs" => moonclaw_runs_response(root)
      _ =>
        if path.has_prefix("/api/datasets/episodes/") &&
          path.has_suffix("/quality") {
          dataset_episode_quality_response(root, path)
        } else if path.has_prefix("/api/datasets/episodes/") {
          dataset_episode_response(root, path)
        } else if path == policy_evaluations_path() {
          policy_evaluations_response(root)
        } else if path.has_prefix("/api/policies/evaluations/") {
          policy_evaluation_detail_response(root, path)
        } else if is_moonbook_task_message_status_path(path) {
          moonbook_task_message_status_response(root, path)
        } else if path.has_prefix("/api/moonbook/task-messages/") {
          moonbook_task_message_response(root, path)
        } else if path.has_prefix("/api/moonclaw/runs/") {
          moonclaw_run_response(root, path)
        } else if path.has_prefix("/api/moonrobo/loops/") {
          robo_loop_detail_response(root, path)
        } else if path.has_prefix("/api/moonrobo/turns/") {
          robo_turn_detail_response(root, path)
        } else if path.has_prefix("/api/moonrobo/steps/") {
          robo_step_detail_response(root, path)
        } else if path.has_prefix("/api/moonrobo/proof-sessions/") {
          platform_proof_session_detail_response(root, path)
        } else if path.has_prefix("/api/reviews/") {
          review_response(root, path)
        } else if replay_annotation_id_from_path(path) is Some(_) {
          replay_annotation_response(root, path)
        } else if session_id_from_replay_annotations_path(path) is Some(_) {
          replay_annotations_response(root, path)
        } else if path.has_prefix("/api/replays/") {
          replay_response(root, path)
        } else {
          error_response(404, "not-found", path, "No Moonrobo host API route")
        }
    }
  } else if http_method == "POST" {
    match path {
      "/api/intents/evaluate" => intent_submission_response(root, body)
      "/api/intents/dry-run" => dry_run_submission_response(root, body)
      "/api/intents/approve" => approval_submission_response(root, body)
      "/api/intents/execute" => execution_submission_response(root, body)
      "/api/policies/evaluate" => policy_evaluation_response(root, body)
      "/api/runtime/supervisor/launch" =>
        runtime_supervisor_launch_response(root)
      "/api/sessions/observe" => observation_start_response(root, body)
      "/api/moontown/tasks/observe" =>
        moontown_observe_task_response(root, body)
      "/api/moontown/tasks/message" =>
        moontown_task_message_response(root, body)
      "/api/moontown/tasks/observe-run" =>
        moontown_observe_run_response(root, body)
      "/api/moonrobo/bootstrap" => platform_bootstrap_response(root, body)
      "/api/moonrobo/advance" => platform_advance_response(root, body)
      "/api/moonrobo/ask" => robo_ask_response(root, body)
      "/api/moonrobo/loop" => robo_loop_response(root, body)
      "/api/moonrobo/turn" => robo_turn_response(root, body)
      "/api/moonrobo/step" => robo_step_response(root, body)
      "/api/moonrobo/first-loop" => platform_first_loop_response(root, body)
      "/api/moonrobo/task-loop" => platform_task_loop_response(root, body)
      "/api/moonrobo/task-loop/continue" =>
        platform_task_loop_continue_response(root, body)
      "/api/moonrobo/runtime-proof" =>
        platform_runtime_proof_response(root, body)
      "/api/moonrobo/prove-loop" => platform_prove_loop_response(root, body)
      "/api/moonrobo/proof-session" =>
        platform_proof_session_response(root, body)
      "/api/moonrobo/executions/feedback" =>
        task_execution_feedback_response(root, body)
      "/api/moonclaw/run-next" => moonclaw_run_next_response(root, body)
      "/api/moonclaw/robot-routine" =>
        moonclaw_robot_routine_response(root, body)
      "/api/moonclaw/work-step" => moonclaw_work_step_response(root, body)
      "/api/moonclaw/work-run" => moonclaw_work_run_response(root, body)
      "/api/runtime/validation/session" =>
        runtime_validation_session_response(root, body)
      "/api/agent/dispatch-next" => agent_dispatch_next_response(root, body)
      "/api/agent/runtime-calibration/resolve" =>
        runtime_calibration_resolve_response(root, body)
      "/api/tools/register" => tool_register_response(root, body)
      "/api/moonbook/remember" => moonbook_remember_response(root)
      _ =>
        if session_id_from_observation_frame_path(path) is Some(_) {
          observation_frame_response(root, path, body)
        } else if session_id_from_observation_stop_path(path) is Some(_) {
          observation_stop_response(root, path, body)
        } else if path.has_prefix("/api/moonbook/task-messages/") &&
          path.has_suffix("/evaluate") {
          moonbook_task_message_evaluate_response(root, path)
        } else if path.has_prefix("/api/moonbook/task-messages/") &&
          path.has_suffix("/dry-run") {
          moonbook_task_message_dry_run_response(root, path)
        } else if path.has_prefix("/api/moonbook/task-messages/") &&
          path.has_suffix("/approve") {
          moonbook_task_message_approve_response(root, path)
        } else if path.has_prefix("/api/moonbook/task-messages/") &&
          path.has_suffix("/execute") {
          moonbook_task_message_execute_response(root, path)
        } else if session_id_from_replay_annotations_path(path) is Some(_) {
          replay_annotation_submission_response(root, path, body)
        } else if path.has_prefix("/api/reviews/") &&
          path.has_suffix("/resolve") {
          review_resolution_response(root, path, body)
        } else {
          error_response(404, "not-found", path, "No Moonrobo host API route")
        }
    }
  } else {
    error_response(
      405, "method-not-allowed", path, "Only GET and POST are supported",
    )
  }
}
