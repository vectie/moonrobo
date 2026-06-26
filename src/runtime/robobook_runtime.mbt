///|
pub(all) struct RuntimeIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LoadedRoboBook {
  root : String
  profile : @core.RobotProfile
  status : @core.RoboBookStatus
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> RuntimeIssue {
  { code, path, message }
}

///|
pub fn robobook_path(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn observed_required_paths(
  root : String,
  profile : @core.RobotProfile,
) -> Array[String] {
  let required = @core.default_robobook_required_paths()
  let observed : Array[String] = []
  let paths = [
    required.profile,
    profile.model.primary,
    required.safety_policy,
    required.bridge_config,
    required.receipts_dir,
  ]
  for path in paths {
    if @fsx.path_exists(robobook_path(root, path)) {
      observed.push(path)
    }
  }
  observed
}

///|
pub fn load_robot_profile(
  root : String,
) -> Result[@core.RobotProfile, RuntimeIssue] {
  let profile_path = robobook_path(root, "robot.json")
  let text = @fsx.read_file_to_string(profile_path) catch {
    _ =>
      return Err(
        issue("read-profile", profile_path, "failed to read RoboBook profile"),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-profile", profile_path, "failed to parse RoboBook profile JSON",
        ),
      )
  }
  let profile : @core.RobotProfile = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-profile", profile_path, "failed to decode RoboBook profile contract",
        ),
      )
  }
  Ok(profile)
}

///|
pub fn load_robobook(root : String) -> Result[LoadedRoboBook, RuntimeIssue] {
  let profile = match load_robot_profile(root) {
    Ok(profile) => profile
    Err(error) => return Err(error)
  }
  let status = @core.inspect_robobook(
    root,
    profile,
    observed_required_paths(root, profile),
  )
  Ok({ root, profile, status })
}

///|
pub fn read_urdf_model(book : LoadedRoboBook) -> @urdf.UrdfModel? {
  if !book.profile.model.primary.has_suffix(".urdf") {
    return None
  }
  let path = robobook_path(book.root, book.profile.model.primary)
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  Some(@urdf.parse(text))
}

///|
pub fn receipt_path(root : String, receipt_id : @core.ReceiptId) -> String {
  robobook_path(root, "runs/receipts/\{receipt_id}.json")
}

///|
fn receipts_dir(root : String) -> String {
  robobook_path(root, "runs/receipts")
}

///|
fn dry_runs_dir(root : String) -> String {
  robobook_path(root, "runs/dry-runs")
}

///|
fn approvals_dir(root : String) -> String {
  robobook_path(root, "runs/approvals")
}

///|
fn bridge_dispatches_dir(root : String) -> String {
  robobook_path(root, "runs/bridge-dispatches")
}

///|
fn bridge_contracts_dir(root : String) -> String {
  robobook_path(root, "runs/bridge-contracts")
}

///|
fn task_executions_dir(root : String) -> String {
  robobook_path(root, "runs/task-executions")
}

///|
fn runtime_validation_dir(root : String) -> String {
  robobook_path(root, "runs/runtime-validation")
}

///|
fn runtime_validation_sessions_dir(root : String) -> String {
  runtime_validation_dir(root) + "/sessions"
}

///|
fn runtime_calibration_dir(root : String) -> String {
  robobook_path(root, "runs/runtime-calibration")
}

///|
fn runtime_calibration_resolutions_dir(root : String) -> String {
  runtime_calibration_dir(root) + "/resolutions"
}

///|
fn annotations_dir(root : String) -> String {
  robobook_path(root, "runs/annotations")
}

///|
fn observations_dir(root : String) -> String {
  robobook_path(root, "runs/observations")
}

///|
fn reviews_dir(root : String) -> String {
  robobook_path(root, "runs/reviews")
}

///|
fn policy_evals_dir(root : String) -> String {
  robobook_path(root, "runs/policy-evals")
}

