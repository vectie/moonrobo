///|
pub(all) struct RobotModelManifest {
  model_id : RobotModelId
  robot_id : String
  format : String
  status : String
  urdf_ref : DataRef
  mesh_refs : Array[DataRef]
  material_refs : Array[DataRef]
  link_names : Array[String]
  joint_names : Array[String]
  provenance : String
  validation_status : String
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robot_model_manifest(
  model_id : RobotModelId,
  robot_id : String,
  format : String,
  status : String,
  urdf_ref : DataRef,
  created_at_ms : Int64,
  mesh_refs? : Array[DataRef] = [],
  material_refs? : Array[DataRef] = [],
  link_names? : Array[String] = [],
  joint_names? : Array[String] = [],
  provenance? : String = "",
  validation_status? : String = "unvalidated",
  summary? : String = "",
) -> RobotModelManifest {
  {
    model_id,
    robot_id,
    format,
    status,
    urdf_ref,
    mesh_refs,
    material_refs,
    link_names,
    joint_names,
    provenance,
    validation_status,
    created_at_ms,
    summary,
  }
}
