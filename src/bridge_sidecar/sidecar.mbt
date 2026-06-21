///|
pub(all) enum SidecarTransport {
  LocalHttp
  Stdio
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisionPolicy {
  Manual
  RestartOnFailure
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeSidecarSpec {
  sidecar_id : String
  bridge_id : @core.BridgeId
  robot_id : @core.RobotId
  kind : @core.BridgeKind
  protocol_version : Int
  transport : SidecarTransport
  command : Array[String]
  env : Map[String, String]
  health_path : String
  telemetry_path : String
  execute_path : String
  mode : String
  supervision : SupervisionPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_sdk_e1_sidecar_path() -> String {
  "moonrobo-sdk-e1-bridge"
}

///|
pub fn sidecar_id(profile : @core.RobotProfile) -> String {
  "\{profile.id}:\{profile.bridge.id}"
}

///|
pub fn sdk_e1_command(
  profile : @core.RobotProfile,
  robotbook_root : String,
  sidecar_path? : String = default_sdk_e1_sidecar_path(),
) -> Array[String] {
  [
    sidecar_path,
    "serve",
    robotbook_root,
    "--robot-id",
    profile.id,
    "--bridge-id",
    profile.bridge.id,
  ]
}

///|
pub fn spec_for_profile(
  profile : @core.RobotProfile,
  robotbook_root : String,
  sidecar_path? : String = default_sdk_e1_sidecar_path(),
) -> BridgeSidecarSpec {
  {
    sidecar_id: sidecar_id(profile),
    bridge_id: profile.bridge.id,
    robot_id: profile.id,
    kind: profile.bridge.kind,
    protocol_version: @bridge_protocol.protocol_version(),
    transport: LocalHttp,
    command: sdk_e1_command(profile, robotbook_root, sidecar_path~),
    env: { "CYCLONEDDS_URI": "file://../sdk/config/dds.xml" },
    health_path: @bridge_protocol.route_for_operation(Health).path,
    telemetry_path: @bridge_protocol.route_for_operation(LatestTelemetry).path,
    execute_path: @bridge_protocol.route_for_operation(ExecuteIntent).path,
    mode: "control-gated",
    supervision: RestartOnFailure,
  }
}

///|
pub fn spec_json(spec : BridgeSidecarSpec, indent? : Int = 2) -> String {
  spec.to_json().stringify(indent~)
}