///|
fn runtime_health_dir(root : String) -> String {
  robobook_path(root, "runs/runtime-health")
}

///|
fn telemetry_dir(root : String) -> String {
  robobook_path(root, "runs/telemetry")
}

///|
fn robo_turns_dir(root : String) -> String {
  robobook_path(root, "runs/robo-turns")
}

///|
fn robo_loops_dir(root : String) -> String {
  robobook_path(root, "runs/robo-loops")
}

///|
fn moonbook_memory_dir(root : String) -> String {
  robobook_path(root, "moonbook/memory")
}

///|
fn moonbook_task_messages_dir(root : String) -> String {
  robobook_path(root, "moonbook/task-messages")
}

///|
fn agents_dir(root : String) -> String {
  robobook_path(root, "agents")
}

///|
pub fn telemetry_session_dir(root : String, session_id : String) -> String {
  telemetry_dir(root) + "/\{session_id}"
}

///|
fn ensure_dir(root : String, relative : String) -> Result[Unit, RuntimeIssue] {
  let path = robobook_path(root, relative)
  if @fsx.path_exists(path) {
    Ok(())
  } else {
    @fsx.create_dir(path) catch {
      _ =>
        return Err(
          issue("create-dir", path, "failed to create RoboBook directory"),
        )
    }
    Ok(())
  }
}

///|
pub fn ensure_robobook_root(root : String) -> Result[Unit, RuntimeIssue] {
  if @fsx.path_exists(root) {
    Ok(())
  } else {
    @fsx.create_dir(root) catch {
      _ =>
        return Err(issue("create-root", root, "failed to create RoboBook root"))
    }
    Ok(())
  }
}

///|
pub fn ensure_process_dirs(root : String) -> Result[Unit, RuntimeIssue] {
  match ensure_robobook_root(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
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
  match ensure_dir(root, "runs/bridge-dispatches") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/bridge-contracts") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/task-executions") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/robo-turns") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/robo-loops") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/runtime-validation") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/runtime-validation/sessions") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/runtime-calibration") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/runtime-calibration/resolutions") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/annotations") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/observations") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/reviews") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/policy-evals") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/runtime-health") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/telemetry") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "moonbook") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "moonbook/task-messages") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "agents") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  ensure_dir(root, "moonbook/memory")
}

