///|
pub(all) enum SafetyDecision {
  Allow
  Deny
  ApprovalRequired
  DryRunRequired
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SafetyReason {
  Safe
  RobotMismatch
  BridgeUnavailable
  UnsupportedCapability
  DisabledCapability
  StaleTelemetry
  ApprovalMissing
  DryRunMissing
  DeveloperGateRequired
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SafetyVerdict {
  intent_id : IntentId
  robot_id : RobotId
  capability : CapabilityId
  decision : SafetyDecision
  reason : SafetyReason
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SafetyContext {
  profile : RobotProfile
  bridge_health : BridgeHealth
  approval_id : String?
  dry_run_receipt_id : ReceiptId?
  developer_gate : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn verdict(
  intent : CommandIntent,
  decision : SafetyDecision,
  reason : SafetyReason,
  detail : String,
) -> SafetyVerdict {
  {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision,
    reason,
    detail,
  }
}

///|
fn find_capability(
  profile : RobotProfile,
  capability_id : CapabilityId,
) -> CapabilitySpec? {
  profile.capabilities
  .search_by(fn(capability) { capability.id == capability_id })
  .map(fn(index) { profile.capabilities[index] })
}

///|
fn telemetry_is_stale(profile : RobotProfile, health : BridgeHealth) -> Bool {
  match health.last_telemetry_age_ms {
    None => true
    Some(age) => age > profile.limits.telemetry_freshness_ms
  }
}

///|
pub fn evaluate_intent(
  context : SafetyContext,
  intent : CommandIntent,
) -> SafetyVerdict {
  if intent.robot_id != context.profile.id {
    return verdict(
      intent,
      Deny,
      RobotMismatch,
      "intent robot does not match selected profile",
    )
  }
  if context.bridge_health.status != "ok" {
    return verdict(
      intent,
      Deny,
      BridgeUnavailable,
      "bridge is not healthy: \{context.bridge_health.status}",
    )
  }
  let capability = match find_capability(context.profile, intent.capability) {
    Some(capability) => capability
    None =>
      return verdict(
        intent,
        Deny,
        UnsupportedCapability,
        "profile does not expose capability `\{intent.capability}`",
      )
  }
  if !capability.enabled {
    return verdict(
      intent,
      Deny,
      DisabledCapability,
      "capability `\{capability.id}` is disabled by profile policy",
    )
  }
  if capability.command_class != Observe &&
    telemetry_is_stale(context.profile, context.bridge_health) {
    return verdict(
      intent,
      Deny,
      StaleTelemetry,
      "telemetry is stale or missing",
    )
  }
  if capability.command_class == LowControl && !context.developer_gate {
    return verdict(
      intent,
      Deny,
      DeveloperGateRequired,
      "low-control capabilities require an explicit developer gate",
    )
  }
  if capability.requires_dry_run && context.dry_run_receipt_id is None {
    return verdict(
      intent,
      DryRunRequired,
      DryRunMissing,
      "capability `\{capability.id}` requires a dry-run receipt",
    )
  }
  if capability.requires_approval && context.approval_id is None {
    return verdict(
      intent,
      ApprovalRequired,
      ApprovalMissing,
      "capability `\{capability.id}` requires operator approval",
    )
  }
  verdict(intent, Allow, Safe, "intent is allowed")
}
