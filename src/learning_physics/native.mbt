///|
/// GC-owned genuine MuJoCo model and data.
pub type Runtime

///|
pub suberror PhysicsError {
  Invalid(String)
}

///|
#borrow(library, scene)
extern "c" fn open_native(
  library : Bytes,
  scene : Bytes,
  require_servos : Bool,
) -> Runtime = "moonrobo_mj_open"

///|
#borrow(rt)
extern "c" fn error_native(rt : Runtime) -> Bytes = "moonrobo_mj_error"

///|
/// The C header ABI compiled into this executable; zero means the optional
/// MuJoCo headers were unavailable and opening a real runtime will fail.
pub extern "c" fn compiled_mujoco_header_version() -> Int32 = "moonrobo_mj_header_version"

///|
#borrow(rt)
extern "c" fn count_native(rt : Runtime, field : Int32) -> Int32 = "moonrobo_mj_count"

///|
#borrow(rt)
extern "c" fn value_native(
  rt : Runtime,
  field : Int32,
  index : Int32,
) -> Double = "moonrobo_mj_value"

///|
#borrow(rt)
extern "c" fn set_native(
  rt : Runtime,
  field : Int32,
  index : Int32,
  value : Double,
) -> Unit = "moonrobo_mj_set"

///|
#borrow(rt, key)
extern "c" fn reset_native(
  rt : Runtime,
  key : Bytes,
  friction : Double,
  unpowered : Bool,
) -> Int32 = "moonrobo_mj_reset"

///|
#borrow(rt)
extern "c" fn step_native(rt : Runtime, substeps : Int32) -> Unit = "moonrobo_mj_step"

///|
#borrow(rt)
extern "c" fn snapshot_native(rt : Runtime, restore : Bool) -> Unit = "moonrobo_mj_snapshot"

///|
#borrow(rt)
extern "c" fn saved_native(rt : Runtime, restore : Bool) -> Unit = "moonrobo_mj_saved"

///|
#borrow(rt)
extern "c" fn name_native(rt : Runtime, index : Int32) -> Bytes = "moonrobo_mj_name"

///|
pub fn Runtime::open(
  library : String,
  scene : String,
  require_position_servos~ : Bool = true,
) -> Runtime raise PhysicsError {
  let rt = open_native(
    @utf8.encode(library),
    @utf8.encode(scene),
    require_position_servos,
  )
  let message = @utf8.decode_lossy(error_native(rt))
  if message != "" {
    raise Invalid(
      "opening MuJoCo library '" +
      library +
      "' with scene '" +
      scene +
      "': " +
      message,
    )
  }
  rt
}

///|
pub fn Runtime::dimensions(self : Runtime) -> (Int32, Int32, Int32, Int32) {
  (
    count_native(self, 0),
    count_native(self, 1),
    count_native(self, 2),
    count_native(self, 3),
  )
}

///|
pub fn Runtime::joint_names(self : Runtime) -> Array[String] {
  Array::makei(count_native(self, 3), i => {
    @utf8.decode_lossy(name_native(self, i))
  })
}

///|
pub fn Runtime::version(self : Runtime) -> String {
  @utf8.decode_lossy(name_native(self, -1))
}

///|
pub fn Runtime::q_indices(self : Runtime) -> Array[Int32] {
  Array::makei(count_native(self, 3), i => value_native(self, 7, i).to_int())
}

///|
pub fn Runtime::state(self : Runtime) -> Array[Double] {
  let (nq, nv, na, _) = self.dimensions()
  Array::makei(nq + nv + na, i => value_native(self, 0, i))
}

///|
pub fn Runtime::observation(
  self : Runtime,
  previous : Array[Double],
) -> Array[Double] raise PhysicsError {
  let nu = count_native(self, 3)
  if previous.length() != nu {
    raise Invalid("previous setpoint width differs")
  }
  let obs = Array::makei(2 * nu + 6, i => value_native(self, 1, i))
  obs.append(previous)
  obs
}

