///|
pub(all) struct RoboBookRequiredPaths {
  profile : String
  safety_policy : String
  bridge_config : String
  receipts_dir : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboBookStatus {
  root : String
  required : RoboBookRequiredPaths
  missing_paths : Array[String]
  profile_report : ValidationReport
  ready : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_robobook_required_paths() -> RoboBookRequiredPaths {
  {
    profile: "robot.json",
    safety_policy: "safety/policy.json",
    bridge_config: "bridge/bridge.json",
    receipts_dir: "runs/receipts",
  }
}

///|
fn observed_has(observed_paths : Array[String], path : String) -> Bool {
  observed_paths.contains(path)
}

///|
pub fn inspect_robobook(
  root : String,
  profile : RobotProfile,
  observed_paths : Array[String],
) -> RoboBookStatus {
  let required = default_robobook_required_paths()
  let missing : Array[String] = []
  if !observed_has(observed_paths, required.profile) {
    missing.push(required.profile)
  }
  if !observed_has(observed_paths, required.safety_policy) {
    missing.push(required.safety_policy)
  }
  if !observed_has(observed_paths, required.bridge_config) {
    missing.push(required.bridge_config)
  }
  if !observed_has(observed_paths, required.receipts_dir) {
    missing.push(required.receipts_dir)
  }
  let profile_report = validate_robot_profile(profile)
  {
    root,
    required,
    missing_paths: missing,
    profile_report,
    ready: missing.is_empty() && profile_report.valid,
  }
}
