///|
pub(all) struct MoonroboLiveReadinessResponse {
  status : String
  ready_for_live_sdk : Bool
  can_collect_proof : Bool
  can_request_dispatch : Bool
  physical_execution_allowed : Bool
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  runtime_status : String
  runtime_bridge_base_url : String
  runtime_health_path : String
  runtime_validation_session_path : String
  runtime_validation_session : @runtime.RuntimeValidationSessionEvidence?
  calibration_status : String
  calibration_path : String
  calibration_pending_revalidation : Bool
  calibration : RuntimeCalibrationPlanRecord?
  calibration_resolution : RuntimeCalibrationResolutionRecord?
  loop_proof : PlatformLoopProofResponse
  proof_session_count : Int
  latest_proof_session_path : String
  latest_proof_session : PlatformProofSessionResponse?
  next_method : String
  next_route : String
  next_title : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonrobo_live_readiness_path() -> String {
  "/api/moonrobo/live-readiness"
}

///|
fn latest_runtime_validation_session_evidence(
  root : String,
) -> @runtime.RuntimeValidationSessionEvidence? {
  let path = @runtime.latest_runtime_validation_session_path(root)
  if !@fsx.path_exists(path) {
    return None
  }
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
fn latest_runtime_calibration_plan(
  root : String,
) -> RuntimeCalibrationPlanRecord? {
  let json = match latest_runtime_calibration_json(root) {
    Ok(json) => json
    Err(_) => return None
  }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
fn latest_proof_session(
  root : String,
) -> Result[(PlatformProofSessionResponse?, Int), HostApiResponse] {
  let paths = match list_proof_session_paths(root) {
    Ok(paths) => paths
    Err(response) => return Err(response)
  }
  if paths.is_empty() {
    return Ok((None, 0))
  }
  let latest_path = paths[paths.length() - 1]
  match read_proof_session_file(latest_path) {
    Ok(session) => Ok((Some(session), paths.length()))
    Err(response) => Err(response)
  }
}

///|
fn calibration_status_for_live_readiness(
  root : String,
  plan : RuntimeCalibrationPlanRecord?,
  pending_revalidation : Bool,
) -> String {
  match plan {
    None => "missing"
    Some(plan) =>
      if calibration_cleared_by_ready_session(root, plan) {
        "cleared"
      } else if pending_revalidation {
        "pending-revalidation"
      } else if plan.actions.is_empty() {
        "clear"
      } else {
        plan.status
      }
  }
}

///|
fn live_readiness_status(
  proof : PlatformLoopProofResponse,
  ready_for_live_sdk : Bool,
  calibration_status : String,
) -> String {
  if proof.ready {
    "verified"
  } else if ready_for_live_sdk &&
    (
      calibration_status == "clear" ||
      calibration_status == "cleared" ||
      calibration_status == "ready"
    ) {
    "ready-for-live-proof"
  } else if calibration_status == "pending-revalidation" {
    "needs-runtime-validation"
  } else if calibration_status == "needs-calibration" {
    "needs-calibration"
  } else {
    "needs-runtime-validation"
  }
}

///|
fn live_readiness_next(status : String) -> (String, String, String) {
  match status {
    "verified" =>
      (
        "POST",
        moontown_task_message_path(),
        "Submit the next Moontown task message",
      )
    "ready-for-live-proof" =>
      (
        "POST",
        platform_proof_session_path(),
        "Run a bounded proof session against the live-ready runtime",
      )
    "needs-calibration" =>
      (
        "GET",
        agent_runtime_calibration_path(),
        "Resolve the latest runtime calibration blocker",
      )
    _ =>
      (
        "POST",
        runtime_validation_session_path(),
        "Collect a repeated runtime validation session",
      )
  }
}

///|
fn live_readiness_message(status : String, next_route : String) -> String {
  match status {
    "verified" =>
      "Moonrobo has verified live execution evidence for this RoboBook."
    "ready-for-live-proof" =>
      "Live SDK readiness is proven; continue with \{next_route} to collect sustained proof."
    "needs-calibration" =>
      "Runtime calibration must be resolved before live proof or dispatch."
    "needs-runtime-validation" =>
      "Collect a newer runtime validation session before live proof or dispatch."
    _ => "Moonrobo live readiness is \{status}; continue with \{next_route}."
  }
}

///|
pub fn moonrobo_live_readiness_response(root : String) -> HostApiResponse {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let loop_proof = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let runtime_session = latest_runtime_validation_session_evidence(root)
  let ready_for_live_sdk = match runtime_session {
    Some(session) => session.ready_for_live_sdk
    None => false
  }
  let (runtime_status, runtime_bridge_base_url) = latest_runtime_context(root)
  let calibration = latest_runtime_calibration_plan(root)
  let calibration_resolution = latest_runtime_calibration_resolution(root)
  let pending_revalidation = match calibration {
    Some(plan) => calibration_pending_revalidation(root, plan) is Some(_)
    None => false
  }
  let calibration_status = calibration_status_for_live_readiness(
    root, calibration, pending_revalidation,
  )
  let (latest_session, proof_session_count) = match latest_proof_session(root) {
    Ok(result) => result
    Err(response) => return response
  }
  let status = live_readiness_status(
    loop_proof, ready_for_live_sdk, calibration_status,
  )
  let (next_method, next_route, next_title) = live_readiness_next(status)
  let can_collect_proof = status == "ready-for-live-proof" ||
    status == "verified"
  let can_request_dispatch = status == "ready-for-live-proof"
  json_response(
    200,
    MoonroboLiveReadinessResponse::{
      status,
      ready_for_live_sdk,
      can_collect_proof,
      can_request_dispatch,
      physical_execution_allowed: can_request_dispatch,
      robot_id: book.profile.id,
      bridge_id: book.profile.bridge.id,
      runtime_status,
      runtime_bridge_base_url,
      runtime_health_path: @runtime.latest_runtime_health_path(root),
      runtime_validation_session_path: @runtime.latest_runtime_validation_session_path(
        root,
      ),
      runtime_validation_session: runtime_session,
      calibration_status,
      calibration_path: @runtime.latest_runtime_calibration_plan_path(root),
      calibration_pending_revalidation: pending_revalidation,
      calibration,
      calibration_resolution,
      loop_proof,
      proof_session_count,
      latest_proof_session_path: match latest_session {
        Some(session) => session.session_path
        None => ""
      },
      latest_proof_session: latest_session,
      next_method,
      next_route,
      next_title,
      message: live_readiness_message(status, next_route),
    }.to_json(),
  )
}
