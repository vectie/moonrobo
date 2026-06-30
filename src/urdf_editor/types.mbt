///|
pub(all) enum UrdfEditorSeverity {
  Info
  Warning
  Error
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfSourceSpan {
  start : Int
  end : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorIssue {
  code : String
  severity : UrdfEditorSeverity
  node_id : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfOriginPatch {
  xyz : String
  rpy : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfAxisPatch {
  xyz : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfLimitPatch {
  lower : Double?
  upper : Double?
  effort : Double?
  velocity : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfDynamicsPatch {
  damping : Double?
  friction : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfMimicPatch {
  target_joint : String
  multiplier : Double?
  offset : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfCalibrationPatch {
  rising : Double?
  falling : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfSafetyControllerPatch {
  soft_lower_limit : Double?
  soft_upper_limit : Double?
  k_position : Double?
  k_velocity : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfInertialPatch {
  origin : UrdfOriginPatch?
  mass : Double?
  ixx : Double?
  ixy : Double?
  ixz : Double?
  iyy : Double?
  iyz : Double?
  izz : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfMaterialPatch {
  color_rgba : String?
  texture_filename : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfGeometryPatch {
  kind : String
  mesh_filename : String?
  mesh_scale : String?
  size : String?
  radius : Double?
  length : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfExtensionPatch {
  raw_source : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfExtensionAttributePatch {
  name : String
  value : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfTransmissionPatch {
  transmission_type : String?
  joint_name : String?
  actuator_name : String?
  mechanical_reduction : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfPluginParameterPatch {
  name : String
  value : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfGazeboPluginPatch {
  plugin_name : String?
  plugin_filename : String?
  parameters : Array[UrdfPluginParameterPatch]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfLinkCreatePatch {
  name : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfJointCreatePatch {
  name : String
  joint_type : String
  parent_link : String
  child_link : String
  origin : UrdfOriginPatch?
  axis : UrdfAxisPatch?
  limit : UrdfLimitPatch?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfVisualCreatePatch {
  link_name : String
  origin : UrdfOriginPatch?
  geometry : UrdfGeometryPatch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfCollisionCreatePatch {
  link_name : String
  origin : UrdfOriginPatch?
  geometry : UrdfGeometryPatch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfOriginNode {
  node_id : String
  xyz : String
  rpy : String
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfAxisNode {
  node_id : String
  xyz : String
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfLimitNode {
  node_id : String
  lower : Double?
  upper : Double?
  effort : Double?
  velocity : Double?
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfDynamicsNode {
  node_id : String
  damping : Double?
  friction : Double?
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfMimicNode {
  node_id : String
  target_joint : String
  multiplier : Double?
  offset : Double?
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfCalibrationNode {
  node_id : String
  rising : Double?
  falling : Double?
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfSafetyControllerNode {
  node_id : String
  soft_lower_limit : Double?
  soft_upper_limit : Double?
  k_position : Double?
  k_velocity : Double?
  source_span : UrdfSourceSpan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfLinkNode {
  node_id : String
  name : String
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfJointNode {
  node_id : String
  name : String
  joint_type : String
  parent_link : String
  child_link : String
  origin : UrdfOriginNode?
  axis : String
  axis_node : UrdfAxisNode?
  limit : UrdfLimitNode?
  dynamics : UrdfDynamicsNode?
  mimic : UrdfMimicNode?
  calibration : UrdfCalibrationNode?
  safety_controller : UrdfSafetyControllerNode?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfVisualNode {
  node_id : String
  link_name : String
  index : Int
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : UrdfOriginNode?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfCollisionNode {
  node_id : String
  link_name : String
  index : Int
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : UrdfOriginNode?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfInertialNode {
  node_id : String
  link_name : String
  origin : UrdfOriginNode?
  mass : Double?
  ixx : Double?
  ixy : Double?
  ixz : Double?
  iyy : Double?
  iyz : Double?
  izz : Double?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfMaterialNode {
  node_id : String
  scope : String
  name : String
  link_name : String
  visual_index : Int?
  color_rgba : String
  texture_filename : String
  color_source_span : UrdfSourceSpan?
  texture_source_span : UrdfSourceSpan?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfExtensionNode {
  node_id : String
  kind : String
  tag_name : String
  parent_id : String
  label : String
  raw : String
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
  close_tag_span : UrdfSourceSpan?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfDocument {
  source : String
  robot_name : String
  links : Array[UrdfLinkNode]
  joints : Array[UrdfJointNode]
  visuals : Array[UrdfVisualNode]
  collisions : Array[UrdfCollisionNode]
  inertials : Array[UrdfInertialNode]
  materials : Array[UrdfMaterialNode]
  extensions : Array[UrdfExtensionNode]
  issues : Array[UrdfEditorIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditResult {
  changed : Bool
  command : String
  target : String
  source : String
  message : String
  issues : Array[UrdfEditorIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditError {
  code : String
  target : String
  message : String
  issues : Array[UrdfEditorIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  code : String,
  severity : UrdfEditorSeverity,
  node_id : String,
  message : String,
) -> UrdfEditorIssue {
  { code, severity, node_id, message }
}

///|
fn edit_error(
  code : String,
  target : String,
  message : String,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditError {
  { code, target, message, issues }
}
