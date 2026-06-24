///|
pub(all) struct RuntimeValidationSessionRequest {
  sample_count : Int
  physical_execution_allowed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeValidationSessionEvidence {
  session_id : String
  generated_at_ms : Int64
  sample_count : Int
  physical_execution_allowed : Bool
  ready_for_live_sdk : Bool
  runtime_id : String
  robot_id : String
  bridge_id : String
  mapping_stable : Bool
  mapping_status : String
  mapping_sample_count : Int
  mapping_matching_sample_count : Int
  mapping_mismatch_sample_count : Int
  mapping_message : String
  health_path : String
  telemetry_path : String
  status : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeValidationSessionResult {
  persisted : Bool
  session_path : String
  session : RuntimeValidationSessionEvidence
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_runtime_validation_session_request(
  sample_count? : Int = 3,
  physical_execution_allowed? : Bool = false,
) -> RuntimeValidationSessionRequest {
  { sample_count, physical_execution_allowed }
}

///|
fn latest_health_ready_for_profile(
  profile : @core.RobotProfile,
  health : @runtime_health.RuntimeHealthRecord,
) -> Bool {
  health.status == "healthy" &&
  health.active &&
  health.running &&
  health.telemetry_ok &&
  health.robot_id == profile.id &&
  health.bridge_id == profile.bridge.id
}

///|
fn mapping_message(
  profile : @core.RobotProfile,
  matching_sample_count : Int,
  mismatch_sample_count : Int,
) -> String {
  if mismatch_sample_count == 0 && matching_sample_count > 0 {
    "\{matching_sample_count} runtime validation sample(s) matched RoboBook robot \{profile.id} and bridge \{profile.bridge.id}"
  } else {
    "\{mismatch_sample_count} runtime validation sample(s) did not match RoboBook robot \{profile.id} and bridge \{profile.bridge.id}"
  }
}

///|
fn validation_session_from_health(
  root : String,
  profile : @core.RobotProfile,
  generated_at_ms : Int64,
  request : RuntimeValidationSessionRequest,
  health : @runtime_health.RuntimeHealthRecord?,
) -> RuntimeValidationSessionEvidence {
  match health {
    Some(record) => {
      let session_ms = if generated_at_ms > 0L {
        generated_at_ms
      } else {
        record.recorded_at_ms
      }
      let session_id = "runtime-validation-session-\{profile.id}-\{session_ms}"
      let ready = latest_health_ready_for_profile(profile, record)
      let mapping_match = record.robot_id == profile.id &&
        record.bridge_id == profile.bridge.id
      let matching_sample_count = if mapping_match {
        request.sample_count
      } else {
        0
      }
      let mismatch_sample_count = request.sample_count - matching_sample_count
      {
        session_id,
        generated_at_ms: session_ms,
        sample_count: request.sample_count,
        physical_execution_allowed: request.physical_execution_allowed,
        ready_for_live_sdk: ready,
        runtime_id: record.runtime_id,
        robot_id: record.robot_id,
        bridge_id: record.bridge_id,
        mapping_stable: mapping_match,
        mapping_status: if mapping_match {
          "stable"
        } else {
          "mismatch"
        },
        mapping_sample_count: request.sample_count,
        mapping_matching_sample_count: matching_sample_count,
        mapping_mismatch_sample_count: mismatch_sample_count,
        mapping_message: mapping_message(
          profile, matching_sample_count, mismatch_sample_count,
        ),
        health_path: latest_runtime_health_path(root),
        telemetry_path: record.telemetry_path,
        status: if ready {
          "ready"
        } else {
          "blocked"
        },
        message: if ready {
          "latest runtime health matches RoboBook and telemetry is healthy"
        } else {
          "latest runtime health does not prove the selected RoboBook mapping"
        },
      }
    }
    None => {
      let session_id = "runtime-validation-session-\{profile.id}-\{generated_at_ms}"
      {
        session_id,
        generated_at_ms,
        sample_count: request.sample_count,
        physical_execution_allowed: request.physical_execution_allowed,
        ready_for_live_sdk: false,
        runtime_id: "",
        robot_id: profile.id,
        bridge_id: profile.bridge.id,
        mapping_stable: false,
        mapping_status: "missing",
        mapping_sample_count: request.sample_count,
        mapping_matching_sample_count: 0,
        mapping_mismatch_sample_count: request.sample_count,
        mapping_message: "no runtime health evidence exists for RoboBook robot \{profile.id} and bridge \{profile.bridge.id}",
        health_path: "",
        telemetry_path: "",
        status: "blocked",
        message: "no runtime health evidence exists for validation",
      }
    }
  }
}

///|
pub fn write_runtime_validation_session_from_latest_health(
  root : String,
  profile : @core.RobotProfile,
  generated_at_ms : Int64,
  request : RuntimeValidationSessionRequest,
) -> Result[RuntimeValidationSessionResult, RuntimeIssue] {
  let health = match read_latest_runtime_health(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let session = validation_session_from_health(
    root, profile, generated_at_ms, request, health,
  )
  let session_path = match
    write_runtime_validation_session(
      root,
      session.session_id,
      session.to_json().stringify(indent=2),
    ) {
    Ok(path) => path
    Err(error) => return Err(error)
  }
  Ok({ persisted: true, session_path, session })
}