///|
pub fn write_robot_profile(
  root : String,
  profile : @core.RobotProfile,
) -> Result[String, RuntimeIssue] {
  match ensure_robobook_root(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = robobook_path(root, "robot.json")
  @fsx.write_string_to_file(path, profile.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        issue("write-profile", path, "failed to write RoboBook profile"),
      )
  }
  Ok(path)
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
        issue("write-receipt", path, "failed to write RoboBook run receipt"),
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
pub fn bridge_dispatch_evidence_path(
  root : String,
  dispatch_id : String,
) -> String {
  bridge_dispatches_dir(root) + "/\{dispatch_id}.json"
}

///|
pub fn bridge_contract_path(root : String, contract_id : String) -> String {
  bridge_contracts_dir(root) + "/\{contract_id}.json"
}

///|
pub fn latest_bridge_contract_path(root : String) -> String {
  bridge_contracts_dir(root) + "/latest.json"
}

///|
pub fn task_execution_snapshot_path(
  root : String,
  snapshot_id : String,
) -> String {
  task_executions_dir(root) + "/\{snapshot_id}.json"
}

///|
pub fn runtime_validation_report_path(
  root : String,
  report_id : String,
) -> String {
  runtime_validation_dir(root) + "/\{report_id}.json"
}

///|
pub fn latest_runtime_validation_path(root : String) -> String {
  runtime_validation_dir(root) + "/latest.json"
}

///|
pub fn runtime_validation_session_path(
  root : String,
  session_id : String,
) -> String {
  runtime_validation_sessions_dir(root) + "/\{session_id}.json"
}

///|
pub fn latest_runtime_validation_session_path(root : String) -> String {
  runtime_validation_dir(root) + "/latest-session.json"
}

///|
pub fn runtime_calibration_plan_path(root : String, plan_id : String) -> String {
  runtime_calibration_dir(root) + "/\{plan_id}.json"
}

///|
pub fn latest_runtime_calibration_plan_path(root : String) -> String {
  runtime_calibration_dir(root) + "/latest.json"
}

///|
pub fn runtime_calibration_resolution_path(
  root : String,
  resolution_id : String,
) -> String {
  runtime_calibration_resolutions_dir(root) + "/\{resolution_id}.json"
}

///|
pub fn latest_runtime_calibration_resolution_path(root : String) -> String {
  runtime_calibration_resolutions_dir(root) + "/latest.json"
}

///|
pub fn annotation_session_dir(root : String, session_id : String) -> String {
  annotations_dir(root) + "/\{session_id}"
}

///|
pub fn replay_annotation_path(
  root : String,
  session_id : String,
  annotation_id : String,
) -> String {
  annotation_session_dir(root, session_id) + "/\{annotation_id}.json"
}

///|
pub fn observation_session_path(root : String, session_id : String) -> String {
  observations_dir(root) + "/\{session_id}.json"
}

///|
pub fn process_review_path(root : String, review_id : String) -> String {
  reviews_dir(root) + "/\{review_id}.json"
}

///|
pub fn policy_evaluation_path(root : String, evaluation_id : String) -> String {
  policy_evals_dir(root) + "/\{evaluation_id}.json"
}

///|
pub fn runtime_health_path(root : String, health_id : String) -> String {
  runtime_health_dir(root) + "/\{health_id}.json"
}

///|
pub fn latest_runtime_health_path(root : String) -> String {
  runtime_health_dir(root) + "/latest.json"
}

///|
pub fn telemetry_frame_path(
  root : String,
  session_id : String,
  frame_id : String,
) -> String {
  telemetry_session_dir(root, session_id) + "/\{frame_id}.json"
}

///|
pub fn moonbook_memory_path(root : String, pack_id : String) -> String {
  moonbook_memory_dir(root) + "/\{pack_id}.json"
}

///|
pub fn moonbook_task_message_path(root : String, task_id : String) -> String {
  moonbook_task_messages_dir(root) + "/\{task_id}.json"
}

///|
pub fn tool_registry_path(root : String) -> String {
  agents_dir(root) + "/tool-registry.json"
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
pub fn bridge_dispatch_evidence_json(
  dispatch : @core.BridgeDispatchEvidence,
  indent? : Int = 2,
) -> String {
  dispatch.to_json().stringify(indent~)
}

///|
pub fn task_execution_snapshot_json(
  snapshot : @core.TaskExecutionSnapshot,
  indent? : Int = 2,
) -> String {
  snapshot.to_json().stringify(indent~)
}

///|
pub fn replay_annotation_json(
  annotation : @annotation.ReplayAnnotation,
  indent? : Int = 2,
) -> String {
  annotation.to_json().stringify(indent~)
}

///|
pub fn observation_session_json(
  session : @core.ObservationSession,
  indent? : Int = 2,
) -> String {
  session.to_json().stringify(indent~)
}

///|
pub fn telemetry_frame_json(
  frame : @core.TelemetryFrame,
  indent? : Int = 2,
) -> String {
  frame.to_json().stringify(indent~)
}

///|
pub fn process_review_json(
  review : @review.ProcessReview,
  indent? : Int = 2,
) -> String {
  review.to_json().stringify(indent~)
}

///|
pub fn runtime_health_json(
  record : @runtime_health.RuntimeHealthRecord,
  indent? : Int = 2,
) -> String {
  @runtime_health.record_json(record, indent~)
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
          "write-dry-run", path, "failed to write RoboBook dry-run evidence",
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
          "write-approval", path, "failed to write RoboBook approval record",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_bridge_dispatch_evidence(
  root : String,
  dispatch : @core.BridgeDispatchEvidence,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = bridge_dispatch_evidence_path(root, dispatch.dispatch_id)
  @fsx.write_string_to_file(path, bridge_dispatch_evidence_json(dispatch)) catch {
    _ =>
      return Err(
        issue(
          "write-bridge-dispatch", path, "failed to write bridge dispatch evidence",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_bridge_contract(
  root : String,
  contract_id : String,
  contract_json : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = bridge_contract_path(root, contract_id)
  @fsx.write_string_to_file(path, contract_json) catch {
    _ =>
      return Err(
        issue(
          "write-bridge-contract", path, "failed to write bridge contract evidence",
        ),
      )
  }
  let latest_path = latest_bridge_contract_path(root)
  @fsx.write_string_to_file(latest_path, contract_json) catch {
    _ =>
      return Err(
        issue(
          "write-bridge-contract-latest", latest_path, "failed to write latest bridge contract evidence",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_task_execution_snapshot(
  root : String,
  snapshot : @core.TaskExecutionSnapshot,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = task_execution_snapshot_path(root, snapshot.snapshot_id)
  @fsx.write_string_to_file(path, task_execution_snapshot_json(snapshot)) catch {
    _ =>
      return Err(
        issue(
          "write-task-execution", path, "failed to write task execution snapshot",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_runtime_validation_report(
  root : String,
  report_id : String,
  report_json : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = runtime_validation_report_path(root, report_id)
  @fsx.write_string_to_file(path, report_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-validation", path, "failed to write runtime validation report",
        ),
      )
  }
  let latest_path = latest_runtime_validation_path(root)
  @fsx.write_string_to_file(latest_path, report_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-validation-latest", latest_path, "failed to write latest runtime validation report",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_runtime_validation_session(
  root : String,
  session_id : String,
  session_json : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = runtime_validation_session_path(root, session_id)
  @fsx.write_string_to_file(path, session_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-validation-session", path, "failed to write runtime validation session",
        ),
      )
  }
  let latest_path = latest_runtime_validation_session_path(root)
  @fsx.write_string_to_file(latest_path, session_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-validation-session-latest", latest_path, "failed to write latest runtime validation session",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_runtime_calibration_plan(
  root : String,
  plan_id : String,
  plan_json : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = runtime_calibration_plan_path(root, plan_id)
  @fsx.write_string_to_file(path, plan_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-calibration", path, "failed to write runtime calibration plan",
        ),
      )
  }
  let latest_path = latest_runtime_calibration_plan_path(root)
  @fsx.write_string_to_file(latest_path, plan_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-calibration-latest", latest_path, "failed to write latest runtime calibration plan",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_runtime_calibration_resolution(
  root : String,
  resolution_id : String,
  resolution_json : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = runtime_calibration_resolution_path(root, resolution_id)
  @fsx.write_string_to_file(path, resolution_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-calibration-resolution", path, "failed to write runtime calibration resolution",
        ),
      )
  }
  let latest_path = latest_runtime_calibration_resolution_path(root)
  @fsx.write_string_to_file(latest_path, resolution_json) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-calibration-resolution-latest", latest_path, "failed to write latest runtime calibration resolution",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_replay_annotation(
  root : String,
  annotation : @annotation.ReplayAnnotation,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/annotations/\{annotation.session_id}") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = replay_annotation_path(
    root,
    annotation.session_id,
    annotation.annotation_id,
  )
  @fsx.write_string_to_file(path, replay_annotation_json(annotation)) catch {
    _ =>
      return Err(
        issue(
          "write-annotation", path, "failed to write RoboBook replay annotation",
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
          "write-observation", path, "failed to write RoboBook observation session",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_process_review(
  root : String,
  review : @review.ProcessReview,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = process_review_path(root, review.review_id)
  @fsx.write_string_to_file(path, process_review_json(review)) catch {
    _ =>
      return Err(
        issue("write-review", path, "failed to write RoboBook process review"),
      )
  }
  Ok(path)
}

///|
pub fn write_policy_evaluation_json(
  root : String,
  evaluation_id : String,
  text : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = policy_evaluation_path(root, evaluation_id)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue(
          "write-policy-eval", path, "failed to write RoboBook policy evaluation",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_moonbook_memory_json(
  root : String,
  pack_id : String,
  text : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = moonbook_memory_path(root, pack_id)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue(
          "write-moonbook-memory", path, "failed to write MoonBook memory pack",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_moonbook_task_message_json(
  root : String,
  task_id : String,
  text : String,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = moonbook_task_message_path(root, task_id)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue(
          "write-moonbook-task-message", path, "failed to write MoonBook task message plan",
        ),
      )
  }
  Ok(path)
}

///|
pub fn write_runtime_health(
  root : String,
  record : @runtime_health.RuntimeHealthRecord,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let text = runtime_health_json(record)
  let path = runtime_health_path(root, record.health_id)
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-health", path, "failed to write runtime health record",
        ),
      )
  }
  @fsx.write_string_to_file(latest_runtime_health_path(root), text) catch {
    _ =>
      return Err(
        issue(
          "write-runtime-health-latest",
          latest_runtime_health_path(root),
          "failed to write latest runtime health record",
        ),
      )
  }
  Ok(path)
}

///|
fn tool_registry_issue(
  path : String,
  item : @tool_registry.RegistryIssue,
) -> RuntimeIssue {
  issue(item.code, path + ":" + item.path, item.message)
}

///|
pub fn tool_registry_json(
  registry : @tool_registry.ToolRegistry,
  indent? : Int = 2,
) -> String {
  registry.to_json().stringify(indent~)
}

///|
pub fn write_tool_registry(
  root : String,
  registry : @tool_registry.ToolRegistry,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = tool_registry_path(root)
  let issues = @tool_registry.validate_registry(registry)
  if !issues.is_empty() {
    return Err(tool_registry_issue(path, issues[0]))
  }
  @fsx.write_string_to_file(path, tool_registry_json(registry)) catch {
    _ =>
      return Err(
        issue(
          "write-tool-registry", path, "failed to write Moonrobo tool registry",
        ),
      )
  }
  Ok(path)
}

///|
pub fn read_tool_registry(
  root : String,
) -> Result[@tool_registry.ToolRegistry, RuntimeIssue] {
  let path = tool_registry_path(root)
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-tool-registry", path, "failed to read Moonrobo tool registry",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-tool-registry", path, "failed to parse Moonrobo tool registry JSON",
        ),
      )
  }
  let registry : @tool_registry.ToolRegistry = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-tool-registry", path, "failed to decode Moonrobo tool registry contract",
        ),
      )
  }
  let issues = @tool_registry.validate_registry(registry)
  if !issues.is_empty() {
    return Err(tool_registry_issue(path, issues[0]))
  }
  Ok(registry)
}

///|
pub fn ensure_tool_registry(
  root : String,
  robot_id : @core.RobotId,
  generated_at_ms : Int64,
) -> Result[@tool_registry.ToolRegistry, RuntimeIssue] {
  match read_tool_registry(root) {
    Ok(registry) => Ok(registry)
    Err(error) =>
      if error.code == "read-tool-registry" {
        let registry = @tool_registry.default_registry(
          robot_id, generated_at_ms,
        )
        match write_tool_registry(root, registry) {
          Ok(_) => Ok(registry)
          Err(issue) => Err(issue)
        }
      } else {
        Err(error)
      }
  }
}

///|
pub fn register_tool_provider(
  root : String,
  robot_id : @core.RobotId,
  provider : @tool_registry.ToolProvider,
  generated_at_ms : Int64,
) -> Result[@tool_registry.ToolRegistry, RuntimeIssue] {
  let base = match ensure_tool_registry(root, robot_id, generated_at_ms) {
    Ok(registry) => registry
    Err(error) => return Err(error)
  }
  let updated = @tool_registry.with_provider(base, provider, generated_at_ms)
  match write_tool_registry(root, updated) {
    Ok(_) => Ok(updated)
    Err(error) => Err(error)
  }
}

///|
pub fn read_moonbook_memory_json_file(
  path : String,
) -> Result[String, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-moonbook-memory", path, "failed to read MoonBook memory pack",
        ),
      )
  }
  Ok(text)
}

///|
pub fn read_moonbook_memory_json(
  root : String,
  pack_id : String,
) -> Result[String, RuntimeIssue] {
  read_moonbook_memory_json_file(moonbook_memory_path(root, pack_id))
}

///|
pub fn list_moonbook_memory_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = moonbook_memory_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-moonbook-memory", dir, "failed to read MoonBook memory directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "moonbook/memory/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_moonbook_task_message_json_file(
  path : String,
) -> Result[String, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-moonbook-task-message", path, "failed to read MoonBook task message plan",
        ),
      )
  }
  Ok(text)
}

