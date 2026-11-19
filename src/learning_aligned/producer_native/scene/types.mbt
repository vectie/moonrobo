///|
/// Values use USD-authored units unless their field explicitly says SI/radians.
pub(all) struct RigidBody {
  path : String
  name : String
  world_transform : Array[Double]
  enabled : Bool
  kinematic : Bool
  mass_properties : Json
  velocity : Array[Double]
  angular_velocity_degrees : Array[Double]
} derive(FromJson, ToJson)

///|
pub(all) struct Joint {
  path : String
  name : String
  kind : String
  body0 : Array[String]
  body1 : Array[String]
  local_position0 : Array[Double]
  local_position1 : Array[Double]
  local_rotation0_wxyz : Array[Double]
  local_rotation1_wxyz : Array[Double]
  axis : String
  limits : Json
  enabled : Bool
  collision_enabled : Bool
  excluded_from_articulation : Bool
  drives : Json
} derive(FromJson, ToJson)

///|
pub(all) struct CollisionShape {
  path : String
  body : String?
  kind : String
  world_transform : Array[Double]
  geometry : Json
  material : String?
  enabled : Bool
  approximation : String?
} derive(FromJson, ToJson)

///|
pub(all) struct ArticulationIR {
  format : String
  root : String
  meters_per_unit : Double
  kilograms_per_unit : Double
  up_axis : String
  bodies : Array[RigidBody]
  joints : Array[Joint]
  shapes : Array[CollisionShape]
  materials : Json
  filtered_pairs : Json
  articulation_roots : Array[String]
  unsupported_features : Array[String]
  extension_properties : Json
} derive(FromJson, ToJson)

///|
pub(all) struct Actuator {
  name : String
  joint_name : String
  joint_path : String
  joint_index : Int32
  default_position_radians : Double
  default_velocity_radians : Double
  effort_limit : Double
  velocity_limit : Double
  stiffness : Double
  damping : Double
  armature : Double
  action_scale : Double
} derive(FromJson, ToJson)

///|
pub(all) struct ScenePlan {
  format : String
  source : ArticulationIR
  canonical_joint_names : Array[String]
  actuators : Array[Actuator]
  recipe : Json
  sdk_revision_pins : Json
  newton_model_constructed : Bool
  physical_equivalence_verified : Bool
} derive(ToJson)
