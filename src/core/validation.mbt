///|
pub(all) struct ValidationIssue {
  path : String
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ValidationReport {
  valid : Bool
  issues : Array[ValidationIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(path : String, code : String, message : String) -> ValidationIssue {
  { path, code, message }
}

///|
fn is_blank(value : String) -> Bool {
  value.trim().to_owned().is_empty()
}

///|
fn require_non_blank(
  issues : Array[ValidationIssue],
  path : String,
  value : String,
) -> Unit {
  if is_blank(value) {
    issues.push(issue(path, "required", "\{path} must not be blank"))
  }
}

///|
fn has_capability(capabilities : Array[CapabilitySpec], id : String) -> Bool {
  capabilities.any(fn(capability) { capability.id == id })
}

///|
fn validate_capability_ids(
  issues : Array[ValidationIssue],
  capabilities : Array[CapabilitySpec],
) -> Unit {
  let seen : Map[String, Bool] = {}
  for capability in capabilities {
    require_non_blank(issues, "capabilities[].id", capability.id)
    match seen.get(capability.id) {
      Some(_) =>
        issues.push(
          issue(
            "capabilities",
            "duplicate-capability",
            "duplicate capability `\{capability.id}`",
          ),
        )
      None => seen[capability.id] = true
    }
  }
}

///|
fn validate_joint_indices(
  issues : Array[ValidationIssue],
  joints : Array[JointSpec],
) -> Unit {
  let seen : Map[Int, Bool] = {}
  for joint in joints {
    require_non_blank(issues, "joints[].name", joint.name)
    if joint.index < 0 {
      issues.push(
        issue("joints[].index", "invalid-index", "joint index must be >= 0"),
      )
    }
    match seen.get(joint.index) {
      Some(_) =>
        issues.push(
          issue(
            "joints",
            "duplicate-joint-index",
            "duplicate joint index `\{joint.index}`",
          ),
        )
      None => seen[joint.index] = true
    }
  }
}

///|
pub fn validate_robot_profile(profile : RobotProfile) -> ValidationReport {
  let issues : Array[ValidationIssue] = []
  require_non_blank(issues, "id", profile.id)
  require_non_blank(issues, "label", profile.label)
  require_non_blank(issues, "platform", profile.platform)
  require_non_blank(issues, "model.primary", profile.model.primary)
  require_non_blank(issues, "bridge.id", profile.bridge.id)
  require_non_blank(issues, "bridge.config_path", profile.bridge.config_path)
  if profile.profile_version < 1 {
    issues.push(
      issue("profile_version", "invalid-version", "version must be >= 1"),
    )
  }
  if profile.limits.telemetry_freshness_ms <= 0 {
    issues.push(
      issue(
        "limits.telemetry_freshness_ms", "invalid-limit", "telemetry freshness must be positive",
      ),
    )
  }
  if profile.limits.heartbeat_ms <= 0 {
    issues.push(
      issue(
        "limits.heartbeat_ms", "invalid-limit", "heartbeat must be positive",
      ),
    )
  }
  if profile.capabilities.is_empty() {
    issues.push(
      issue(
        "capabilities", "missing-capability", "robot profile must expose at least one capability",
      ),
    )
  }
  validate_capability_ids(issues, profile.capabilities)
  validate_joint_indices(issues, profile.joints)
  { valid: issues.is_empty(), issues }
}

///|
pub fn profile_supports(profile : RobotProfile, capability_id : String) -> Bool {
  has_capability(profile.capabilities, capability_id)
}
