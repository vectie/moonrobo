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
fn safety_state(receipts : Array[@core.RunReceipt]) -> String {
  if review_count(receipts) > 0 {
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
  book : @runtime.LoadedRobotBook,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  receipts : Array[@core.RunReceipt],
  sessions : Array[@core.ObservationSession],
) -> ResidentRobotAgent {
  let active = active_observation(sessions)
  {
    resident_id: resident_id(book.profile),
    robot_id: book.profile.id,
    label: book.profile.label,
    platform: book.profile.platform,
    role: "physical-robot",
    availability: availability(sidecar, active),
    safety_state: safety_state(receipts),
    bridge_state: sidecar_state_text(sidecar.state),
    active_observation: active,
    latest_observation: latest_observation(sessions),
    latest_receipt: latest_receipt(receipts),
    capability_count: book.profile.capabilities.length(),
    review_count: review_count(receipts),
    command_path: sidecar.command_path,
    town_route: town_route(book.profile),
  }
}

///|
pub fn resident_json(agent : ResidentRobotAgent, indent? : Int = 2) -> String {
  agent.to_json().stringify(indent~)
}
