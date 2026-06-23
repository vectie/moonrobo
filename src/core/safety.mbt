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
  InvalidParameter
  MotionLimitExceeded
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
fn high_control_motion_capability(capability_id : CapabilityId) -> Bool {
  capability_id == "control.high.walk" || capability_id == "control.high.run"
}

///|
fn parse_double_parameter(
  intent : CommandIntent,
  key : String,
  fallback : String,
) -> Result[Double, SafetyVerdict] {
  let text = intent.parameters.get(key).unwrap_or(fallback)
  let value = @string.parse_double(text) catch {
    _ =>
      return Err(
        verdict(
          intent,
          Deny,
          InvalidParameter,
          "parameter `\{key}` must be a number",
        ),
      )
  }
  Ok(value)
}

///|
fn parse_int_parameter(
  intent : CommandIntent,
  key : String,
  fallback : String,
) -> Result[Int, SafetyVerdict] {
  let text = intent.parameters.get(key).unwrap_or(fallback)
  let value = @string.parse_int(text) catch {
    _ =>
      return Err(
        verdict(
          intent,
          Deny,
          InvalidParameter,
          "parameter `\{key}` must be an integer",
        ),
      )
  }
  Ok(value)
}

///|
fn abs_exceeds(value : Double, max_abs : Double) -> Bool {
  value < 0.0 - max_abs || value > max_abs
}

///|
fn validate_high_control_motion_limits(
  profile : RobotProfile,
  intent : CommandIntent,
) -> SafetyVerdict? {
  if !high_control_motion_capability(intent.capability) {
    return None
  }
  let x = match parse_double_parameter(intent, "x", "0.0") {
    Ok(value) => value
    Err(verdict) => return Some(verdict)
  }
  let yaw = match parse_double_parameter(intent, "yaw", "0.0") {
    Ok(value) => value
    Err(verdict) => return Some(verdict)
  }
  let duration_ms = match parse_int_parameter(intent, "duration_ms", "1000") {
    Ok(value) => value
    Err(verdict) => return Some(verdict)
  }
  if abs_exceeds(x, profile.limits.high_control_max_x_abs) {
    return Some(
      verdict(
        intent,
        Deny,
        MotionLimitExceeded,
        "high-control x `\{x}` exceeds profile limit ±\{profile.limits.high_control_max_x_abs}",
      ),
    )
  }
  if abs_exceeds(yaw, profile.limits.high_control_max_yaw_abs) {
    return Some(
      verdict(
        intent,
        Deny,
        MotionLimitExceeded,
        "high-control yaw `\{yaw}` exceeds profile limit ±\{profile.limits.high_control_max_yaw_abs}",
      ),
    )
  }
  if duration_ms <= 0 ||
    duration_ms > profile.limits.high_control_max_duration_ms {
    return Some(
      verdict(
        intent,
        Deny,
        MotionLimitExceeded,
        "high-control duration_ms `\{duration_ms}` exceeds profile limit 1..\{profile.limits.high_control_max_duration_ms}",
      ),
    )
  }
  None
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
  match validate_high_control_motion_limits(context.profile, intent) {
    Some(verdict) => return verdict
    None => ()
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
