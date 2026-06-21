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
fn dry_runs_dir(root : String) -> String {
  robotbook_path(root, "runs/dry-runs")
}

///|
fn approvals_dir(root : String) -> String {
  robotbook_path(root, "runs/approvals")
}

///|
fn observations_dir(root : String) -> String {
  robotbook_path(root, "runs/observations")
}

///|
fn ensure_dir(root : String, relative : String) -> Result[Unit, RuntimeIssue] {
  let path = robotbook_path(root, relative)
  if @fsx.path_exists(path) {
    Ok(())
  } else {
    @fsx.create_dir(path) catch {
      _ =>
        return Err(
          issue("create-dir", path, "failed to create RobotBook directory"),
        )
    }
    Ok(())
  }
}

///|
pub fn ensure_process_dirs(root : String) -> Result[Unit, RuntimeIssue] {
  match ensure_dir(root, "runs") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/receipts") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/dry-runs") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/approvals") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  ensure_dir(root, "runs/observations")
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
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
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
pub fn dry_run_evidence_path(
  root : String,
  dry_run_receipt_id : @core.ReceiptId,
) -> String {
  dry_runs_dir(root) + "/\{dry_run_receipt_id}.json"
}

///|
pub fn approval_record_path(root : String, approval_id : String) -> String {
  approvals_dir(root) + "/\{approval_id}.json"
}

///|
pub fn observation_session_path(root : String, session_id : String) -> String {
  observations_dir(root) + "/\{session_id}.json"
}

///|
pub fn dry_run_evidence_json(
  evidence : @core.DryRunEvidence,
  indent? : Int = 2,
) -> String {
  evidence.to_json().stringify(indent~)
}

///|
pub fn approval_record_json(
  approval : @core.ApprovalRecord,
  indent? : Int = 2,
) -> String {
  approval.to_json().stringify(indent~)
}

///|
pub fn observation_session_json(
  session : @core.ObservationSession,
  indent? : Int = 2,
) -> String {
  session.to_json().stringify(indent~)
}

///|
pub fn write_dry_run_evidence(
  root : String,
  evidence : @core.DryRunEvidence,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = dry_run_evidence_path(root, evidence.dry_run_receipt_id)
  @fsx.write_string_to_file(path, dry_run_evidence_json(evidence)) catch {
    _ =>
      return Err(
        issue(
          "write-dry-run", path, "failed to write RobotBook dry-run evidence",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_approval_record(
  root : String,
  approval : @core.ApprovalRecord,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = approval_record_path(root, approval.approval_id)
  @fsx.write_string_to_file(path, approval_record_json(approval)) catch {
    _ =>
      return Err(
        issue(
          "write-approval", path, "failed to write RobotBook approval record",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_observation_session(
  root : String,
  session : @core.ObservationSession,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = observation_session_path(root, session.session_id)
  @fsx.write_string_to_file(path, observation_session_json(session)) catch {
    _ =>
      return Err(
        issue(
          "write-observation", path, "failed to write RobotBook observation session",
        ),
      )
  }
  Ok(path)
}

///|
pub fn read_dry_run_evidence(
  root : String,
  dry_run_receipt_id : @core.ReceiptId,
) -> Result[@core.DryRunEvidence, RuntimeIssue] {
  let path = dry_run_evidence_path(root, dry_run_receipt_id)
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(issue("read-dry-run", path, "failed to read dry-run evidence"))
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(issue("parse-dry-run", path, "failed to parse dry-run JSON"))
  }
  let evidence : @core.DryRunEvidence = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-dry-run", path, "failed to decode dry-run evidence"),
      )
  }
  Ok(evidence)
}

///|
pub fn read_approval_record(
  root : String,
  approval_id : String,
) -> Result[@core.ApprovalRecord, RuntimeIssue] {
  let path = approval_record_path(root, approval_id)
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(issue("read-approval", path, "failed to read approval record"))
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(issue("parse-approval", path, "failed to parse approval JSON"))
  }
  let approval : @core.ApprovalRecord = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-approval", path, "failed to decode approval record"),
      )
  }
  Ok(approval)
}

///|
pub fn read_observation_session(
  root : String,
  session_id : String,
) -> Result[@core.ObservationSession, RuntimeIssue] {
  let path = observation_session_path(root, session_id)
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-observation", path, "failed to read RobotBook observation session",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-observation", path, "failed to parse observation JSON"),
      )
  }
  let session : @core.ObservationSession = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-observation", path, "failed to decode observation session",
        ),
      )
  }
  Ok(session)
}

///|
pub fn list_observation_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = observations_dir(root)
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-observations", dir, "failed to read RobotBook observation directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robotbook_path(root, "runs/observations/\{name}"))
    }
  }
  Ok(paths)
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