///|
pub fn Runtime::clip_control(
  self : Runtime,
  target : Array[Double],
) -> Array[Double] raise PhysicsError {
  if target.length() != count_native(self, 3) {
    raise Invalid("action width differs")
  }
  let result : Array[Double] = []
  for i, v in target {
    if v.is_nan() || v.is_inf() {
      raise Invalid("nonfinite action")
    }
    let lower = value_native(self, 2, i)
    let upper = value_native(self, 3, i)
    result.push(if v < lower { lower } else if v > upper { upper } else { v })
  }
  result
}

///|
pub fn Runtime::reset(
  self : Runtime,
  keyframe : String,
  friction : Double,
  unpowered~ : Bool = false,
) -> Unit raise PhysicsError {
  if friction.is_nan() || friction.is_inf() || friction <= 0 {
    raise Invalid("friction must be finite and positive")
  }
  if reset_native(self, @utf8.encode(keyframe), friction, unpowered) != 0 {
    raise Invalid(@utf8.decode_lossy(error_native(self)))
  }
}

///|
pub fn Runtime::save(self : Runtime) -> Unit {
  saved_native(self, false)
}

///|
pub fn Runtime::restore(self : Runtime) -> Unit {
  saved_native(self, true)
}

///|
pub fn Runtime::integration(self : Runtime) -> Array[Double] {
  snapshot_native(self, false)
  Array::makei(count_native(self, 4), i => value_native(self, 8, i))
}

///|
pub fn Runtime::set_integration(
  self : Runtime,
  state : Array[Double],
) -> Unit raise PhysicsError {
  if state.length() != count_native(self, 4) {
    raise Invalid("integration state width differs")
  }
  for i, v in state {
    set_native(self, 3, i, v)
  }
  snapshot_native(self, true)
}

///|
pub fn Runtime::shift_xy(self : Runtime, x : Double, y : Double) -> Unit {
  set_native(self, 2, 0, value_native(self, 0, 0) + x)
  set_native(self, 2, 1, value_native(self, 0, 1) + y)
}

///|
pub fn Runtime::root_height(self : Runtime) -> Double {
  value_native(self, 4, 0)
}

///|
pub fn Runtime::upright(self : Runtime) -> Double {
  value_native(self, 5, 0)
}

///|
pub fn Runtime::contacts(self : Runtime) -> Int32 {
  count_native(self, 5)
}

///|
pub fn Runtime::set_friction(
  self : Runtime,
  friction : Double,
) -> Unit raise PhysicsError {
  if friction.is_nan() || friction.is_inf() || friction <= 0 {
    raise Invalid("friction must be finite and positive")
  }
  set_native(self, 4, 0, friction)
}

///|
pub fn Runtime::control_substeps(
  self : Runtime,
  dt : Double,
) -> Int32 raise PhysicsError {
  let timestep = value_native(self, 6, 0)
  if dt.is_nan() || dt.is_inf() || dt <= 0 || timestep <= 0 {
    raise Invalid("invalid control or physics timestep")
  }
  let steps = @math.round(dt / timestep).to_int()
  if steps < 1 || (steps.to_double() * timestep - dt).abs() > dt.abs() * 1.0e-9 {
    raise Invalid(
      "control period must be a positive multiple of physics timestep",
    )
  }
  steps
}

///|
pub fn Runtime::step(
  self : Runtime,
  action : Array[Double],
  substeps : Int32,
) -> Array[Double] raise PhysicsError {
  if substeps < 1 {
    raise Invalid("substeps must be positive")
  }
  let action = self.clip_control(action)
  for i, v in action {
    set_native(self, 0, i, v)
  }
  step_native(self, substeps)
  let state = self.state()
  if state.any(v => v.is_nan() || v.is_inf()) {
    raise Invalid("nonfinite simulator state")
  }
  state
}

///|
pub fn Runtime::v_indices(self : Runtime) -> Array[Int32] {
  Array::makei(count_native(self, 3), i => value_native(self, 9, i).to_int())
}

