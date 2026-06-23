///|
pub(all) struct RuntimeHealthRecord {
  health_id : String
  recorded_at_ms : Int64
  status : String
  active : Bool
  running : Bool
  pid : Int
  launch_id : String
  runtime_id : String
  robot_id : String
  bridge_id : String
  bridge_base_url : String
  telemetry_ok : Bool
  telemetry_status : String
  telemetry_message : String
  telemetry_path : String
  telemetry_frame_id : String
  telemetry_captured_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn record(
  recorded_at_ms : Int64,
  status : String,
  active : Bool,
  running : Bool,
  pid : Int,
  launch_id : String,
  runtime_id : String,
  robot_id : String,
  bridge_id : String,
  bridge_base_url : String,
  telemetry_ok : Bool,
  telemetry_status : String,
  telemetry_message : String,
  telemetry_path : String,
  telemetry_frame_id : String,
  telemetry_captured_at_ms : Int64,
  health_id? : String = "runtime-health-\{recorded_at_ms}",
) -> RuntimeHealthRecord {
  {
    health_id,
    recorded_at_ms,
    status,
    active,
    running,
    pid,
    launch_id,
    runtime_id,
    robot_id,
    bridge_id,
    bridge_base_url,
    telemetry_ok,
    telemetry_status,
    telemetry_message,
    telemetry_path,
    telemetry_frame_id,
    telemetry_captured_at_ms,
  }
}

///|
pub fn priority(record : RuntimeHealthRecord) -> Int {
  match record.status {
    "healthy" => 58
    "running-unprobed" => 68
    "not-running" | "process-stopped" => 82
    "bridge-unhealthy" => 94
    _ => 72
  }
}

///|
pub fn summary(record : RuntimeHealthRecord) -> String {
  if record.status == "healthy" {
    "Runtime is healthy; bridge \{record.bridge_id} served telemetry frame \{record.telemetry_frame_id}"
  } else if record.status == "bridge-unhealthy" {
    "Runtime process is active but bridge telemetry failed: \{record.telemetry_message}"
  } else if record.status == "running-unprobed" {
    "Runtime process is running but bridge telemetry has not been probed"
  } else if record.status == "not-running" {
    "No active physical runtime supervisor is recorded"
  } else {
    "Runtime health is \{record.status}: \{record.telemetry_message}"
  }
}

///|
pub fn record_json(record : RuntimeHealthRecord, indent? : Int = 2) -> String {
  record.to_json().stringify(indent~)
}
