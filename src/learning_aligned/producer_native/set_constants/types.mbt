///|
/// An actual host rigid-body reference calculation, never a device transaction.
pub suberror SetConstantsError {
  Invalid(String)
  Unsupported(String)
} derive(Debug)

///|
/// Explicit MuJoCo coordinates: hinge/slide have one qpos/DOF; free uses
/// world translation plus wxyz qpos and world-linear/body-local angular qvel.
pub(all) struct Joint {
  kind : String
  qpos_adr : Int32
  dof_adr : Int32
  anchor : @geometry.Vec3
  axis : @geometry.Vec3
} derive(Debug, FromJson, ToJson)

///|
/// Pose is the authored parent-to-body transform. Inertia is expressed in
/// the body frame around com; it is not the inertia around the body origin.
pub(all) struct Body {
  parent : Int32
  pose : @geometry.Transform3
  mass : Double
  com : @geometry.Vec3
  inertia : @geometry.Basis3
  joint : Joint?
} derive(Debug, FromJson, ToJson)

///|
/// Armature is authored physical armature, with no kinematic locking term.
pub(all) struct RigidModel {
  bodies : Array[Body]
  armature : Array[Double]
} derive(Debug, FromJson, ToJson)

///|
/// Tendon armature, flex, mocap and locked-kinematic bodies affect the core
/// calculation and are refused. Other feature constants are explicitly omitted.
pub(all) struct FeatureCounts {
  tendons : Int32
  flex : Int32
  mocap_bodies : Int32
  kinematic_bodies : Int32
  equalities : Int32
  cameras : Int32
  lights : Int32
  actuators : Int32
} derive(Debug, FromJson, ToJson)

///|
/// Models are shared (one) or one per world, permitting actual randomized
/// body mass/COM/inertia. qpos0 is also the hinge/slide reference coordinate.
pub(all) struct CommandRequest {
  models : Array[RigidModel]
  qpos0 : Array[Array[Double]]
  current_qpos : Array[Array[Double]]
  features : FeatureCounts
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct BodyInverseWeight {
  translation : Double
  rotation : Double
} derive(Debug, FromJson, ToJson)

///|
/// Actual computed rigid-body reference outputs. Arrays are owned results.
pub(all) struct WorldConstants {
  body_pose : Array[@geometry.Transform3]
  body_com : Array[@geometry.Vec3]
  body_world_inertia : Array[@geometry.Basis3]
  subtree_mass : Array[Double]
  subtree_com : Array[@geometry.Vec3]
  subtree_inertia_about_com : Array[@geometry.Basis3]
  mass_matrix : Array[Array[Double]]
  inverse_mass_matrix : Array[Array[Double]]
  dof_invweight0 : Array[Double]
  body_invweight0 : Array[BodyInverseWeight]
  mean_inertia : Double
} derive(Debug, FromJson, ToJson)

///|
struct ModelLayout {
  nq : Int32
  nv : Int32
  physical_inertia : Array[@geometry.Basis3]
}

///|
struct Kinematics {
  pose : Array[@geometry.Transform3]
  com : Array[@geometry.Vec3]
  world_inertia : Array[@geometry.Basis3]
  dof_axis : Array[@geometry.Vec3]
  dof_origin : Array[@geometry.Vec3]
  dof_rotational : Array[Bool]
}

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn vector_ok(value : @geometry.Vec3) -> Bool {
  finite(value.x) && finite(value.y) && finite(value.z)
}

///|
fn zero() -> @geometry.Vec3 {
  @geometry.vec3(0.0, 0.0, 0.0)
}

///|
fn basis_values(value : @geometry.Basis3) -> Array[Double] {
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
fn zero_basis() -> @geometry.Basis3 {
  {
    xx: 0.0,
    xy: 0.0,
    xz: 0.0,
    yx: 0.0,
    yy: 0.0,
    yz: 0.0,
    zx: 0.0,
    zy: 0.0,
    zz: 0.0,
  }
}

///|
fn transpose(value : @geometry.Basis3) -> @geometry.Basis3 {
  {
    xx: value.xx,
    xy: value.yx,
    xz: value.zx,
    yx: value.xy,
    yy: value.yy,
    yz: value.zy,
    zx: value.xz,
    zy: value.yz,
    zz: value.zz,
  }
}

///|
fn diagonal(value : @geometry.Vec3) -> @geometry.Basis3 {
  { ..zero_basis(), xx: value.x, yy: value.y, zz: value.z, }
}

///|
fn add_basis(a : @geometry.Basis3, b : @geometry.Basis3) -> @geometry.Basis3 {
  {
    xx: a.xx + b.xx,
    xy: a.xy + b.xy,
    xz: a.xz + b.xz,
    yx: a.yx + b.yx,
    yy: a.yy + b.yy,
    yz: a.yz + b.yz,
    zx: a.zx + b.zx,
    zy: a.zy + b.zy,
    zz: a.zz + b.zz,
  }
}

///|
/// Parallel-axis term m * (|offset|² I - offset offsetᵀ).
fn parallel_axis(mass : Double, d : @geometry.Vec3) -> @geometry.Basis3 {
  {
    xx: mass * (d.y * d.y + d.z * d.z),
    xy: -mass * d.x * d.y,
    xz: -mass * d.x * d.z,
    yx: -mass * d.y * d.x,
    yy: mass * (d.x * d.x + d.z * d.z),
    yz: -mass * d.y * d.z,
    zx: -mass * d.z * d.x,
    zy: -mass * d.z * d.y,
    zz: mass * (d.x * d.x + d.y * d.y),
  }
}