///|
pub fn read_moonbook_task_message_json(
  root : String,
  task_id : String,
) -> Result[String, RuntimeIssue] {
  read_moonbook_task_message_json_file(
    moonbook_task_message_path(root, task_id),
  )
}

///|
pub fn list_moonbook_task_message_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = moonbook_task_messages_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-moonbook-task-messages", dir, "failed to read MoonBook task message directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "moonbook/task-messages/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_robo_turn_json_file(path : String) -> Result[String, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-robo-turn", path, "failed to read Robo turn artifact"),
      )
  }
  Ok(text)
}

///|
pub fn read_robo_turn_json(
  root : String,
  turn_id : String,
) -> Result[String, RuntimeIssue] {
  read_robo_turn_json_file(
    robobook_path(root, "runs/robo-turns/\{turn_id}.json"),
  )
}

///|
pub fn list_robo_turn_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = robo_turns_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-robo-turns", dir, "failed to read Robo turn directory"),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/robo-turns/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_robo_loop_json_file(path : String) -> Result[String, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-robo-loop", path, "failed to read Robo loop artifact"),
      )
  }
  Ok(text)
}

///|
pub fn read_robo_loop_json(
  root : String,
  loop_id : String,
) -> Result[String, RuntimeIssue] {
  read_robo_loop_json_file(
    robobook_path(root, "runs/robo-loops/\{loop_id}.json"),
  )
}

