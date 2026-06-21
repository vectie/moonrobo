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
  robotbook_root : String
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
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  result : @pipeline.PipelineResult
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
fn json_response(status : Int, body : Json) -> HostApiResponse {
  { status, content_type: "application/json", body: body.stringify(indent=2) }
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
  book : @runtime.LoadedRobotBook,
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
) -> Result[
  (@runtime.LoadedRobotBook, IntentSubmissionRequest),
  HostApiResponse,
] {
  let request = match decode_submission(body, path) {
    Ok(request) => request
    Err(error) =>
      return Err(error_response(400, error.code, error.path, error.message))
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  Ok((book, request))
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
  let bridge_request = @bridge_protocol.execute_request(
    "request-execute-\{request.intent_id}-\{request.now_ms}",
    book.profile,
    expected_intent,
    request.now_ms,
  )
  match @bridge_protocol.validate_request(book.profile, bridge_request) {
    Err(issue) =>
      return error_response(
        400,
        issue.code,
        intent_execute_path(),
        issue.message,
      )
    Ok(_) => ()
  }
  let receipt = @core.executed_receipt(
    request.receipt_id,
    result.receipt,
    request.now_ms,
    telemetry_frame_count=1,
  )
  let bridge_response = @bridge_protocol.receipt_response(
    bridge_request, receipt,
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(
    200,
    { persisted: true, receipt_path, receipt, bridge_response, result }.to_json(),
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
  match @runtime.load_robotbook(root) {
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
  let status = match @runtime.load_robotbook(root) {
    Ok(book) => if book.status.ready { "ready" } else { "not-ready" }
    Err(_) => "error"
  }
  json_response(
    200,
    {
      service: "moonrobo",
      robotbook_root: root,
      status,
      snapshot_path: snapshot_path(),
      read_only: true,
    }.to_json(),
  )
}

///|
pub fn bridge_sidecar_response(root : String) -> HostApiResponse {
  match @runtime.load_robotbook(root) {
    Ok(book) =>
      json_response(200, {
        "spec": sidecar_spec(book.profile, root).to_json(),
        "status": sidecar_status(book.profile, root).to_json(),
      })
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
pub fn resident_response(root : String) -> HostApiResponse {
  match @runtime.load_robotbook(root) {
    Ok(book) =>
      json_response(
        200,
        @resident.project(
          book,
          sidecar_status(book.profile, root),
          receipts_or_empty(root),
          observation_sessions_or_empty(root),
          reviews_or_empty(root),
        ).to_json(),
      )
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
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let reviews = reviews_or_empty(root)
  let resident = @resident.project(
    book,
    sidecar_status(book.profile, root),
    receipts_or_empty(root),
    observation_sessions_or_empty(root),
    reviews,
  )
  json_response(
    200,
    { result: @moonclaw.planning_result(resident, reviews, 0L) }.to_json(),
  )
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
      "/api/moontown/resident" => resident_response(root)
      "/api/reviews" => reviews_response(root)
      "/api/moonclaw/context" => moonclaw_context_response(root)
      "/api/moonclaw/runs" => moonclaw_runs_response(root)
      _ =>
        if path.has_prefix("/api/replays/") {
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
      "/api/sessions/observe" => observation_start_response(root, body)
      "/api/moontown/tasks/observe" =>
        moontown_observe_task_response(root, body)
      "/api/moontown/tasks/observe-run" =>
        moontown_observe_run_response(root, body)
      "/api/moonclaw/run-next" => moonclaw_run_next_response(root, body)
      _ =>
        if session_id_from_observation_frame_path(path) is Some(_) {
          observation_frame_response(root, path, body)
        } else if session_id_from_observation_stop_path(path) is Some(_) {
          observation_stop_response(root, path, body)
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