///|
pub fn Runtime::control_bounds(
  self : Runtime,
) -> (Array[Double], Array[Double]) {
  (
    Array::makei(count_native(self, 3), i => value_native(self, 2, i)),
    Array::makei(count_native(self, 3), i => value_native(self, 3, i)),
  )
}

///|
pub fn Runtime::body_count(self : Runtime) -> Int32 {
  count_native(self, 6)
}

///|
pub fn Runtime::joint_count(self : Runtime) -> Int32 {
  count_native(self, 7)
}

///|
fn Runtime::check_body(self : Runtime, id : Int32) -> Unit raise PhysicsError {
  if id < 0 || id >= self.body_count() {
    raise Invalid("body index out of range")
  }
}

///|
fn Runtime::check_joint(self : Runtime, id : Int32) -> Unit raise PhysicsError {
  if id < 0 || id >= self.joint_count() {
    raise Invalid("joint index out of range")
  }
}

///|
pub fn Runtime::body_name(
  self : Runtime,
  id : Int32,
) -> String raise PhysicsError {
  self.check_body(id)
  @utf8.decode_lossy(name_native(self, 1000000 + id))
}

///|
pub fn Runtime::body_parent(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_body(id)
  value_native(self, 10, id).to_int()
}

///|
pub fn Runtime::body_joint_count(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_body(id)
  value_native(self, 11, id).to_int()
}

///|
pub fn Runtime::body_joint_ids(
  self : Runtime,
  id : Int32,
) -> Array[Int32] raise PhysicsError {
  let count = self.body_joint_count(id)
  let first = value_native(self, 12, id).to_int()
  Array::makei(count, i => first + i)
}

///|
pub fn Runtime::body_offset_pos(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(3, i => value_native(self, 13, id * 3 + i))
}

///|
pub fn Runtime::body_offset_quat(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(4, i => value_native(self, 14, id * 4 + i))
}

///|
pub fn Runtime::body_world_pos(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(3, i => value_native(self, 22, id * 3 + i))
}

///|
pub fn Runtime::body_world_quat(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(4, i => value_native(self, 23, id * 4 + i))
}

///|
pub fn Runtime::joint_name(
  self : Runtime,
  id : Int32,
) -> String raise PhysicsError {
  self.check_joint(id)
  @utf8.decode_lossy(name_native(self, 2000000 + id))
}

///|
pub fn Runtime::joint_type(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_joint(id)
  value_native(self, 15, id).to_int()
}

///|
pub fn Runtime::joint_qref(
  self : Runtime,
  id : Int32,
) -> Double raise PhysicsError {
  self.check_joint(id)
  value_native(self, 16, id)
}

///|
pub fn Runtime::joint_axis(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_joint(id)
  Array::makei(3, i => value_native(self, 17, id * 3 + i))
}

///|
pub fn Runtime::joint_pivot(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_joint(id)
  Array::makei(3, i => value_native(self, 18, id * 3 + i))
}

///|
pub fn Runtime::joint_limits(
  self : Runtime,
  id : Int32,
) -> (Double, Double) raise PhysicsError {
  self.check_joint(id)
  (value_native(self, 19, id * 2), value_native(self, 19, id * 2 + 1))
}

///|
pub fn Runtime::joint_qpos_address(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_joint(id)
  value_native(self, 20, id).to_int()
}

///|
pub fn Runtime::joint_velocity_address(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_joint(id)
  value_native(self, 21, id).to_int()
}

///|
/// Set qpos/qvel/activation together, then recompute MuJoCo derived quantities.
pub fn Runtime::set_state(
  self : Runtime,
  state : Array[Double],
) -> Unit raise PhysicsError {
  let (nq, nv, na, _) = self.dimensions()
  if state.length() != nq + nv + na || state.any(v => v.is_nan() || v.is_inf()) {
    raise Invalid("invalid state width or nonfinite state")
  }
  for i, v in state {
    set_native(self, 5, i, v)
  }
  step_native(self, 0)
}

