///|
pub struct Environment {
  runtimes : Array[@sim.Runtime]
  layouts : Array[@aligned.JointLayout]
  profile : Profile
  kin : @aligned.Kinematics
  motion : @aligned.MotionLibrary
  config : @tracking.EnvironmentConfig
  atlas_reward : Bool
  rng : @numeric.Rng
  sampler : @aligned.ReturnBinSampler
  frames : Array[Int32]
  steps : Array[Int32]
  bins : Array[Int32]
  previous : Array[Array[Double]]
  xi : Array[Array[Double]]
  returns : Array[Double]
  discounted : Array[Double]
}

///|
pub fn Environment::new(
  runtimes : Array[@sim.Runtime],
  robot : Profile,
  motion : @aligned.MotionLibrary,
  config~ : @tracking.EnvironmentConfig = @tracking.EnvironmentConfig::default(),
  seed~ : UInt32 = 1U,
  atlas_reward~ : Bool = false,
) -> Environment raise {
  guard !runtimes.is_empty() && runtimes.length() <= 128 else {
    fail("E1 supports 1..128 CPU physical environments")
  }
  let kin = @tracking.kinematics(
    runtimes[0],
    names=robot.joints,
    tracked_names=robot.tracked,
    root_name="base_link",
  )
  let layouts = []
  for rt in runtimes {
    let n = robot.joints.length()
    let (nq, nv, na, nu) = rt.dimensions()
    guard nq == n + 7 &&
      nv == n + 6 &&
      na == 0 &&
      nu == n &&
      rt.joint_names() == robot.joints else {
      fail(
        "E1 scene dimensions/actuator order differ from selected physical profile",
      )
    }
    rt.set_timestep(config.physics_dt)
    rt.configure_collision(config.self_collisions)
    for i, name in robot.joints {
      rt.configure_joint_actuator(
        name,
        robot.stiffness[i],
        robot.damping[i],
        robot.effort[i],
        robot.armature[i],
      )
    }
    layouts.push(@tracking.joint_layout(rt, names=robot.joints))
  }
  let n = runtimes.length()
  let result : Environment = {
    runtimes,
    layouts,
    profile: robot,
    kin,
    motion,
    config,
    atlas_reward,
    rng: @numeric.Rng::new(seed),
    sampler: @aligned.ReturnBinSampler::new(motion.bins, gamma=config.gamma),
    frames: Array::make(n, 0),
    steps: Array::make(n, 0),
    bins: Array::make(n, 0),
    previous: Array::makei(n, _ => Array::make(29, 0.0)),
    xi: Array::makei(n, _ => Array::make(33, 0.0)),
    returns: Array::make(n, 0.0),
    discounted: Array::make(n, 0.0),
  }
  result.reset()
  result
}

///|
pub fn Environment::inspect(
  self : Environment,
) -> Array[@aligned.CollectorFrame] {
  Array::makei(self.runtimes.length(), i => {
    let s = @tracking.state(self.runtimes[i], self.layouts[i])
    let state = {
      ..s,
      q: Array::makei(29, j => s.q.get(j).unwrap_or(0.0)),
      qd: Array::makei(29, j => s.qd.get(j).unwrap_or(0.0)),
    }
    {
      state,
      previous: self.previous[i].copy(),
      xi: self.xi[i].copy(),
      frame: self.frames[i],
      episode_step: self.steps[i],
    }
  })
}

