///|
fn decode_runtime_validation_session_request(
  body : String,
  path : String,
) -> Result[@runtime.RuntimeValidationSessionRequest, HostApiResponse] {
  if body == "" {
    return Ok(@runtime.default_runtime_validation_session_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400, "parse-runtime-validation-session", path, "failed to parse runtime validation session JSON",
        ),
      )
  }
  let request : @runtime.RuntimeValidationSessionRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400, "decode-runtime-validation-session", path, "failed to decode runtime validation session contract",
        ),
      )
  }
  Ok(request)
}

///|
pub fn runtime_validation_session_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match
    decode_runtime_validation_session_request(
      body,
      runtime_validation_session_path(),
    ) {
    Ok(value) => value
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  match
    @runtime.write_runtime_validation_session_from_latest_health(
      root,
      book.profile,
      0L,
      request,
    ) {
    Ok(result) =>
      json_response(
        200,
        runtime_validation_session_response_json(
          root,
          book.profile,
          request,
          result,
        ),
      )
    Err(issue) => error_response(500, issue.code, issue.path, issue.message)
  }
}

///|
fn runtime_validation_first_blocker(
  session : @runtime.RuntimeValidationSessionEvidence,
) -> String {
  if session.ready_for_live_sdk {
    ""
  } else if !session.mapping_stable {
    "runtime-identity-match"
  } else {
    "runtime-health"
  }
}

///|
fn runtime_validation_session_response_json(
  root : String,
  profile : @core.RobotProfile,
  request : @runtime.RuntimeValidationSessionRequest,
  result : @runtime.RuntimeValidationSessionResult,
) -> Json {
  let session = result.session
  let ready_sample_count = if session.ready_for_live_sdk {
    session.sample_count
  } else {
    0
  }
  let blocked_sample_count = session.sample_count - ready_sample_count
  let calibration_status = if session.ready_for_live_sdk {
    "ready"
  } else {
    "needs-calibration"
  }
  {
    "persisted": result.persisted,
    "sample_count": session.sample_count,
    "session_path": result.session_path,
    "latest_session_path": @runtime.latest_runtime_validation_session_path(root),
    "calibration_path": @runtime.latest_runtime_calibration_plan_path(root),
    "latest_calibration_path": @runtime.latest_runtime_calibration_plan_path(
      root,
    ),
    "session": {
      "session_id": session.session_id,
      "generated_at_ms": session.generated_at_ms,
      "sample_count": session.sample_count,
      "physical_execution_allowed": session.physical_execution_allowed,
      "ready_for_live_sdk": session.ready_for_live_sdk,
      "runtime_id": session.runtime_id,
      "robot_id": session.robot_id,
      "bridge_id": session.bridge_id,
      "mapping_stable": session.mapping_stable,
      "mapping_status": session.mapping_status,
      "mapping_sample_count": session.mapping_sample_count,
      "mapping_matching_sample_count": session.mapping_matching_sample_count,
      "mapping_mismatch_sample_count": session.mapping_mismatch_sample_count,
      "mapping_message": session.mapping_message,
      "health_path": session.health_path,
      "telemetry_path": session.telemetry_path,
      "status": session.status,
      "message": session.message,
      "required_sample_count": request.sample_count,
      "ready_sample_count": ready_sample_count,
      "blocked_sample_count": blocked_sample_count,
      "first_blocker_code": runtime_validation_first_blocker(session),
      "mapping_proof": {
        "robot_id": profile.id,
        "bridge_id": profile.bridge.id,
        "sample_count": session.mapping_sample_count,
        "matching_sample_count": session.mapping_matching_sample_count,
        "mismatch_sample_count": session.mapping_mismatch_sample_count,
        "stable": session.mapping_stable,
        "status": session.mapping_status,
        "first_mismatch_report_id": if session.mapping_stable {
          ""
        } else {
          session.session_id
        },
        "message": session.mapping_message,
      },
    },
    "calibration": {
      "status": calibration_status,
      "action_count": if session.ready_for_live_sdk {
        0
      } else {
        1
      },
      "blocking_action_count": if session.ready_for_live_sdk {
        0
      } else {
        1
      },
    },
  }
}