///|
pub fn Runtime::configure_joint_actuator(
  self : Runtime,
  joint_name : String,
  kp : Double,
  kd : Double,
  effort : Double,
  armature : Double,
) -> Unit raise PhysicsError {
  let names = self.joint_names()
  let mut aid = -1
  for i, name in names {
    if name == joint_name {
      aid = i
      break
    }
  }
  if aid < 0 {
    raise Invalid("joint has no actuator: " + joint_name)
  }
  if [kp, kd, effort, armature].any(v => v.is_nan() || v.is_inf() || v < 0) ||
    effort == 0 {
    raise Invalid("invalid actuator configuration")
  }
  set_native(self, 6, aid, kp)
  set_native(self, 7, aid, kd)
  set_native(self, 8, aid, effort)
  set_native(self, 9, aid, armature)
}

///|
pub fn Runtime::set_timestep(
  self : Runtime,
  dt : Double,
) -> Unit raise PhysicsError {
  if dt.is_nan() || dt.is_inf() || dt <= 0 {
    raise Invalid("invalid physics timestep")
  }
  set_native(self, 10, 0, dt)
}

///|
pub fn Runtime::configure_collision(
  self : Runtime,
  self_collisions : Bool,
) -> Unit {
  set_native(self, 11, 0, if self_collisions { 1.0 } else { 0.0 })
}

///|
pub fn Runtime::set_ground_friction(
  self : Runtime,
  friction : Double,
) -> Unit raise PhysicsError {
  if friction.is_nan() || friction.is_inf() || friction <= 0 {
    raise Invalid("invalid ground friction")
  }
  set_native(self, 12, 0, friction)
}

///|
/// Offset is always relative to the model's original inertial position.
pub fn Runtime::set_torso_com_offset(
  self : Runtime,
  offset : Array[Double],
  body_name~ : String = "torso_link",
) -> Unit raise PhysicsError {
  if offset.length() != 3 || offset.any(v => v.is_nan() || v.is_inf()) {
    raise Invalid("invalid COM offset")
  }
  let mut body = -1
  for i in 0..<self.body_count() {
    if self.body_name(i) == body_name {
      body = i
      break
    }
  }
  if body < 0 {
    raise Invalid("missing torso body: " + body_name)
  }
  for i, v in offset {
    set_native(self, 13, body * 3 + i, v)
  }
}

///|
pub fn Runtime::reset_data(self : Runtime) -> Unit {
  step_native(self, -1)
}

///|
pub fn Runtime::set_control(
  self : Runtime,
  action : Array[Double],
) -> Unit raise PhysicsError {
  let applied = self.clip_control(action)
  for i, v in applied {
    set_native(self, 0, i, v)
  }
}

///|
pub fn Runtime::root_body(self : Runtime) -> Int32 {
  value_native(self, 33, 0).to_int()
}

///|
pub fn Runtime::body_mass(
  self : Runtime,
  id : Int32,
) -> Double raise PhysicsError {
  self.check_body(id)
  value_native(self, 24, id)
}

///|
pub fn Runtime::body_inertial_pos(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(3, i => value_native(self, 25, id * 3 + i))
}

///|
pub fn Runtime::body_mocap_id(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_body(id)
  value_native(self, 26, id).to_int()
}

///|
pub fn Runtime::site_count(self : Runtime) -> Int32 {
  count_native(self, 8)
}

///|
fn Runtime::check_site(self : Runtime, id : Int32) -> Unit raise PhysicsError {
  if id < 0 || id >= self.site_count() {
    raise Invalid("site index out of range")
  }
}

///|
pub fn Runtime::site_name(
  self : Runtime,
  id : Int32,
) -> String raise PhysicsError {
  self.check_site(id)
  @utf8.decode_lossy(name_native(self, 3000000 + id))
}

///|
pub fn Runtime::site_body(
  self : Runtime,
  id : Int32,
) -> Int32 raise PhysicsError {
  self.check_site(id)
  value_native(self, 27, id).to_int()
}

///|
pub fn Runtime::site_local_pos(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_site(id)
  Array::makei(3, i => value_native(self, 28, id * 3 + i))
}

///|
pub fn Runtime::site_world_pos(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_site(id)
  Array::makei(3, i => value_native(self, 29, id * 3 + i))
}

