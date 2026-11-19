///|
/// A rigid offset applied to the recipe's initial root pose. Each placement
/// creates an independent logical world; no CUDA world or collision group.
pub(all) struct WorldPlacement {
  transform : @geo.Transform3
}

///|
/// JSON-friendly rigid world offset, using metres and a unit wxyz quaternion.
pub(all) struct Placement {
  position : Array[Double]
  quaternion_wxyz : Array[Double]
} derive(FromJson, ToJson)

///|
pub(all) struct PrepareRequest {
  usd_receipt : Json
  num_envs : Int32
  self_collisions : Bool
  placements : Array[Placement]
} derive(FromJson)

///|
pub(all) struct MassProperties {
  mass : Double
  inverse_mass : Double
  center_of_mass : Array[Double]
  inertia : Array[Double]
  inverse_inertia : Array[Double]
} derive(ToJson)

///|
/// Actual CPU/Double arrays for the supported kinematic tree and reset pose.
/// Type codes follow pinned Newton JointType; poses are xyz+xyzw. Optional mass
/// entries stay absent when USD requires inference. No device model is created.
pub(all) struct PreparedArrays {
  format : String
  body_paths : Array[String]
  body_source_index : Array[Int32]
  body_world : Array[Int32]
  body_q : Array[Double]
  body_qd : Array[Double]
  body_mass_properties : Array[MassProperties?]
  joint_paths : Array[String]
  joint_source_index : Array[Int32]
  joint_world : Array[Int32]
  joint_type : Array[Int32]
  joint_parent : Array[Int32]
  joint_child : Array[Int32]
  joint_X_p : Array[Double]
  joint_X_c : Array[Double]
  joint_q_start : Array[Int32]
  joint_qd_start : Array[Int32]
  joint_q : Array[Double]
  joint_qd : Array[Double]
  joint_axis : Array[Double]
  joint_axis_start : Array[Int32]
  joint_armature : Array[Double]
  joint_target_ke : Array[Double]
  joint_target_kd : Array[Double]
  joint_effort_limit : Array[Double]
  joint_velocity_limit : Array[Double]
  joint_limit_lower : Array[Double?]
  joint_limit_upper : Array[Double?]
  articulation_start : Array[Int32]
  articulation_end : Array[Int32]
  canonical_joint_to_builder : Array[Int32]
  canonical_coord_to_builder : Array[Int32]
  canonical_dof_to_builder : Array[Int32]
  unresolved_semantics : Array[String]
  mass_properties_complete : Bool
  full_finalize_complete : Bool
  newton_model_constructed : Bool
  numerical_equivalence_verified : Bool
} derive(ToJson)
