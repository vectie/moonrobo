///|
pub struct NativeBalanceTeacher {
  runtime : @native_physics.Runtime
  kernel : @balance.BalanceTeacher
  parameters : @balance.FeedbackParameters
  foot_sites : Array[Int32]
}

///|
pub fn NativeBalanceTeacher::new(
  runtime : @native_physics.Runtime,
  parameters : @balance.FeedbackParameters,
  dt : Double,
) -> NativeBalanceTeacher raise {
  let foot_sites : Array[Int32] = []
  for name in ["left_foot", "right_foot"] {
    let mut found = -1
    for site in 0..<runtime.site_count() {
      if runtime.site_name(site) == name {
        found = site
      }
    }
    guard found >= 0 else {
      fail("balance teacher missing support site: " + name)
    }
    foot_sites.push(found)
  }
  {
    runtime,
    kernel: @balance.BalanceTeacher::new(runtime.joint_names(), parameters, dt),
    parameters,
    foot_sites,
  }
}

///|
pub fn NativeBalanceTeacher::measurements(
  self : NativeBalanceTeacher,
) -> (Array[Double], Array[Array[Double]], Array[Double]) raise {
  let root = self.runtime.root_body()
  let rotation = @balance.quaternion_matrix(self.runtime.body_world_quat(root))
  let feet = self.foot_sites.map(fn(site) { self.runtime.site_world_pos(site) })
  (rotation, feet, self.runtime.subtree_com(root))
}

///|
pub fn NativeBalanceTeacher::memory(
  self : NativeBalanceTeacher,
) -> (Array[Double]?, Array[Double]) {
  self.kernel.memory()
}

///|
pub fn NativeBalanceTeacher::set_memory(
  self : NativeBalanceTeacher,
  last : Array[Double]?,
  velocity : Array[Double],
) -> Unit {
  self.kernel.set_memory(last, velocity)
}

///|
pub fn NativeBalanceTeacher::predict(
  self : NativeBalanceTeacher,
  _observation : Array[Double],
  goal : Array[Double],
) -> Array[Double] raise {
  let runtime = self.runtime
  let (rotation, feet, com) = self.measurements()
  let (nq, _, _, nu) = runtime.dimensions()
  let state = runtime.state()
  let v_indices = runtime.v_indices()
  let joint_speed = v_indices.map(fn(i) { state[nq + i] })
  let correction = Array::make(nu, 0.0)
  if self.parameters.support_gain != 0.0 {
    let cop = @balance.clip(
      com[0],
      (feet[0][0] + feet[1][0]) / 2.0 - 0.04,
      (feet[0][0] + feet[1][0]) / 2.0 + 0.04,
    )
    let jacobian = Array::makei(2, fn(i) {
      let point = feet[i].copy()
      point[0] = cop
      runtime.point_jacobian(point, runtime.site_body(self.foot_sites[i]))[2]
    })
    // The vertical support weight equals the subtree mass times world gravity magnitude.
    let mut mass = 0.0
    let selected : Map[Int32, Bool] = {}
    selected[runtime.root_body()] = true
    for body in runtime.root_body()..<runtime.body_count() {
      if body == runtime.root_body() ||
        selected.contains(runtime.body_parent(body)) {
        selected[body] = true
        mass += runtime.body_mass(body)
      }
    }
    let torque = @balance.support_torque(
      com,
      feet,
      mass * -runtime.gravity()[2],
      jacobian,
      runtime.qfrc_bias(),
    )
    let gains = runtime.actuator_gain()
    for i in 0..<nu {
      guard gains[i] != 0.0 else { fail("zero actuator proportional gain") }
      correction[i] = torque[v_indices[i]] / gains[i]
    }
  }
  let (lower, upper) = runtime.control_bounds()
  self.kernel.predict(
    rotation,
    com,
    feet,
    joint_speed,
    [state[nq + 3], state[nq + 4], state[nq + 5]],
    correction,
    goal,
    lower,
    upper,
  )
}

///|
pub fn evaluate_teacher(
  runtime : @native_physics.Runtime,
  cases : Array[@native_physics.Case],
  seeds : Array[Int32],
  parameters : @balance.FeedbackParameters,
  seconds : Double,
  dt : Double,
  _rng : @numeric.Rng,
) -> (Json, Array[@native_physics.Episode], Array[@native_physics.Trial]) raise {
  let episodes : Array[@native_physics.Episode] = []
  let trials : Array[@native_physics.Trial] = []
  for case in cases {
    for seed in seeds {
      let teacher = NativeBalanceTeacher::new(runtime, parameters, dt)
      let reset_rng = @numeric.Rng::new(seed.reinterpret_as_uint())
      let (episode, trial) = runtime.rollout(
        case,
        seed,
        "policy",
        seconds,
        dt,
        fn() { reset_rng.normal() },
        policy=fn(obs, goal) { try! teacher.predict(obs, goal) },
      )
      episodes.push(episode)
      trials.push(trial)
    }
  }
  (
    @balance.summarize_recorded_trials(trials.map(fn(t) { t.to_json() })),
    episodes,
    trials,
  )
}

///|
fn parameter_number(
  value : Json,
  key : String,
  fallback : Double?,
) -> Double raise {
  guard value is Object(fields) else {
    fail("teacher parameters must be an object")
  }
  match fields.get(key) {
    Some(Number(number, ..)) => {
      guard @numeric.finite(number) else { fail("nonfinite teacher parameter") }
      number
    }
    None =>
      match fallback {
        Some(number) => number
        None => fail("missing teacher parameter: " + key)
      }
    _ => fail("teacher parameter must be numeric: " + key)
  }
}

///|
/// Accept the original Python teacher.json parameter field names, including optional hip/waist/support gains.
pub fn parameters_from_json(value : Json) -> @balance.FeedbackParameters raise {
  let dynamic = match value {
    Object(fields) =>
      match fields.get("waist_dynamic_only") {
        Some(True) => true
        Some(False) | None => false
        _ => fail("waist_dynamic_only must be boolean")
      }
    _ => fail("teacher parameters must be an object")
  }
  {
    angle_gain: parameter_number(value, "angle_gain", None),
    rate_gain: parameter_number(value, "rate_gain", None),
    com_gain: parameter_number(value, "com_gain", None),
    velocity_gain: parameter_number(value, "velocity_gain", None),
    pitch_bias: parameter_number(value, "pitch_bias_rad", None),
    joint_damping: parameter_number(value, "joint_damping", Some(0.0)),
    residual_bound: parameter_number(value, "residual_bound_rad", None),
    hip_share: parameter_number(value, "hip_share", Some(0.0)),
    waist_share: parameter_number(value, "waist_share", Some(0.0)),
    waist_dynamic_only: dynamic,
    support_gain: parameter_number(value, "support_gain", Some(0.0)),
  }
}
