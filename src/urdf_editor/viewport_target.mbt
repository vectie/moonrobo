///|
pub(all) struct UrdfEditorViewportTarget {
  node_id : String
  selection_type : String
  sub_type : String
  link_name : String
  joint_name : String
  object_index : Int
  label : String
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn urdf_robot_node_id() -> String {
  "robot"
}

///|
pub fn urdf_link_node_id(name : String) -> String {
  "link:\{name}"
}

///|
pub fn urdf_joint_node_id(name : String) -> String {
  "joint:\{name}"
}

///|
pub fn urdf_visual_node_id(link_name : String, index : Int) -> String {
  "visual:\{link_name}:\{index}"
}

///|
pub fn urdf_collision_node_id(link_name : String, index : Int) -> String {
  "collision:\{link_name}:\{index}"
}

///|
pub fn urdf_inertial_node_id(link_name : String) -> String {
  "inertial:\{link_name}"
}

///|
pub fn viewport_link_target(
  name : String,
  depth : Int,
  status : String,
) -> UrdfEditorViewportTarget {
  {
    node_id: urdf_link_node_id(name),
    selection_type: "link",
    sub_type: "",
    link_name: name,
    joint_name: "",
    object_index: -1,
    label: name,
    detail: "depth \{depth}; \{status}",
  }
}

///|
pub fn viewport_joint_target(
  name : String,
  joint_type : String,
  parent_link : String,
  child_link : String,
  limit_state : String,
) -> UrdfEditorViewportTarget {
  {
    node_id: urdf_joint_node_id(name),
    selection_type: "joint",
    sub_type: "",
    link_name: child_link,
    joint_name: name,
    object_index: -1,
    label: name,
    detail: "\{joint_type} \{parent_link}->\{child_link}; \{limit_state}",
  }
}

///|
pub fn viewport_visual_target(
  link_name : String,
  index : Int,
  geometry_kind : String,
  asset_status : String,
) -> UrdfEditorViewportTarget {
  {
    node_id: urdf_visual_node_id(link_name, index),
    selection_type: "link",
    sub_type: "visual",
    link_name,
    joint_name: "",
    object_index: index,
    label: "\{link_name} visual \{index}",
    detail: "\{geometry_kind}; \{asset_status}",
  }
}

///|
pub fn viewport_collision_target(
  link_name : String,
  index : Int,
  geometry_kind : String,
  asset_status : String,
) -> UrdfEditorViewportTarget {
  {
    node_id: urdf_collision_node_id(link_name, index),
    selection_type: "link",
    sub_type: "collision",
    link_name,
    joint_name: "",
    object_index: index,
    label: "\{link_name} collision \{index}",
    detail: "\{geometry_kind}; \{asset_status}",
  }
}