///|
pub fn Runtime::subtree_com(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  Array::makei(3, i => value_native(self, 30, id * 3 + i))
}

///|
pub fn Runtime::qfrc_bias(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 1), i => value_native(self, 31, i))
}

///|
/// Applied generalized forces, copied directly from mjData.qfrc_applied.
pub fn Runtime::qfrc_applied(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 1), i => value_native(self, 44, i))
}

///|
pub fn Runtime::actuator_gain(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 3), i => value_native(self, 32, i))
}

///|
/// Declared actuator damping, in actuator order: -actuator_biasprm[:, 2].
pub fn Runtime::actuator_damping(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 3), i => value_native(self, 39, i))
}

///|
/// Declared model force-range endpoints, including for actuators not force-limited.
pub fn Runtime::actuator_force_bounds(
  self : Runtime,
) -> (Array[Double], Array[Double]) {
  (
    Array::makei(count_native(self, 3), i => value_native(self, 40, i)),
    Array::makei(count_native(self, 3), i => value_native(self, 41, i)),
  )
}

///|
/// Joint DoF armatures in actuator-joint order (not model joint order).
pub fn Runtime::joint_armatures(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 3), i => value_native(self, 42, i))
}

///|
/// Actual model sliding, torsional, and rolling friction for a named geom.
/// Missing or unnamed geoms raise instead of selecting a default floor.
pub fn Runtime::geom_friction(
  self : Runtime,
  name : String,
) -> Array[Double] raise PhysicsError {
  if name != "" {
    for id in 0..<count_native(self, 9) {
      if @utf8.decode_lossy(name_native(self, 4000000 + id)) == name {
        return Array::makei(3, i => value_native(self, 43, 3 * id + i))
      }
    }
  }
  raise Invalid("missing geom: " + name)
}

///|
/// Translational Jacobian of a world-space point, rows x/y/z and nv columns.
pub fn Runtime::point_jacobian(
  self : Runtime,
  point : Array[Double],
  body : Int32,
) -> Array[Array[Double]] raise PhysicsError {
  self.check_body(body)
  if point.length() != 3 || point.any(v => v.is_nan() || v.is_inf()) {
    raise Invalid("invalid Jacobian point")
  }
  for i, v in point {
    set_native(self, 14, i, v)
  }
  set_native(self, 15, body, 0)
  let nv = count_native(self, 1)
  Array::makei(3, row => {
    Array::makei(nv, i => value_native(self, 34, row * nv + i))
  })
}

///|
#borrow(library, source, output)
extern "c" fn compile_native(
  library : Bytes,
  source : Bytes,
  output : Bytes,
) -> Bytes = "moonrobo_mj_compile"

///|
/// Compile arbitrary URDF/MJCF using real MuJoCo, without runtime model restrictions.
pub fn compile_xml_to_mjcf(
  library : String,
  source : String,
  output : String,
) -> String raise PhysicsError {
  let result = @utf8.decode_lossy(
    compile_native(
      @utf8.encode(library),
      @utf8.encode(source),
      @utf8.encode(output),
    ),
  )
  if result.has_prefix("error: ") {
    raise Invalid(result)
  }
  result
}

///|
pub fn Runtime::gravity(self : Runtime) -> Array[Double] {
  Array::makei(3, i => value_native(self, 35, i))
}

///|
/// Reconstruct recorded qpos/qvel/act, normalize with mj_normalizeQuat, apply
/// control and run mj_forward without advancing simulation time.
pub fn Runtime::set_recorded_state(
  self : Runtime,
  state : Array[Double],
  action : Array[Double],
) -> Unit raise PhysicsError {
  self.set_state(state)
  self.set_control(action)
  step_native(self, -2)
}

///|
pub fn Runtime::body_positions(
  self : Runtime,
  include_world~ : Bool = true,
) -> Array[Array[Double]] {
  let first = if include_world { 0 } else { 1 }
  Array::makei(self.body_count() - first, i => {
    try! self.body_world_pos(first + i)
  })
}

