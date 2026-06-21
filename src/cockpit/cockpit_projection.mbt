///|
pub(all) struct CockpitRobotSummary {
  root : String
  robot_id : @core.RobotId
  label : String
  platform : String
  model_primary : String
  ready : Bool
  missing_paths : Int
  validation_issues : Int
  joints : Int
  sensors : Int
  capabilities : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitBridgeSummary {
  bridge_id : @core.BridgeId
  status : String
  mode : String
  telemetry_age_ms : Int?
  telemetry_stale : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSidecarSummary {
  sidecar_id : String
  state : String
  command_path : String
  command_available : Bool
  health_path : String
  execute_path : String
  ready_for_execution : Bool
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitTelemetrySummary {
  frame_id : String
  captured_at_ms : Int64
  mode : String
  joints : Int
  imu_available : Bool
  operator_input_fields : Int
  errors : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSafetySummary {
  intent_id : @core.IntentId
  capability : @core.CapabilityId
  decision : String
  reason : String
  next_action : String
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitReceiptSummary {
  receipt_id : @core.ReceiptId
  status : String
  capability : @core.CapabilityId
  started_at_ms : Int64
  bridge_error : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CockpitSnapshot {
  robot : CockpitRobotSummary
  bridge : CockpitBridgeSummary
  sidecar : CockpitSidecarSummary
  telemetry : CockpitTelemetrySummary
  safety : CockpitSafetySummary
  receipt_count : Int
  latest_receipt : CockpitReceiptSummary?
  read_only : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn next_action_text(action : @pipeline.PipelineNextAction) -> String {
  match action {
    Execute => "execute"
    CollectDryRun => "collect-dry-run"
    RequestApproval => "request-approval"
    Stop => "stop"
  }
}

///|
pub fn run_status_text(status : @core.RunStatus) -> String {
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
pub fn safety_decision_text(decision : @core.SafetyDecision) -> String {
  match decision {
    Allow => "allow"
    Deny => "deny"
    ApprovalRequired => "approval-required"
    DryRunRequired => "dry-run-required"
  }
}

///|
pub fn safety_reason_text(reason : @core.SafetyReason) -> String {
  match reason {
    Safe => "safe"
    RobotMismatch => "robot-mismatch"
    BridgeUnavailable => "bridge-unavailable"
    UnsupportedCapability => "unsupported-capability"
    DisabledCapability => "disabled-capability"
    StaleTelemetry => "stale-telemetry"
    ApprovalMissing => "approval-missing"
    DryRunMissing => "dry-run-missing"
    DeveloperGateRequired => "developer-gate-required"
  }
}

///|
pub fn robot_summary(book : @runtime.LoadedRobotBook) -> CockpitRobotSummary {
  {
    root: book.root,
    robot_id: book.profile.id,
    label: book.profile.label,
    platform: book.profile.platform,
    model_primary: book.profile.model.primary,
    ready: book.status.ready,
    missing_paths: book.status.missing_paths.length(),
    validation_issues: book.status.profile_report.issues.length(),
    joints: book.profile.joints.length(),
    sensors: book.profile.sensors.length(),
    capabilities: book.profile.capabilities.length(),
  }
}

///|
pub fn bridge_summary(
  profile : @core.RobotProfile,
  health : @core.BridgeHealth,
) -> CockpitBridgeSummary {
  let stale = match health.last_telemetry_age_ms {
    None => true
    Some(age) => age > profile.limits.telemetry_freshness_ms
  }
  {
    bridge_id: health.bridge_id,
    status: health.status,
    mode: health.mode,
    telemetry_age_ms: health.last_telemetry_age_ms,
    telemetry_stale: stale,
  }
}

///|
pub fn sidecar_state_text(state : @bridge_sidecar.SidecarState) -> String {
  match state {
    MissingCommand => "missing-command"
    Launchable => "launchable"
  }
}

///|
pub fn sidecar_summary(
  status : @bridge_sidecar.BridgeSidecarStatus,
) -> CockpitSidecarSummary {
  {
    sidecar_id: status.sidecar_id,
    state: sidecar_state_text(status.state),
    command_path: status.command_path,
    command_available: status.command_available,
    health_path: status.health_path,
    execute_path: status.execute_path,
    ready_for_execution: status.ready_for_execution,
    detail: status.detail,
  }
}

///|
pub fn telemetry_summary(
  telemetry : @core.TelemetryFrame,
) -> CockpitTelemetrySummary {
  {
    frame_id: telemetry.frame_id,
    captured_at_ms: telemetry.captured_at_ms,
    mode: telemetry.mode,
    joints: telemetry.joints.length(),
    imu_available: telemetry.imu is Some(_),
    operator_input_fields: telemetry.operator_input.length(),
    errors: telemetry.errors.length(),
  }
}

///|
pub fn safety_summary(
  result : @pipeline.PipelineResult,
) -> CockpitSafetySummary {
  {
    intent_id: result.intent.intent_id,
    capability: result.intent.capability,
    decision: safety_decision_text(result.verdict.decision),
    reason: safety_reason_text(result.verdict.reason),
    next_action: next_action_text(result.next_action),
    detail: result.verdict.detail,
  }
}

///|
pub fn receipt_summary(receipt : @core.RunReceipt) -> CockpitReceiptSummary {
  {
    receipt_id: receipt.receipt_id,
    status: run_status_text(receipt.status),
    capability: receipt.intent.capability,
    started_at_ms: receipt.started_at_ms,
    bridge_error: receipt.bridge_error,
  }
}

///|
pub fn latest_receipt(
  receipts : Array[@core.RunReceipt],
) -> CockpitReceiptSummary? {
  if receipts.is_empty() {
    None
  } else {
    Some(receipt_summary(receipts[receipts.length() - 1]))
  }
}

///|
pub fn snapshot(
  book : @runtime.LoadedRobotBook,
  health : @core.BridgeHealth,
  sidecar : @bridge_sidecar.BridgeSidecarStatus,
  telemetry : @core.TelemetryFrame,
  safety : @pipeline.PipelineResult,
  receipts : Array[@core.RunReceipt],
) -> CockpitSnapshot {
  {
    robot: robot_summary(book),
    bridge: bridge_summary(book.profile, health),
    sidecar: sidecar_summary(sidecar),
    telemetry: telemetry_summary(telemetry),
    safety: safety_summary(safety),
    receipt_count: receipts.length(),
    latest_receipt: latest_receipt(receipts),
    read_only: safety.next_action != Execute,
  }
}

///|
pub fn snapshot_json(snapshot : CockpitSnapshot, indent? : Int = 2) -> String {
  snapshot.to_json().stringify(indent~)
}
