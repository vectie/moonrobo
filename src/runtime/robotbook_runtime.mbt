///|
pub(all) struct RuntimeIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LoadedRobotBook {
  root : String
  profile : @core.RobotProfile
  status : @core.RobotBookStatus
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> RuntimeIssue {
  { code, path, message }
}

///|
pub fn robotbook_path(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn observed_required_paths(root : String) -> Array[String] {
  let required = @core.default_robotbook_required_paths()
  let observed : Array[String] = []
  let paths = [
    required.profile,
    required.safety_policy,
    required.bridge_config,
    required.receipts_dir,
  ]
  for path in paths {
    if @fsx.path_exists(robotbook_path(root, path)) {
      observed.push(path)
    }
  }
  observed
}

///|
pub fn load_robot_profile(
  root : String,
) -> Result[@core.RobotProfile, RuntimeIssue] {
  let profile_path = robotbook_path(root, "robot.json")
  let text = @fsx.read_file_to_string(profile_path) catch {
    _ =>
      return Err(
        issue("read-profile", profile_path, "failed to read RobotBook profile"),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-profile", profile_path, "failed to parse RobotBook profile JSON",
        ),
      )
  }
  let profile : @core.RobotProfile = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-profile", profile_path, "failed to decode RobotBook profile contract",
        ),
      )
  }
  Ok(profile)
}

///|
pub fn load_robotbook(root : String) -> Result[LoadedRobotBook, RuntimeIssue] {
  let profile = match load_robot_profile(root) {
    Ok(profile) => profile
    Err(error) => return Err(error)
  }
  let status = @core.inspect_robotbook(
    root,
    profile,
    observed_required_paths(root),
  )
  Ok({ root, profile, status })
}

///|
pub fn receipt_path(root : String, receipt_id : @core.ReceiptId) -> String {
  robotbook_path(root, "runs/receipts/\{receipt_id}.json")
}

///|
pub fn write_run_receipt(
  root : String,
  receipt : @core.RunReceipt,
) -> Result[String, RuntimeIssue] {
  let path = receipt_path(root, receipt.receipt_id)
  let text = receipt.to_json().stringify(indent=2)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue("write-receipt", path, "failed to write RobotBook run receipt"),
      )
  }
  Ok(path)
}