///|
pub fn list_robo_loop_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = robo_loops_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-robo-loops", dir, "failed to read Robo loop directory"),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/robo-loops/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_runtime_health_file(
  path : String,
) -> Result[@runtime_health.RuntimeHealthRecord, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-runtime-health", path, "failed to read runtime health record",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-runtime-health", path, "failed to parse runtime health JSON",
        ),
      )
  }
  let record : @runtime_health.RuntimeHealthRecord = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-runtime-health", path, "failed to decode runtime health record",
        ),
      )
  }
  Ok(record)
}

///|
pub fn read_latest_runtime_health(
  root : String,
) -> Result[@runtime_health.RuntimeHealthRecord?, RuntimeIssue] {
  let path = latest_runtime_health_path(root)
  if !@fsx.path_exists(path) {
    Ok(None)
  } else {
    match read_runtime_health_file(path) {
      Ok(record) => Ok(Some(record))
      Err(error) => Err(error)
    }
  }
}

///|
pub fn list_runtime_health_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = runtime_health_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-runtime-health", dir, "failed to read runtime health directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") && name != "latest.json" {
      paths.push(robobook_path(root, "runs/runtime-health/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_policy_evaluation_json_file(
  path : String,
) -> Result[String, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-policy-eval", path, "failed to read RoboBook policy evaluation",
        ),
      )
  }
  Ok(text)
}

