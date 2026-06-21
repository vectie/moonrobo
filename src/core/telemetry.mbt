///|
pub(all) struct JointTelemetry {
  name : String
  index : Int
  position : Double
  velocity : Double
  torque : Double
  error : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ImuTelemetry {
  orientation : Array[Double]
  angular_velocity : Array[Double]
  linear_acceleration : Array[Double]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TelemetryFrame {
  frame_id : String
  robot_id : RobotId
  bridge_id : BridgeId
  captured_at_ms : Int64
  mode : String
  joints : Array[JointTelemetry]
  imu : ImuTelemetry?
  operator_input : Map[String, String]
  errors : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn empty_telemetry_frame(
  frame_id : String,
  robot_id : RobotId,
  bridge_id : BridgeId,
  captured_at_ms : Int64,
) -> TelemetryFrame {
  {
    frame_id,
    robot_id,
    bridge_id,
    captured_at_ms,
    mode: "read-only",
    joints: [],
    imu: None,
    operator_input: {},
    errors: [],
  }
}
