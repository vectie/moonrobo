///|
pub(all) struct BridgeHealth {
  bridge_id : BridgeId
  status : String
  mode : String
  robot_id : RobotId
  last_telemetry_age_ms : Int?
  capabilities_hash : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeMetadata {
  bridge_id : BridgeId
  kind : BridgeKind
  label : String
  protocol_version : Int
  read_only : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn bridge_ok(
  bridge_id : BridgeId,
  robot_id : RobotId,
  mode? : String = "read-only",
  last_telemetry_age_ms? : Int,
) -> BridgeHealth {
  {
    bridge_id,
    status: "ok",
    mode,
    robot_id,
    last_telemetry_age_ms,
    capabilities_hash: "",
  }
}

///|
pub fn bridge_down(
  bridge_id : BridgeId,
  robot_id : RobotId,
  reason : String,
) -> BridgeHealth {
  {
    bridge_id,
    status: reason,
    mode: "unavailable",
    robot_id,
    last_telemetry_age_ms: None,
    capabilities_hash: "",
  }
}