///|
pub fn read_policy_evaluation_json(
  root : String,
  evaluation_id : String,
) -> Result[String, RuntimeIssue] {
  read_policy_evaluation_json_file(policy_evaluation_path(root, evaluation_id))
}

///|
pub fn list_policy_evaluation_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = policy_evals_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-policy-evals", dir, "failed to read RoboBook policy evaluation directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/policy-evals/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn write_telemetry_frame(
  root : String,
  session_id : String,
  frame : @core.TelemetryFrame,
) -> Result[String, RuntimeIssue] {
  match ensure_process_dirs(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match ensure_dir(root, "runs/telemetry/\{session_id}") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let path = telemetry_frame_path(root, session_id, frame.frame_id)
  @fsx.write_string_to_file(path, telemetry_frame_json(frame)) catch {
    _ =>
      return Err(
        issue(
          "write-telemetry", path, "failed to write RoboBook telemetry frame",
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
pub fn read_bridge_dispatch_evidence(
  root : String,
  dispatch_id : String,
) -> Result[@core.BridgeDispatchEvidence, RuntimeIssue] {
  let path = bridge_dispatch_evidence_path(root, dispatch_id)
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-bridge-dispatch", path, "failed to read bridge dispatch evidence",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-bridge-dispatch", path, "failed to parse bridge dispatch JSON",
        ),
      )
  }
  let dispatch : @core.BridgeDispatchEvidence = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-bridge-dispatch", path, "failed to decode bridge dispatch evidence",
        ),
      )
  }
  Ok(dispatch)
}

