///|
pub(all) struct EnvironmentConfig {
  gamma : Double
  eval_mode : Bool
  auto_reset : Bool
  self_collisions : Bool
  randomization : Bool
  reset_noise : Bool
  max_episode_steps : Int32
  physics_dt : Double
  context_resampling : String
} derive(Debug, ToJson, FromJson)

///|
pub fn EnvironmentConfig::default() -> EnvironmentConfig {
  {
    gamma: 0.99,
    eval_mode: false,
    auto_reset: true,
    self_collisions: true,
    randomization: true,
    reset_noise: true,
    max_episode_steps: 500,
    physics_dt: 0.005,
    context_resampling: "episode",
  }
}

///|
pub struct Environment {
  runtimes : Array[@native_physics.Runtime]
  layout : @aligned.JointLayout
  actuator_order : Array[Int32]
  kin : @aligned.Kinematics
  motion : @aligned.MotionLibrary
  config : EnvironmentConfig
  sampler : @aligned.ReturnBinSampler
  rng : @numeric.Rng
  frames : Array[Int32]
  episode_steps : Array[Int32]
  start_bins : Array[Int32]
  previous : Array[Array[Double]]
  xi : Array[Array[Double]]
  initialized : Array[Bool]
  returns : Array[Double]
  discounted : Array[Double]
  substeps : Int32
}

///|
pub fn Environment::inspect(
  self : Environment,
) -> Array[@aligned.CollectorFrame] {
  Array::makei(self.runtimes.length(), i => {
    state: state(self.runtimes[i], self.layout),
    previous: self.previous[i].copy(),
    xi: self.xi[i].copy(),
    frame: self.frames[i],
    episode_step: self.episode_steps[i],
  })
}

///|
pub fn Environment::reset(
  self : Environment,
  ids? : Array[Int32],
  frames? : Array[Int32],
) -> Unit raise {
  let ids = ids.unwrap_or(Array::makei(self.runtimes.length(), i => i))
  let selected = match frames {
    Some(values) => {
      guard values.length() == ids.length() else {
        fail("reset frames differ from environment count")
      }
      values.map(frame => {
        guard frame >= 0 && frame < self.motion.states.length() else {
          fail("reset frame out of motion range")
        }
        let end = self.motion.clip_end[self.motion.clip_id[frame]]
        guard frame < end else {
          fail("reset frame has no remaining transition")
        }
        (frame, self.motion.frame_bin[frame])
      })
    }
    None => self.sampler.sample(ids.length(), () => self.rng.uniform())
  }
  for k, id in ids {
    guard id >= 0 && id < self.runtimes.length() else {
      fail("reset environment index out of range")
    }
    let (frame, bin) = selected[k]
    let mut xi = self.xi[id].copy()
    if self.config.randomization && !self.config.eval_mode {
      let fresh = self.config.context_resampling == "episode" ||
        !self.initialized[id]
      if fresh {
        xi[0] = 0.3 + 0.9 * self.rng.uniform()
        for j in 30..<33 {
          xi[j] = (self.rng.uniform() * 0.1 - 0.05) *
            (if j == 30 { 0.5 } else { 1.0 })
        }
      }
      for j in 1..<30 {
        xi[j] = self.rng.uniform() * 0.02 - 0.01
      }
    } else {
      xi = Array::make(33, 0.0)
      xi[0] = 1.0
    }
    let reference = self.motion.states[frame]
    let mut p = reference.p.copy()
    let mut rotation = reference.rotation.copy()
    let mut v = reference.v.copy()
    let mut w = reference.w.copy()
    let mut q = reference.q.copy()
    if self.config.reset_noise && !self.config.eval_mode {
      p = noisy(self.rng, p, [0.05, 0.05, 0.01])
      rotation = @aligned.mat_mul(
        @aligned.so3_exp(noisy(self.rng, [0.0, 0.0, 0.0], [0.1, 0.1, 0.2])),
        rotation,
      )
      v = noisy(self.rng, v, [0.5, 0.5, 0.2])
      w = noisy(self.rng, w, [0.52, 0.52, 0.78])
      q = noisy(self.rng, q, Array::make(29, 0.1))
    }
    for j in 0..<29 {
      q[j] = q[j].max(self.kin.q_lo[j]).min(self.kin.q_hi[j])
    }
    let root : @aligned.State = { p, rotation, v, w, q, qd: reference.qd, }
    let rt = self.runtimes[id]
    rt.reset_data()
    rt.set_friction(xi[0])
    rt.set_ground_friction(if self.config.eval_mode { 1.0 } else { 0.3 })
    rt.set_torso_com_offset(xi[30:33].to_owned())
    rt.set_state(
      @aligned.mujoco_state(@aligned.flatten_state(root), self.layout),
    )
    rt.set_control(self.actuator_order.map(j => q[j]))
    self.frames[id] = frame
    self.start_bins[id] = bin
    self.episode_steps[id] = 0
    self.previous[id] = Array::make(29, 0.0)
    self.xi[id] = xi
    self.initialized[id] = true
    self.returns[id] = 0.0
    self.discounted[id] = 0.0
  }
}

