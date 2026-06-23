///|
pub(all) enum RobotKind {
  Humanoid
  Quadruped
  Arm
  MobileBase
  Unknown(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum BridgeKind {
  Mock
  Sim
  SdkE1
  Ros2
  UnknownBridge(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum CommandClass {
  Observe
  Simulate
  HighControl
  LowControl
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotModelRef {
  primary : String
  alternates : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeRef {
  id : BridgeId
  kind : BridgeKind
  config_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JointSpec {
  name : String
  index : Int
  min_position : Double?
  max_position : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SensorSpec {
  id : String
  kind : String
  label : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CapabilitySpec {
  id : CapabilityId
  command_class : CommandClass
  label : String
  enabled : Bool
  requires_approval : Bool
  requires_dry_run : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotLimits {
  telemetry_freshness_ms : Int
  heartbeat_ms : Int
  default_mode : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotProfile {
  id : RobotId
  label : String
  kind : RobotKind
  platform : String
  profile_version : Int
  model : RobotModelRef
  bridge : BridgeRef
  joints : Array[JointSpec]
  sensors : Array[SensorSpec]
  capabilities : Array[CapabilitySpec]
  limits : RobotLimits
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn capability(
  id : CapabilityId,
  command_class : CommandClass,
  label : String,
  enabled? : Bool = true,
  requires_approval? : Bool = false,
  requires_dry_run? : Bool = false,
) -> CapabilitySpec {
  { id, command_class, label, enabled, requires_approval, requires_dry_run }
}

///|
pub fn joint(
  name : String,
  index : Int,
  min_position? : Double,
  max_position? : Double,
) -> JointSpec {
  { name, index, min_position, max_position }
}

///|
pub fn sensor(id : String, kind : String, label : String) -> SensorSpec {
  { id, kind, label }
}

///|
pub fn noetix_e1_default_capabilities() -> Array[CapabilitySpec] {
  [
    capability("observe.telemetry", Observe, "Observe telemetry"),
    capability("observe.joints", Observe, "Observe joint state"),
    capability("observe.imu", Observe, "Observe IMU"),
    capability("simulate.motion", Simulate, "Dry-run motion intent"),
    capability("control.emergency.stop", HighControl, "Emergency stop or hold"),
    capability(
      "control.high.walk",
      HighControl,
      "High-level walk",
      requires_approval=true,
      requires_dry_run=true,
    ),
    capability(
      "control.high.run",
      HighControl,
      "High-level run",
      requires_approval=true,
      requires_dry_run=true,
    ),
    capability(
      "control.high.teach.start",
      HighControl,
      "Start teach mode",
      requires_approval=true,
    ),
    capability(
      "control.high.teach.play",
      HighControl,
      "Play teach recording",
      requires_approval=true,
      requires_dry_run=true,
    ),
    capability(
      "control.low.joint-position",
      LowControl,
      "Low-level joint position",
      enabled=false,
      requires_approval=true,
      requires_dry_run=true,
    ),
  ]
}

///|
pub fn noetix_e1_joint_names() -> Array[String] {
  [
    "arm_l1_joint", "arm_l2_joint", "arm_l3_joint", "arm_l4_joint", "arm_l5_joint",
    "leg_l1_joint", "leg_l2_joint", "leg_l3_joint", "leg_l4_joint", "leg_l5_joint",
    "leg_l6_joint", "arm_r1_joint", "arm_r2_joint", "arm_r3_joint", "arm_r4_joint",
    "arm_r5_joint", "leg_r1_joint", "leg_r2_joint", "leg_r3_joint", "leg_r4_joint",
    "leg_r5_joint", "leg_r6_joint", "waist_1_joint", "waist_2_joint",
  ]
}

///|
pub fn noetix_e1_profile(id : RobotId, label : String) -> RobotProfile {
  {
    id,
    label,
    kind: Humanoid,
    platform: "noetix-e1",
    profile_version: 1,
    model: {
      primary: "model/robot.urdf",
      alternates: ["model/robot.mjcf", "model/robot.usd"],
    },
    bridge: { id: "sdk-e1", kind: SdkE1, config_path: "bridge/bridge.json" },
    joints: noetix_e1_joint_names().mapi(fn(index, name) { joint(name, index) }),
    sensors: [
      sensor("imu", "imu", "Body IMU"),
      sensor("joystick", "operator-input", "Remote joystick"),
    ],
    capabilities: noetix_e1_default_capabilities(),
    limits: {
      telemetry_freshness_ms: 250,
      heartbeat_ms: 100,
      default_mode: "read-only",
    },
  }
}