///|
pub fn read_task_execution_snapshot(
  root : String,
  snapshot_id : String,
) -> Result[@core.TaskExecutionSnapshot, RuntimeIssue] {
  read_task_execution_snapshot_file(
    task_execution_snapshot_path(root, snapshot_id),
  )
}

///|
pub fn read_task_execution_snapshot_file(
  path : String,
) -> Result[@core.TaskExecutionSnapshot, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-task-execution", path, "failed to read task execution snapshot",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-task-execution", path, "failed to parse task execution snapshot JSON",
        ),
      )
  }
  let snapshot : @core.TaskExecutionSnapshot = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-task-execution", path, "failed to decode task execution snapshot",
        ),
      )
  }
  Ok(snapshot)
}

///|
pub fn list_task_execution_snapshot_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = task_executions_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-task-executions", dir, "failed to read task execution snapshot directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/task-executions/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn read_replay_annotation_file(
  path : String,
) -> Result[@annotation.ReplayAnnotation, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-annotation", path, "failed to read RoboBook replay annotation",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-annotation", path, "failed to parse replay annotation JSON",
        ),
      )
  }
  let annotation : @annotation.ReplayAnnotation = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-annotation", path, "failed to decode replay annotation"),
      )
  }
  Ok(annotation)
}

///|
pub fn read_replay_annotation(
  root : String,
  session_id : String,
  annotation_id : String,
) -> Result[@annotation.ReplayAnnotation, RuntimeIssue] {
  read_replay_annotation_file(
    replay_annotation_path(root, session_id, annotation_id),
  )
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
          "read-observation", path, "failed to read RoboBook observation session",
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
pub fn read_telemetry_frame_file(
  path : String,
) -> Result[@core.TelemetryFrame, RuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-telemetry", path, "failed to read RoboBook telemetry frame"),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-telemetry", path, "failed to parse telemetry frame JSON"),
      )
  }
  let frame : @core.TelemetryFrame = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-telemetry", path, "failed to decode telemetry frame contract",
        ),
      )
  }
  Ok(frame)
}

///|
pub fn read_process_review(
  root : String,
  review_id : String,
) -> Result[@review.ProcessReview, RuntimeIssue] {
  let path = process_review_path(root, review_id)
  let text = @fsx.read_file_to_string(path) catch {
    _ => return Err(issue("read-review", path, "failed to read process review"))
  }
  let json = @json.parse(text) catch {
    _ => return Err(issue("parse-review", path, "failed to parse review JSON"))
  }
  let review : @review.ProcessReview = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-review", path, "failed to decode process review"),
      )
  }
  Ok(review)
}

