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
fn receipts_dir(root : String) -> String {
  robotbook_path(root, "runs/receipts")
}

///|
pub fn receipt_json(receipt : @core.RunReceipt, indent? : Int = 2) -> String {
  receipt.to_json().stringify(indent~)
}

///|
pub fn write_run_receipt(
  root : String,
  receipt : @core.RunReceipt,
) -> Result[String, RuntimeIssue] {
  let path = receipt_path(root, receipt.receipt_id)
  let text = receipt_json(receipt)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue("write-receipt", path, "failed to write RobotBook run receipt"),
      )
  }
  Ok(path)
}

///|
pub fn list_receipt_paths(root : String) -> Result[Array[String], RuntimeIssue] {
  let dir = receipts_dir(root)
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-receipts", dir, "failed to read RobotBook receipt directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robotbook_path(root, "runs/receipts/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_run_receipt_file(
  path : String,
) -> Result[@core.RunReceipt, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-receipt", path, "failed to read RobotBook receipt"),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-receipt", path, "failed to parse RobotBook receipt JSON"),
      )
  }
  let receipt : @core.RunReceipt = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-receipt", path, "failed to decode RobotBook receipt contract",
        ),
      )
  }
  Ok(receipt)
}

///|
pub fn read_run_receipt(
  root : String,
  receipt_id : @core.ReceiptId,
) -> Result[@core.RunReceipt, RuntimeIssue] {
  read_run_receipt_file(receipt_path(root, receipt_id))
}

///|
pub fn list_run_receipts(
  root : String,
) -> Result[Array[@core.RunReceipt], RuntimeIssue] {
  let paths = match list_receipt_paths(root) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let receipts : Array[@core.RunReceipt] = []
  for path in paths {
    match read_run_receipt_file(path) {
      Ok(receipt) => receipts.push(receipt)
      Err(error) => return Err(error)
    }
  }
  Ok(receipts)
}