///|
fn noisy(
  rng : @numeric.Rng,
  x : Array[Double],
  widths : Array[Double],
) -> Array[Double] {
  Array::makei(x.length(), i => x[i] + (2.0 * rng.uniform() - 1.0) * widths[i])
}

///|
pub fn Environment::step(
  self : Environment,
  actions : Array[Array[Double]],
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  scales? : Array[Double],
) -> Array[@aligned.Transition] raise {
  guard actions.length() == self.runtimes.length() else {
    fail("action environment count differs")
  }
  let out : Array[@aligned.Transition] = []
  let finished : Array[Int32] = []
  let episodes : Array[@aligned.CompletedEpisode] = []
  for i, rt in self.runtimes {
    let before = state(rt, self.layout)
    let frame = self.frames[i]
    let ep = self.episode_steps[i]
    let previous = self.previous[i].copy()
    let xi = self.xi[i].copy()
    let setpoint = @aligned.action_to_setpoint(
      actions[i],
      default_q~,
      scales?,
      calibration=xi[1:30].to_owned(),
    )
    ignore(rt.step(self.actuator_order.map(j => setpoint[j]), self.substeps))
    let next = state(rt, self.layout)
    let end = self.motion.clip_end[self.motion.clip_id[frame]]
    let next_frame = (frame + 1).min(end)
    let reward = @aligned.reward(
        self.kin,
        next,
        self.motion.states[next_frame],
        self.motion.bodies[next_frame],
        actions[i],
        previous,
      ).reward
    let terminated = @aligned.termination(next, self.motion.states[next_frame])
    let truncated = next_frame >= end ||
      (!self.config.eval_mode && ep + 1 >= self.config.max_episode_steps)
    out.push({
      s: @aligned.flatten_state(before),
      s1: @aligned.flatten_state(next),
      a: actions[i].copy(),
      a_prev: previous,
      xi,
      r: reward,
      frame,
      ep_step: ep,
      terminated,
      truncated,
    })
    self.frames[i] = next_frame
    self.episode_steps[i] = ep + 1
    self.previous[i] = actions[i].copy()
    self.returns[i] += reward
    self.discounted[i] += @math.pow(self.config.gamma, ep.to_double()) * reward
    if terminated || truncated {
      finished.push(i)
      episodes.push({
        bin: self.start_bins[i],
        discounted_return: self.discounted[i],
        bootstrap: Some((ep + 1, self.returns[i], terminated)),
      })
    }
  }
  if self.config.auto_reset && !finished.is_empty() {
    self.sampler.update(episodes)
    self.reset(ids=finished)
  }
  out
}