///|
pub fn list_telemetry_frame_paths(
  root : String,
  session_id : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = telemetry_session_dir(root, session_id)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-telemetry", dir, "failed to read RoboBook telemetry directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(telemetry_session_dir(root, session_id) + "/\{name}")
    }
  }
  Ok(paths)
}

///|
pub fn list_replay_annotation_paths(
  root : String,
  session_id : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = annotation_session_dir(root, session_id)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-annotations", dir, "failed to read RoboBook annotation directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(annotation_session_dir(root, session_id) + "/\{name}")
    }
  }
  Ok(paths)
}

///|
pub fn list_replay_annotations(
  root : String,
  session_id : String,
) -> Result[Array[@annotation.ReplayAnnotation], RuntimeIssue] {
  let paths = match list_replay_annotation_paths(root, session_id) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let annotations : Array[@annotation.ReplayAnnotation] = []
  for path in paths {
    match read_replay_annotation_file(path) {
      Ok(annotation) => annotations.push(annotation)
      Err(error) => return Err(error)
    }
  }
  Ok(annotations)
}

///|
pub fn list_telemetry_frames(
  root : String,
  session_id : String,
) -> Result[Array[@core.TelemetryFrame], RuntimeIssue] {
  let paths = match list_telemetry_frame_paths(root, session_id) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let frames : Array[@core.TelemetryFrame] = []
  for path in paths {
    match read_telemetry_frame_file(path) {
      Ok(frame) => frames.push(frame)
      Err(error) => return Err(error)
    }
  }
  Ok(frames)
}

///|
pub fn list_process_review_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = reviews_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-reviews", dir, "failed to read RoboBook review directory"),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/reviews/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn list_process_reviews(
  root : String,
) -> Result[Array[@review.ProcessReview], RuntimeIssue] {
  let paths = match list_process_review_paths(root) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let reviews : Array[@review.ProcessReview] = []
  for path in paths {
    let text = @fsx.read_file_to_string(path) catch {
      _ =>
        return Err(
          issue("read-review", path, "failed to read RoboBook process review"),
        )
    }
    let json = @json.parse(text) catch {
      _ =>
        return Err(
          issue("parse-review", path, "failed to parse process review JSON"),
        )
    }
    let review : @review.ProcessReview = @json.from_json(json) catch {
      _ =>
        return Err(
          issue("decode-review", path, "failed to decode process review"),
        )
    }
    reviews.push(review)
  }
  Ok(reviews)
}

///|
pub fn list_observation_paths(
  root : String,
) -> Result[Array[String], RuntimeIssue] {
  let dir = observations_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-observations", dir, "failed to read RoboBook observation directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/observations/\{name}"))
    }
  }
  Ok(paths)
}

///|
pub fn list_observation_sessions(
  root : String,
) -> Result[Array[@core.ObservationSession], RuntimeIssue] {
  let paths = match list_observation_paths(root) {
    Ok(paths) => paths
    Err(error) => return Err(error)
  }
  let sessions : Array[@core.ObservationSession] = []
  for path in paths {
    let text = @fsx.read_file_to_string(path) catch {
      _ =>
        return Err(
          issue(
            "read-observation", path, "failed to read RoboBook observation session",
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
    sessions.push(session)
  }
  Ok(sessions)
}

///|
pub fn list_receipt_paths(root : String) -> Result[Array[String], RuntimeIssue] {
  let dir = receipts_dir(root)
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-receipts", dir, "failed to read RoboBook receipt directory"),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(robobook_path(root, "runs/receipts/\{name}"))
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
      return Err(issue("read-receipt", path, "failed to read RoboBook receipt"))
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-receipt", path, "failed to parse RoboBook receipt JSON"),
      )
  }
  let receipt : @core.RunReceipt = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-receipt", path, "failed to decode RoboBook receipt contract",
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
