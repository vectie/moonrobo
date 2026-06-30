///|
pub(all) struct UrdfPluginParameterSchema {
  name : String
  label : String
  value_kind : String
  default_value : String
  required : Bool
  description : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfPluginSchema {
  schema_id : String
  label : String
  plugin_name : String
  plugin_filename : String
  summary : String
  parameters : Array[UrdfPluginParameterSchema]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn plugin_parameter_schema(
  name : String,
  label : String,
  value_kind : String,
  default_value : String,
  required : Bool,
  description : String,
) -> UrdfPluginParameterSchema {
  { name, label, value_kind, default_value, required, description }
}

///|
fn gazebo_ros_control_schema() -> UrdfPluginSchema {
  {
    schema_id: "gazebo_ros_control",
    label: "ROS Control",
    plugin_name: "gazebo_ros_control",
    plugin_filename: "libgazebo_ros_control.so",
    summary: "Gazebo ROS control bridge for transmission-backed joints.",
    parameters: [
      plugin_parameter_schema(
        "robotNamespace", "Robot Namespace", "string", "", false, "ROS namespace used by the control bridge.",
      ),
      plugin_parameter_schema(
        "robotSimType", "Robot Sim Type", "string", "gazebo_ros_control/DefaultRobotHWSim",
        false, "Hardware simulation class used by the plugin.",
      ),
      plugin_parameter_schema(
        "controlPeriod", "Control Period", "number", "", false, "Optional controller update period in seconds.",
      ),
    ],
  }
}

///|
fn gazebo_ros_diff_drive_schema() -> UrdfPluginSchema {
  {
    schema_id: "gazebo_ros_diff_drive",
    label: "ROS Diff Drive",
    plugin_name: "gazebo_ros_diff_drive",
    plugin_filename: "libgazebo_ros_diff_drive.so",
    summary: "Gazebo ROS differential-drive command and odometry plugin.",
    parameters: [
      plugin_parameter_schema(
        "robotNamespace", "Robot Namespace", "string", "", false, "ROS namespace used by the drive plugin.",
      ),
      plugin_parameter_schema(
        "commandTopic", "Command Topic", "string", "cmd_vel", true, "Velocity command topic.",
      ),
      plugin_parameter_schema(
        "odometryTopic", "Odometry Topic", "string", "odom", true, "Odometry output topic.",
      ),
      plugin_parameter_schema(
        "odometryFrame", "Odometry Frame", "string", "odom", true, "Frame id for odometry output.",
      ),
      plugin_parameter_schema(
        "robotBaseFrame", "Robot Base Frame", "string", "base_link", true, "Base frame driven by the plugin.",
      ),
      plugin_parameter_schema(
        "updateRate", "Update Rate", "number", "50", false, "Plugin update rate in Hz.",
      ),
      plugin_parameter_schema(
        "wheelSeparation", "Wheel Separation", "number", "", true, "Distance between left and right wheels.",
      ),
      plugin_parameter_schema(
        "wheelDiameter", "Wheel Diameter", "number", "", true, "Wheel diameter used for velocity integration.",
      ),
      plugin_parameter_schema(
        "publishWheelTF", "Publish Wheel TF", "bool", "false", false, "Whether the plugin publishes wheel transforms.",
      ),
      plugin_parameter_schema(
        "publishOdom", "Publish Odom", "bool", "true", false, "Whether the plugin publishes odometry.",
      ),
    ],
  }
}

///|
fn gazebo_ros_joint_state_schema() -> UrdfPluginSchema {
  {
    schema_id: "gazebo_ros_joint_state_publisher",
    label: "ROS Joint State",
    plugin_name: "gazebo_ros_joint_state_publisher",
    plugin_filename: "libgazebo_ros_joint_state_publisher.so",
    summary: "Gazebo ROS joint-state publisher plugin.",
    parameters: [
      plugin_parameter_schema(
        "robotNamespace", "Robot Namespace", "string", "", false, "ROS namespace used by the joint-state publisher.",
      ),
      plugin_parameter_schema(
        "jointName", "Joint Name", "string", "", true, "Joint name or joint-name list understood by the plugin.",
      ),
      plugin_parameter_schema(
        "updateRate", "Update Rate", "number", "50", false, "Plugin update rate in Hz.",
      ),
    ],
  }
}

///|
pub fn gazebo_plugin_schemas() -> Array[UrdfPluginSchema] {
  [
    gazebo_ros_control_schema(),
    gazebo_ros_diff_drive_schema(),
    gazebo_ros_joint_state_schema(),
  ]
}

///|
pub fn gazebo_plugin_schema(schema_id : String) -> UrdfPluginSchema? {
  for schema in gazebo_plugin_schemas() {
    if schema.schema_id == schema_id {
      return Some(schema)
    }
  }
  None
}

///|
pub fn suggested_gazebo_plugin_schema(
  plugin_name : String,
  plugin_filename : String,
) -> UrdfPluginSchema? {
  let clean_name = plugin_name.trim()
  let clean_filename = plugin_filename.trim()
  for schema in gazebo_plugin_schemas() {
    if clean_name == schema.plugin_name ||
      clean_filename == schema.plugin_filename {
      return Some(schema)
    }
  }
  None
}