///|
pub fn Environment::new(
  runtimes : Array[@native_physics.Runtime],
  motion : @aligned.MotionLibrary,
  config~ : EnvironmentConfig = EnvironmentConfig::default(),
  seed~ : UInt32 = 1U,
) -> Environment raise {
  guard !runtimes.is_empty() &&
    (
      config.context_resampling == "episode" ||
      config.context_resampling == "environment"
    ) else {
    fail("invalid environment count or context resampling")
  }
  guard motion.bodies.length() == motion.states.length() else {
    fail("physical tracking requires reference body features")
  }
  let first = runtimes[0]
  let layout = joint_layout(first)
  guard layout.na == 0 && layout.nq == 36 && layout.nv == 35 else {
    fail("aligned physics requires unactivated 29-DoF free-root G1")
  }
  let kin = kinematics(first)
  let names = @aligned.joint_names()
  let act_names = first.joint_names()
  let actuator_order : Array[Int32] = []
  for act in act_names {
    let mut found = -1
    for j, name in names {
      if name == act {
        found = j
        break
      }
    }
    guard found >= 0 else { fail("unknown G1 joint actuator") }
    actuator_order.push(found)
  }
  guard actuator_order.length() == 29 else {
    fail("G1 physics needs 29 joint actuators")
  }
  for rt in runtimes {
    guard rt.joint_names() == act_names else {
      fail("vector environment models differ")
    }
    rt.set_timestep(config.physics_dt)
    rt.configure_collision(config.self_collisions)
    for name in names {
      let motor = @aligned.motor_of(name)
      rt.configure_joint_actuator(
        name,
        motor.stiffness(),
        motor.damping(),
        motor.effort,
        motor.armature,
      )
    }
  }
  let n = runtimes.length()
  let env : Environment = {
    runtimes,
    layout,
    actuator_order,
    kin,
    motion,
    config,
    sampler: @aligned.ReturnBinSampler::new(motion.bins, gamma=config.gamma),
    rng: @numeric.Rng::new(seed),
    frames: Array::make(n, 0),
    episode_steps: Array::make(n, 0),
    start_bins: Array::make(n, 0),
    previous: Array::makei(n, _ => Array::make(29, 0.0)),
    xi: Array::makei(n, _ => Array::make(33, 0.0)),
    initialized: Array::make(n, false),
    returns: Array::make(n, 0.0),
    discounted: Array::make(n, 0.0),
    substeps: first.control_substeps(0.02),
  }
  env.reset()
  env
}

///|
pub(all) struct EnvironmentSnapshot {
  config : EnvironmentConfig
  physics : Array[Array[Double]]
  frames : Array[Int32]
  episode_steps : Array[Int32]
  start_bins : Array[Int32]
  previous : Array[Array[Double]]
  xi : Array[Array[Double]]
  initialized : Array[Bool]
  returns : Array[Double]
  discounted : Array[Double]
  bin_returns : Array[Double]
  bin_average : Array[Double]
  bin_completed : Array[Int32]
  rng : UInt32
} derive(ToJson, FromJson)

///|
pub fn Environment::snapshot(self : Environment) -> EnvironmentSnapshot {
  let (bin_returns, bin_average, bin_completed) = self.sampler.snapshot()
  {
    config: self.config,
    physics: self.runtimes.map(rt => rt.integration()),
    frames: self.frames.copy(),
    episode_steps: self.episode_steps.copy(),
    start_bins: self.start_bins.copy(),
    previous: self.previous.map(x => x.copy()),
    xi: self.xi.map(x => x.copy()),
    initialized: self.initialized.copy(),
    returns: self.returns.copy(),
    discounted: self.discounted.copy(),
    bin_returns,
    bin_average,
    bin_completed,
    rng: self.rng.state(),
  }
}

///|
pub fn Environment::restore(
  self : Environment,
  saved : EnvironmentSnapshot,
) -> Bool raise {
  let n = self.runtimes.length()
  guard saved.config.to_json() == self.config.to_json() &&
    saved.physics.length() == n &&
    saved.frames.length() == n &&
    saved.episode_steps.length() == n &&
    saved.start_bins.length() == n &&
    saved.previous.length() == n &&
    saved.xi.length() == n &&
    saved.initialized.length() == n &&
    saved.returns.length() == n &&
    saved.discounted.length() == n else {
    fail("incompatible physical environment checkpoint")
  }
  self.sampler.restore(
    saved.bin_returns,
    saved.bin_average,
    saved.bin_completed,
  )
  self.rng.set_state(saved.rng)
  let mut exact = true
  for i, rt in self.runtimes {
    rt.set_friction(saved.xi[i][0])
    rt.set_ground_friction(if self.config.eval_mode { 1.0 } else { 0.3 })
    rt.set_torso_com_offset(saved.xi[i][30:33].to_owned())
    rt.set_integration(saved.physics[i])
    exact = exact && rt.integration() == saved.physics[i]
    self.frames[i] = saved.frames[i]
    self.episode_steps[i] = saved.episode_steps[i]
    self.start_bins[i] = saved.start_bins[i]
    self.previous[i] = saved.previous[i].copy()
    self.xi[i] = saved.xi[i].copy()
    self.initialized[i] = saved.initialized[i]
    self.returns[i] = saved.returns[i]
    self.discounted[i] = saved.discounted[i]
  }
  if !exact {
    self.reset()
  }
  exact
}
