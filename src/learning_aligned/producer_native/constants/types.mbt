///|
/// Host-side constant fragments. No SDK, device state or model is initialized.
pub suberror ConstantsError {
  Invalid(String)
  Unsupported(String)
} derive(Debug)

///|
/// MuJoCo quaternion component order, not Newton's xyzw storage order.
pub(all) struct Quaternion {
  w : Double
  x : Double
  y : Double
  z : Double
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct PrincipalInertia {
  moments : @geometry.Vec3
  orientation : Quaternion
  axes : @geometry.Basis3
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct NewtonBodies {
  mass : Array[Double]
  com : Array[@geometry.Vec3]
  inertia : Array[@geometry.Basis3]
  gravcomp : Array[Double]?
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct BodyConstant {
  mass : Double
  ipos : @geometry.Vec3
  inertia : @geometry.Vec3
  iquat : Quaternion
  gravcomp : Double
} derive(Debug, FromJson, ToJson)

///|
/// Mapping entries -1 retain the existing MuJoCo world/sentinel row.
pub(all) struct BodyUpdate {
  newton : NewtonBodies
  mapping : Array[Array[Int32]]
  existing : Array[Array[BodyConstant]]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct SubtreeRequest {
  parent : Array[Int32]
  body_mass : Array[Array[Double]]
  output_worlds : Int32
} derive(Debug, FromJson, ToJson)

///|
/// M must already be the actual qpos0 mass matrix assembled with authored
/// armature. This package does not assemble M or remove locking by subtraction.
pub(all) struct MeanInertiaRequest {
  nv : Int32
  row_nnz : Array[Int32]
  row_adr : Array[Int32]
  matrix : Array[Array[Double]]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct PairConstant {
  solref : Array[Double]
  solreffriction : Array[Double]
  solimp : Array[Double]
  margin : Double
  gap : Double
  friction : Array[Double]
} derive(Debug, FromJson, ToJson)

///|
/// Each optional source is a flat world-major Newton custom attribute.
pub(all) struct PairOverrides {
  solref : Array[Array[Double]]?
  solreffriction : Array[Array[Double]]?
  solimp : Array[Array[Double]]?
  margin : Array[Double]?
  gap : Array[Double]?
  friction : Array[Array[Double]]?
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct PairUpdate {
  pairs_per_world : Int32
  existing : Array[Array[PairConstant]]
  overrides : PairOverrides
  zero_native_ccd_margins : Bool
} derive(Debug, FromJson, ToJson)

///|
/// Supported analytic geometry kinds exclude mesh/heightfield pose corrections.
pub(all) struct ShapeProperties {
  kind : String
  friction : @geometry.Vec3
  stiffness : Double
  damping : Double
  size : @geometry.Vec3
  pose : @geometry.Transform3
  raw_solref : Array[Double]?
  solref_mode : String
  solimp : Array[Double]?
  solmix : Double?
  margin : Double
  gap : Double
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct GeomConstant {
  friction : @geometry.Vec3
  solref : Array[Double]
  size : @geometry.Vec3
  position : @geometry.Vec3
  orientation : Quaternion
  solimp : Array[Double]
  solmix : Double
  margin : Double
  gap : Double
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct GeomUpdate {
  shapes : Array[ShapeProperties]
  mapping : Array[Array[Int32]]
  existing : Array[Array[GeomConstant]]
  zero_native_ccd_margins : Bool
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct ReferenceRequest {
  qpos : Array[Array[Double]]
  qpos0 : Array[Array[Double]]
} derive(Debug, FromJson, ToJson)

///|
/// Owns only copied host data, never an active solver transaction.
pub struct ReferenceQpos {
  saved : Array[Array[Double]]
  reference : Array[Array[Double]]
}

///|
/// CLI-friendly explicit typed payload; operation names are fixed.
pub(all) struct CommandRequest {
  operation : String
  parameters : Json
} derive(Debug, FromJson, ToJson)

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn vector_finite(value : @geometry.Vec3) -> Bool {
  finite(value.x) && finite(value.y) && finite(value.z)
}

///|
fn values(value : @geometry.Basis3) -> Array[Double] {
  [
    value.xx,
    value.xy,
    value.xz,
    value.yx,
    value.yy,
    value.yz,
    value.zx,
    value.zy,
    value.zz,
  ]
}

///|
fn check_vector(
  value : @geometry.Vec3,
  label : String,
) -> Unit raise ConstantsError {
  guard vector_finite(value) else {
    raise Invalid(label + " must have finite components")
  }
}

///|
fn check_tuple(
  value : Array[Double],
  length : Int32,
  label : String,
) -> Unit raise ConstantsError {
  guard value.length() == length && value.all(finite) else {
    raise Invalid(label + " has wrong width or nonfinite values")
  }
}

///|
fn matrix_copy(value : Array[Array[Double]]) -> Array[Array[Double]] {
  value.map(row => row.copy())
}

///|
fn basis(value : Array[Array[Double]]) -> @geometry.Basis3 {
  {
    xx: value[0][0],
    xy: value[0][1],
    xz: value[0][2],
    yx: value[1][0],
    yy: value[1][1],
    yz: value[1][2],
    zx: value[2][0],
    zy: value[2][1],
    zz: value[2][2],
  }
}

///|
fn quaternion_finite(value : Quaternion) -> Bool {
  finite(value.w) && finite(value.x) && finite(value.y) && finite(value.z)
}
