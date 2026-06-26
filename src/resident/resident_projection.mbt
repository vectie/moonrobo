///|
pub(all) struct ResidentObservationSummary {
  session_id : String
  status : String
  telemetry_frame_count : Int
  latest_frame_id : String?
  latest_artifact_path : String?
  started_at_ms : Int64
  stopped_at_ms : Int64?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ResidentReceiptSummary {
  receipt_id : @core.ReceiptId
  status : String
  capability : @core.CapabilityId
  started_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ResidentExecutionSummary {
  snapshot_id : String
  task_id : String
  status : String
  verified : Bool
  message : String
  receipt_id : @core.ReceiptId
  command_capability : @core.CapabilityId
  bridge_status : String
  runtime_status : String
  runtime_health_persisted : Bool
  telemetry_frame_id : String
  physical_feedback_path : String
  physical_feedback_status : String
  physical_feedback_verified : Bool
  command_outcome_status : String
  command_outcome_verified : Bool
  captured_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ResidentProofSessionSummary {
  session_id : String
  status : String
  ready : Bool
  attempted_count : Int
  requested_iterations : Int
  stop_reason : String
  session_path : String
  latest_proof_path : String
  next_route : String
  feedback_binding_required_count : Int
  feedback_binding_success_count : Int
  feedback_closed : Bool
  latest_feedback_status : Int
  latest_feedback_message : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ResidentRobotAgent {
  resident_id : String
  robot_id : @core.RobotId
  label : String
  platform : String
  role : String
  availability : String
  safety_state : String
  bridge_state : String
  active_observation : ResidentObservationSummary?
  latest_observation : ResidentObservationSummary?
  latest_receipt : ResidentReceiptSummary?
  latest_execution : ResidentExecutionSummary?
  latest_proof_session : ResidentProofSessionSummary?
  execution_count : Int
  verified_execution_count : Int
  proof_session_count : Int
  capability_count : Int
  review_count : Int
  command_path : String
  town_route : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn run_status_text(status : @core.RunStatus) -> String {
  match status {
    Denied => "denied"
    WaitingForApproval => "waiting-for-approval"
    WaitingForDryRun => "waiting-for-dry-run"
    ReadyForExecution => "ready-for-execution"
    Executed => "executed"
    Failed => "failed"
  }
}

///|
fn observation_status_text(status : @core.ObservationStatus) -> String {
  match status {
    Active => "active"
    Stopped => "stopped"
  }
}

///|
fn sidecar_state_text(state : @bridge_sidecar.SidecarState) -> String {
  match state {
    MissingCommand => "missing-command"
    Launchable => "launchable"
  }
}

///|
fn latest_artifact_path(paths : Array[String]) -> String? {
  if paths.is_empty() {
    None
  } else {
    Some(paths[paths.length() - 1])
  }
}

///|
pub fn observation_summary(
  session : @core.ObservationSession,
) -> ResidentObservationSummary {
  {
    session_id: session.session_id,
    status: observation_status_text(session.status),
    telemetry_frame_count: session.telemetry_frame_count,
    latest_frame_id: session.latest_frame_id,
    latest_artifact_path: latest_artifact_path(session.artifact_paths),
    started_at_ms: session.started_at_ms,
    stopped_at_ms: session.stopped_at_ms,
  }
}

///|
pub fn receipt_summary(receipt : @core.RunReceipt) -> ResidentReceiptSummary {
  {
    receipt_id: receipt.receipt_id,
    status: run_status_text(receipt.status),
    capability: receipt.intent.capability,
    started_at_ms: receipt.started_at_ms,
  }
}

///|
pub fn execution_summary(
  snapshot : @core.TaskExecutionSnapshot,
) -> ResidentExecutionSummary {
  let proof = @core.task_execution_proof(snapshot)
  {
    snapshot_id: snapshot.snapshot_id,
    task_id: snapshot.task_id,
    status: proof.status,
    verified: proof.verified,
    message: proof.message,
    receipt_id: snapshot.receipt_id,
    command_capability: snapshot.command_capability,
    bridge_status: snapshot.bridge_status,
    runtime_status: snapshot.runtime_status,
    runtime_health_persisted: snapshot.runtime_health_persisted,
    telemetry_frame_id: snapshot.telemetry_frame_id,
    physical_feedback_path: snapshot.physical_feedback_path,
    physical_feedback_status: snapshot.physical_feedback_status,
    physical_feedback_verified: snapshot.physical_feedback_verified,
    command_outcome_status: snapshot.command_outcome_status,
    command_outcome_verified: snapshot.command_outcome_verified,
    captured_at_ms: snapshot.captured_at_ms,
  }
}

///|
pub fn proof_session_summary(
  session_id : String,
  status : String,
  ready : Bool,
  attempted_count : Int,
  requested_iterations : Int,
  stop_reason : String,
  session_path : String,
  latest_proof_path : String,
  next_route : String,
  feedback_binding_required_count : Int,
  feedback_binding_success_count : Int,
  feedback_closed : Bool,
  latest_feedback_status : Int,
  latest_feedback_message : String,
  message : String,
) -> ResidentProofSessionSummary {
  {
    session_id,
    status,
    ready,
    attempted_count,
    requested_iterations,
    stop_reason,
    session_path,
    latest_proof_path,
    next_route,
    feedback_binding_required_count,
    feedback_binding_success_count,
    feedback_closed,
    latest_feedback_status,
    latest_feedback_message,
    message,
  }
}

///|
fn latest_receipt(
  receipts : Array[@core.RunReceipt],
) -> ResidentReceiptSummary? {
  if receipts.is_empty() {
    None
  } else {
    Some(receipt_summary(receipts[receipts.length() - 1]))
  }
}

///|
fn latest_observation(
  sessions : Array[@core.ObservationSession],
) -> ResidentObservationSummary? {
  if sessions.is_empty() {
    None
  } else {
    Some(observation_summary(sessions[sessions.length() - 1]))
  }
}

///|
fn latest_execution(
  snapshots : Array[@core.TaskExecutionSnapshot],
) -> ResidentExecutionSummary? {
  if snapshots.is_empty() {
    None
  } else {
    Some(execution_summary(snapshots[snapshots.length() - 1]))
  }
}

///|
fn latest_proof_session(
  sessions : Array[ResidentProofSessionSummary],
) -> ResidentProofSessionSummary? {
  if sessions.is_empty() {
    None
  } else {
    Some(sessions[sessions.length() - 1])
  }
}

///|
fn verified_execution_count(
  snapshots : Array[@core.TaskExecutionSnapshot],
) -> Int {
  let mut count = 0
  for snapshot in snapshots {
    if @core.task_execution_proof(snapshot).verified {
      count += 1
    }
  }
  count
}

///|
fn active_observation(
  sessions : Array[@core.ObservationSession],
) -> ResidentObservationSummary? {
  let mut found : ResidentObservationSummary? = None
  for session in sessions {
    if session.status == Active {
      found = Some(observation_summary(session))
    }
  }
  found
}

///|
fn receipt_needs_review(receipt : @core.RunReceipt) -> Bool {
  match receipt.status {
    Denied | WaitingForApproval | WaitingForDryRun | Failed => true
    ReadyForExecution | Executed => false
  }
}

///|
fn review_count(receipts : Array[@core.RunReceipt]) -> Int {
  let mut count = 0
  for receipt in receipts {
    if receipt_needs_review(receipt) {
      count += 1
    }
  }
  count
}

///|
fn process_review_needs_human(review : @review.ProcessReview) -> Bool {
  review.disposition == NeedsHumanReview
}

///|
fn process_review_count(reviews : Array[@review.ProcessReview]) -> Int {
  let mut count = 0
  for review in reviews {
    if process_review_needs_human(review) {
      count += 1
    }
  }
  count
}

///|
fn total_review_count(
  receipts : Array[@core.RunReceipt],
  reviews : Array[@review.ProcessReview],
) -> Int {
  review_count(receipts) + process_review_count(reviews)
}

///|
fn safety_state(
  receipts : Array[@core.RunReceipt],
  reviews : Array[@review.ProcessReview],
) -> String {
  if total_review_count(receipts, reviews) > 0 {
    "review-required"
  } else {
    "clear"
  }
}

///|
fn availability(
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  active : ResidentObservationSummary?,
) -> String {
  match active {
    Some(_) => "observing"
    None =>
      match sidecar.state {
        Launchable => "ready"
        MissingCommand => "bridge-missing"
      }
  }
}

///|
pub fn resident_id(profile : @core.RobotProfile) -> String {
  "robot:\{profile.id}"
}

///|
pub fn town_route(profile : @core.RobotProfile) -> String {
  "/town/residents/\{resident_id(profile)}"
}

///|
pub fn project(
  book : @runtime.LoadedRoboBook,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  receipts : Array[@core.RunReceipt],
  sessions : Array[@core.ObservationSession],
  reviews : Array[@review.ProcessReview],
  executions? : Array[@core.TaskExecutionSnapshot] = [],
  proof_sessions? : Array[ResidentProofSessionSummary] = [],
) -> ResidentRobotAgent {
  let active = active_observation(sessions)
  {
    resident_id: resident_id(book.profile),
    robot_id: book.profile.id,
    label: book.profile.label,
    platform: book.profile.platform,
    role: "physical-robot",
    availability: availability(sidecar, active),
    safety_state: safety_state(receipts, reviews),
    bridge_state: sidecar_state_text(sidecar.state),
    active_observation: active,
    latest_observation: latest_observation(sessions),
    latest_receipt: latest_receipt(receipts),
    latest_execution: latest_execution(executions),
    latest_proof_session: latest_proof_session(proof_sessions),
    execution_count: executions.length(),
    verified_execution_count: verified_execution_count(executions),
    proof_session_count: proof_sessions.length(),
    capability_count: book.profile.capabilities.length(),
    review_count: total_review_count(receipts, reviews),
    command_path: sidecar.command_path,
    town_route: town_route(book.profile),
  }
}

///|
pub fn resident_json(agent : ResidentRobotAgent, indent? : Int = 2) -> String {
  agent.to_json().stringify(indent~)
}