///|
/// Each body rotation is row-major length 9, from MuJoCo data.xmat.
pub fn Runtime::body_rotations(
  self : Runtime,
  include_world~ : Bool = true,
) -> Array[Array[Double]] {
  let first = if include_world { 0 } else { 1 }
  Array::makei(self.body_count() - first, body => {
    Array::makei(9, i => value_native(self, 36, (body + first) * 9 + i))
  })
}

///|
pub fn Runtime::root_body_index(self : Runtime) -> Int32 {
  self.root_body()
}

///|
/// mj_objectVelocity BODY in world axes, angular xyz followed by linear xyz.
pub fn Runtime::body_object_velocity_world(
  self : Runtime,
  id : Int32,
) -> Array[Double] raise PhysicsError {
  self.check_body(id)
  set_native(self, 16, id, 0)
  Array::makei(6, i => value_native(self, 37, i))
}

///|
pub fn Runtime::actuator_force(self : Runtime) -> Array[Double] {
  Array::makei(count_native(self, 3), i => value_native(self, 38, i))
}

///|
/// Return model disable flags to the loaded scene's defaults before policy probes.
pub fn Runtime::restore_disable_flags(self : Runtime) -> Unit {
  set_native(self, 17, 0, 0.0)
}

///|
#borrow(rt)
extern "c" fn floor_distance_native(rt : Runtime, body : Int32) -> Double = "moonrobo_mj_floor_distance"

///|
#borrow(rt)
extern "c" fn self_penetration_native(rt : Runtime) -> Double = "moonrobo_mj_self_penetration"

///|
/// Minimum signed distance from this body's collision geoms to world planes.
pub fn Runtime::body_floor_distance(
  self : Runtime,
  body : Int32,
) -> Double raise PhysicsError {
  self.check_body(body)
  let value = floor_distance_native(self, body)
  guard !value.is_nan() && !value.is_inf() else {
    raise Invalid(
      "body has no collision geometry/ground plane or geomDistance is unavailable",
    )
  }
  value
}

///|
/// Deepest active non-ground contact penetration after forward kinematics.
pub fn Runtime::self_penetration(self : Runtime) -> Double {
  self_penetration_native(self)
}

///|
/// Body names for the deepest active self contact; world/world means none.
pub fn Runtime::self_contact_bodies(
  self : Runtime,
) -> Array[String] raise PhysicsError {
  Array::makei(2, i => self.body_name(value_native(self, 45, i).to_int()))
}

///|
pub(all) struct Contact {
  body_a : Int32
  body_b : Int32
  point : Array[Double]
  normal_a_to_b : Array[Double]
  distance : Double
}

///|
/// Active rigid collision contacts, in world coordinates, including the floor.
pub fn Runtime::collision_contacts(self : Runtime) -> Array[Contact] {
  Array::makei(self.contacts(), i => {
    body_a: value_native(self, 46, i * 9).to_int(),
    body_b: value_native(self, 46, i * 9 + 1).to_int(),
    point: Array::makei(3, k => value_native(self, 46, i * 9 + 2 + k)),
    normal_a_to_b: Array::makei(3, k => value_native(self, 46, i * 9 + 5 + k)),
    distance: value_native(self, 46, i * 9 + 8),
  })
}

///|
#borrow(rt)
extern "c" fn body_box_native(
  rt : Runtime,
  body : Int32,
  field : Int32,
) -> Double = "moonrobo_mj_body_box"

///|
/// Collision box local center and half sizes. Fails for multiple geoms,
/// non-box geometry or a rotated local box rather than assuming a sole shape.
pub fn Runtime::body_box(
  self : Runtime,
  body : Int32,
) -> (Array[Double], Array[Double]) raise PhysicsError {
  self.check_body(body)
  let values = Array::makei(6, k => body_box_native(self, body, k))
  guard values.all(v => !v.is_nan() && !v.is_inf()) else {
    raise Invalid("body must have one axis-aligned collision box")
  }
  (values[:3].to_owned(), values[3:].to_owned())
}
