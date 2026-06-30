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
pub(all) struct UrdfLimitPatch {
  lower : Double?
  upper : Double?
  effort : Double?
  velocity : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfOriginNode {
  node_id : String
  xyz : String
  rpy : String
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
  limit : UrdfLimitNode?
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
