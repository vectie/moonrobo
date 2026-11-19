///|
/// Explicit resolved Newton material attributes, not USD schema defaults.
pub(all) struct ShapeMaterial {
  ke : Double
  kd : Double
  kf : Double
  ka : Double
  mu : Double
  restitution : Double
  mu_torsional : Double
  mu_rolling : Double
  kh : Double
} derive(FromJson, ToJson)

///|
/// body/world are global prepared-model indices; -1 body is static, -1 world
/// is global. Transform is body-local for attached shapes and world for static.
pub(all) struct ResolvedShape {
  kind : String
  body : Int32
  world : Int32
  transform : @geo.Transform3
  scale : @geo.Vec3
  material : ShapeMaterial
  flags : Int32
  collision_group : Int32
  margin : Double
  gap : Double
  collision_radius : Double
  is_solid : Bool
} derive(FromJson, ToJson)

///|
pub(all) struct ShapePair {
  a : Int32
  b : Int32
} derive(FromJson, ToJson)

///|
/// A Newton Contacts stream capacity, not per-world MuJoCo/MJWarp contacts.
pub(all) struct ContactCapacity {
  rigid_max : Int32
  soft_max : Int32
  requires_grad : Bool
  per_contact_shape_properties : Bool
  contact_matching : Bool
  contact_report : Bool
  surface_velocity : Bool
} derive(FromJson, ToJson)

///|
/// Callers supply already resolved Newton shape data/filter exclusions. This
/// request does not infer USD resolver priorities or grow collision geometry.
pub(all) struct CollisionRequest {
  base : CommandRequest
  shapes : Array[ResolvedShape]
  filters : Array[ShapePair]
  candidate_limit : Int32
  contacts : ContactCapacity
} derive(FromJson)