///|
pub fn Environment::reset(
  self : Environment,
  ids? : Array[Int32],
  frame? : Int32,
) -> Unit raise {
  let ids = ids.unwrap_or(Array::makei(self.runtimes.length(), i => i))
  let selected = match frame {
    Some(f) => {
      guard f >= 0 &&
        f < self.motion.states.length() &&
        f < self.motion.clip_end[self.motion.clip_id[f]] else {
        fail("E1 reset requires a valid non-final reference frame")
      }
      Array::make(ids.length(), (f, self.motion.frame_bin[f]))
    }
    None => self.sampler.sample(ids.length(), () => self.rng.uniform())
  }
  for k, id in ids {
    guard id >= 0 && id < self.runtimes.length() else {
      fail("E1 environment index out of range")
    }
    let (f, bin) = selected[k]
    let s = self.motion.states[f]
    let q = s.q.copy()
    let xi = Array::make(33, 0.0)
    xi[0] = if self.config.randomization && !self.config.eval_mode {
      0.3 + 0.9 * self.rng.uniform()
    } else {
      1.0
    }
    for j in 0..<self.profile.joints.length() {
      if self.config.randomization && !self.config.eval_mode {
        xi[j + 1] = 0.02 * self.rng.uniform() - 0.01
      }
      if self.config.reset_noise && !self.config.eval_mode {
        q[j] += 0.2 * self.rng.uniform() - 0.1
      }
      q[j] = q[j].max(self.kin.q_lo[j]).min(self.kin.q_hi[j])
    }
    let layout = self.layouts[id]
    let raw = Array::make(layout.nq + layout.nv, 0.0)
    let quaternion = @aligned.mat_to_quat(s.rotation)
    for j in 0..<3 {
      raw[j] = s.p[j]
      raw[layout.nq + j] = s.v[j]
    }
    for j in 0..<4 {
      raw[j + 3] = quaternion[j]
    }
    let omega = @aligned.mat_vec(@aligned.transpose(s.rotation), s.w)
    for j in 0..<3 {
      raw[layout.nq + 3 + j] = omega[j]
    }
    for j in 0..<self.profile.joints.length() {
      raw[layout.qpos_addresses[j]] = q[j]
      raw[layout.nq + layout.qvel_addresses[j]] = s.qd[j]
    }
    let rt = self.runtimes[id]
    rt.reset_data()
    rt.set_friction(xi[0])
    rt.set_ground_friction(1.0)
    rt.set_state(raw)
    rt.set_control(q[:self.profile.joints.length()].to_owned())
    self.xi[id] = xi
    self.previous[id] = Array::make(29, 0.0)
    self.frames[id] = f
    self.bins[id] = bin
    self.steps[id] = 0
    self.returns[id] = 0.0
    self.discounted[id] = 0.0
  }
}

///|
pub fn Environment::step(
  self : Environment,
  actions : Array[Array[Double]],
) -> Array[@aligned.Transition] raise {
  guard actions.length() == self.runtimes.length() else {
    fail("E1 action batch count differs")
  }
  let before = self.inspect()
  let masked = actions.map(a => self.profile.project(a))
  for i, rt in self.runtimes {
    let q = Array::makei(self.profile.joints.length(), j => {
      self.profile.default_q[j] +
      self.profile.scales[j] * masked[i][j] +
      self.xi[i][j + 1]
    })
    guard q.all(@numeric.finite) else { fail("nonfinite E1 setpoint") }
    ignore(rt.step(q, rt.control_substeps(0.02)))
  }
  let after = self.inspect()
  let transitions : Array[@aligned.Transition] = []
  let completed : Array[@aligned.CompletedEpisode] = []
  let ids = []
  for i, frame in before {
    let last = self.motion.clip_end[self.motion.clip_id[frame.frame]]
    let next_frame = (frame.frame + 1).min(last)
    let state = after[i].state
    let reward = @aligned.reward(
        self.kin,
        state,
        self.motion.states[next_frame],
        self.motion.bodies[next_frame],
        masked[i],
        frame.previous,
        atlas=self.atlas_reward,
      ).reward
    let terminated = @aligned.termination(state, self.motion.states[next_frame])
    let truncated = next_frame == last ||
      (
        !self.config.eval_mode &&
        frame.episode_step + 1 >= self.config.max_episode_steps
      )
    transitions.push({
      s: @aligned.flatten_state(frame.state),
      s1: @aligned.flatten_state(state),
      a: masked[i],
      a_prev: frame.previous,
      xi: frame.xi,
      r: reward,
      frame: frame.frame,
      ep_step: frame.episode_step,
      terminated,
      truncated,
    })
    self.frames[i] = next_frame
    self.steps[i] += 1
    self.previous[i] = masked[i]
    self.returns[i] += reward
    self.discounted[i] += @math.pow(
        self.config.gamma,
        frame.episode_step.to_double(),
      ) *
      reward
    if terminated || truncated {
      ids.push(i)
      completed.push({
        bin: self.bins[i],
        discounted_return: self.discounted[i],
        bootstrap: Some((frame.episode_step + 1, self.returns[i], terminated)),
      })
    }
  }
  if self.config.auto_reset && !ids.is_empty() {
    self.sampler.update(completed)
    self.reset(ids~)
  }
  transitions
}
