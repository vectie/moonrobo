// The complete environment protocol is independent of the optional solver.
// No Newton/PhysX implementation is substituted by this callback boundary.

///|
pub(all) struct BatchAdapter {
  backend : String
  num_envs : Int32
  joint_names : Array[String]
  read_states : () -> Array[@aligned.State] raise
  write_resets : (Array[Int32], Array[@aligned.State]) -> Unit raise
  apply_context : (Array[Int32], Array[Array[Double]], Double) -> Unit raise
  step_substeps : (Array[Array[Double]], Int32, Double) -> Unit raise
  synchronize : () -> Unit raise
}

///|
pub(all) struct ProtocolConfig {
  asset_path : String
  asset_sha256 : String
  gamma : Double
  self_collisions : Bool
  reset_noise : Bool
  max_episode_steps : Int32
  context_resampling : String
  physics_dt : Double
} derive(ToJson, FromJson)

///|
pub(all) struct BatchStep {
  transitions : Array[@aligned.Transition]
  done : Array[Bool]
  timeout : Array[Bool]
  active : Array[Bool]
  reset_ids : Array[Int32]
}

///|
pub struct TrackingProtocol {
  adapter : BatchAdapter
  config : ProtocolConfig
  motion : @aligned.MotionLibrary
  kin : @aligned.Kinematics
  sampler : @aligned.ReturnBinSampler
  rng : @numeric.Rng
  frames : Array[Int32]
  episode_steps : Array[Int32]
  start_bins : Array[Int32]
  previous : Array[Array[Double]]
  xi : Array[Array[Double]]
  returns : Array[Double]
  discounted : Array[Double]
  done_eval : Array[Bool]
  failed_eval : Array[Bool]
  mut eval_mode : Bool
  reuse_pre_step_state : Bool
  mut pending_inspection : Array[@aligned.CollectorFrame]?
}

///|
fn TrackingProtocol::all_ids(self : TrackingProtocol) -> Array[Int32] {
  Array::makei(self.adapter.num_envs, i => i)
}

///|
fn TrackingProtocol::sample_context(
  self : TrackingProtocol,
  ids : Array[Int32],
) -> Unit {
  for id in ids {
    self.xi[id][0] = 0.3 + 0.9 * self.rng.uniform()
    self.xi[id][30] = 0.05 * self.rng.uniform() - 0.025
    self.xi[id][31] = 0.1 * self.rng.uniform() - 0.05
    self.xi[id][32] = 0.1 * self.rng.uniform() - 0.05
  }
}

///|
/// Constructor validates joint ordering before any raw/device state access.
/// This constructs only a protocol around an explicitly supplied physical
/// adapter. The optional gpu_native package supplies the genuine Warp APIC
/// artifact factory; tests may explicitly inject a CPU contract fixture.
pub fn TrackingProtocol::new(
  adapter : BatchAdapter,
  kin : @aligned.Kinematics,
  motion : @aligned.MotionLibrary,
  config : ProtocolConfig,
  eval_mode~ : Bool = false,
  seed~ : UInt32 = 0U,
  reuse_pre_step_state~ : Bool = false,
) -> TrackingProtocol raise {
  guard adapter.num_envs > 0 && adapter.joint_names == @aligned.joint_names() else {
    fail("GPU articulation joint order differs from the 29-joint reference")
  }
  guard config.physics_dt == 0.005 &&
    ["episode", "environment"].contains(config.context_resampling) &&
    config.max_episode_steps > 0 else {
    fail(
      "aligned GPU protocol requires four 0.005 s substeps and a valid reset protocol",
    )
  }
  guard motion.bodies.length() == motion.states.length() else {
    fail("GPU protocol requires reference FK cache")
  }
  let n = adapter.num_envs
  let result : TrackingProtocol = {
    adapter,
    config,
    motion,
    kin,
    sampler: @aligned.ReturnBinSampler::new(motion.bins, gamma=config.gamma),
    rng: @numeric.Rng::new(seed),
    frames: Array::make(n, 0),
    episode_steps: Array::make(n, 0),
    start_bins: Array::make(n, 0),
    previous: Array::makei(n, _ => Array::make(29, 0.0)),
    xi: Array::makei(n, _ => {
      let x = Array::make(33, 0.0)
      x[0] = 1.0
      x
    }),
    returns: Array::make(n, 0.0),
    discounted: Array::make(n, 0.0),
    done_eval: Array::make(n, false),
    failed_eval: Array::make(n, false),
    eval_mode,
    reuse_pre_step_state,
    pending_inspection: None,
  }
  if !eval_mode && config.context_resampling == "environment" {
    result.sample_context(result.all_ids())
  }
  (adapter.apply_context)(
    result.all_ids(),
    result.xi,
    if eval_mode {
      1.0
    } else {
      0.3
    },
  )
  result.reset()
  result
}

///|
fn TrackingProtocol::noise(
  self : TrackingProtocol,
  values : Array[Double],
  scale : Array[Double],
) -> Array[Double] {
  Array::makei(values.length(), i => {
    values[i] + (2.0 * self.rng.uniform() - 1.0) * scale[i]
  })
}

///|
pub fn TrackingProtocol::reset(
  self : TrackingProtocol,
  ids? : Array[Int32],
  frames? : Array[Int32],
) -> Unit raise {
  self.pending_inspection = None
  let ids = ids.unwrap_or(self.all_ids())
  if ids.is_empty() {
    return
  }
  let seen = []
  for id in ids {
    guard id >= 0 && id < self.adapter.num_envs && !seen.contains(id) else {
      fail("GPU reset IDs must be unique and in range")
    }
    seen.push(id)
  }
  let selected = match frames {
    Some(frames) => {
      guard frames.length() == ids.length() else {
        fail("one reset frame is required per GPU world")
      }
      frames.map(f => {
        guard f >= 0 && f < self.motion.states.length() else {
          fail("GPU reset frame out of range")
        }
        (f, self.motion.frame_bin[f])
      })
    }
    None => self.sampler.sample(ids.length(), () => self.rng.uniform())
  }
  if !self.eval_mode && self.config.context_resampling == "episode" {
    self.sample_context(ids)
    (self.adapter.apply_context)(ids, ids.map(i => self.xi[i]), 0.3)
  }
  let states = []
  for k, id in ids {
    let (frame, bin) = selected[k]
    let reference = self.motion.states[frame]
    let state = if self.config.reset_noise && !self.eval_mode {
      {
        ..reference,
        p: self.noise(reference.p, [0.05, 0.05, 0.01]),
        rotation: @aligned.mat_mul(
          @aligned.so3_exp(self.noise([0.0, 0.0, 0.0], [0.1, 0.1, 0.2])),
          reference.rotation,
        ),
        v: self.noise(reference.v, [0.5, 0.5, 0.2]),
        w: self.noise(reference.w, [0.52, 0.52, 0.78]),
        q: self.noise(reference.q, Array::make(29, 0.1)),
      }
    } else {
      { ..reference, q: reference.q.copy(), }
    }
    for j in 0..<29 {
      state.q[j] = state.q[j].max(self.kin.q_lo[j]).min(self.kin.q_hi[j])
    }
    states.push(state)
    self.frames[id] = frame
    self.start_bins[id] = bin
    self.episode_steps[id] = 0
    self.previous[id] = Array::make(29, 0.0)
    self.returns[id] = 0.0
    self.discounted[id] = 0.0
    self.done_eval[id] = false
    self.failed_eval[id] = false
    if !self.eval_mode {
      for j in 1..<30 {
        self.xi[id][j] = 0.02 * self.rng.uniform() - 0.01
      }
    }
  }
  (self.adapter.write_resets)(ids, states)
  // A real provider must invalidate/reset solver warm starts for these IDs.
  (self.adapter.synchronize)()
}

///|
pub fn TrackingProtocol::inspect(
  self : TrackingProtocol,
) -> Array[@aligned.CollectorFrame] raise {
  self.pending_inspection = None
  (self.adapter.synchronize)()
  let states = (self.adapter.read_states)()
  guard states.length() == self.adapter.num_envs else {
    fail("GPU device-state world count differs")
  }
  let frames : Array[@aligned.CollectorFrame] = Array::makei(states.length(), i => {
    state: states[i],
    previous: self.previous[i].copy(),
    xi: self.xi[i].copy(),
    frame: self.frames[i],
    episode_step: self.episode_steps[i],
  })
  // The protocol owns all adapter mutations. Cache only until the next step;
  // reset/restore/another inspect invalidate it. Deep-copy the returned state
  // so observation preparation cannot mutate the transition's pre-step state.
  if self.reuse_pre_step_state {
    self.pending_inspection = Some(frames.map(copy_collector_frame))
  }
  frames
}

///|
fn copy_collector_frame(
  frame : @aligned.CollectorFrame,
) -> @aligned.CollectorFrame {
  let s = frame.state
  {
    ..frame,
    state: {
      p: s.p.copy(),
      rotation: s.rotation.copy(),
      v: s.v.copy(),
      w: s.w.copy(),
      q: s.q.copy(),
      qd: s.qd.copy(),
    },
    previous: frame.previous.copy(),
    xi: frame.xi.copy(),
  }
}

///|
/// Preserve physical pre-reset state/terminal flags. Inactive evaluation slots
/// still consume actual simulated compute but never create extra measured trials.
pub fn TrackingProtocol::step(
  self : TrackingProtocol,
  actions : Array[Array[Double]],
) -> BatchStep raise {
  let pending = self.pending_inspection
  self.pending_inspection = None
  guard actions.length() == self.adapter.num_envs &&
    actions.all(a => a.length() == 29 && a.all(v => !v.is_nan() && !v.is_inf())) else {
    fail("GPU actions must be finite N by 29")
  }
  let before = match pending {
    Some(frames) => frames
    None => self.inspect()
  }
  self.pending_inspection = None
  let active = Array::makei(actions.length(), i => {
    !self.eval_mode || !self.done_eval[i]
  })
  let targets = Array::makei(actions.length(), i => {
    @aligned.action_to_setpoint(
      actions[i],
      calibration=self.xi[i][1:30].to_owned(),
    )
  })
  (self.adapter.step_substeps)(targets, 4, 0.005)
  (self.adapter.synchronize)()
  let after = (self.adapter.read_states)()
  guard after.length() == actions.length() else {
    fail("GPU post-step world count differs")
  }
  let transitions : Array[@aligned.Transition] = []
  let done = []
  let timeout = []
  let reset_ids = []
  let completions : Array[@aligned.CompletedEpisode] = []
  for i, prior in before {
    let frame = (prior.frame + (if active[i] { 1 } else { 0 })).min(
      self.motion.clip_end[self.motion.clip_id[prior.frame]],
    )
    let reference = self.motion.states[frame]
    let reward = if active[i] {
      @aligned.reward(
        self.kin,
        after[i],
        reference,
        self.motion.bodies[frame],
        actions[i],
        prior.previous,
        atlas=self.motion.orthonormal_heading,
      ).reward
    } else {
      0.0
    }
    let term = active[i] && @aligned.termination(after[i], reference)
    let cut = frame >= self.motion.clip_end[self.motion.clip_id[prior.frame]] ||
      (
        !self.eval_mode &&
        prior.episode_step + 1 >= self.config.max_episode_steps
      )
    let finished = term || cut || !active[i]
    transitions.push({
      s: @aligned.flatten_state(prior.state),
      s1: @aligned.flatten_state(after[i]),
      a: actions[i].copy(),
      a_prev: prior.previous,
      xi: prior.xi,
      r: reward,
      frame: prior.frame,
      ep_step: prior.episode_step,
      terminated: term,
      truncated: cut && !term,
    })
    done.push(finished)
    timeout.push(cut)
    self.returns[i] += reward
    self.discounted[i] += @math.pow(
        self.config.gamma,
        prior.episode_step.to_double(),
      ) *
      reward
    self.frames[i] = frame
    self.episode_steps[i] = prior.episode_step + (if active[i] { 1 } else { 0 })
    self.previous[i] = actions[i].copy()
    if self.eval_mode {
      self.done_eval[i] = self.done_eval[i] || finished
      self.failed_eval[i] = self.failed_eval[i] || term
    } else if finished {
      reset_ids.push(i)
      completions.push({
        bin: self.start_bins[i],
        discounted_return: self.discounted[i],
        bootstrap: Some((self.episode_steps[i], self.returns[i], term)),
      })
    }
  }
  if !self.eval_mode && !reset_ids.is_empty() {
    self.sampler.update(completions)
    self.reset(ids=reset_ids)
  }
  { transitions, done, timeout, active, reset_ids, }
}

///|
pub(all) struct WarmState {
  format : String
  config : ProtocolConfig
  num_envs : Int32
  xi : Array[Array[Double]]
  bin_returns : Array[Double]
  bin_average : Array[Double]
  bin_completed : Array[Int32]
  rng : UInt32
  exact_resume : Bool
  replay_refill_required : Bool
} derive(ToJson, FromJson)

///|
pub fn TrackingProtocol::snapshot(self : TrackingProtocol) -> WarmState {
  let (bin_returns, bin_average, bin_completed) = self.sampler.snapshot()
  {
    format: "moonrobo.aligned.isaac-warm-state.v1",
    config: self.config,
    num_envs: self.adapter.num_envs,
    xi: self.xi.map(row => row.copy()),
    bin_returns,
    bin_average,
    bin_completed,
    rng: self.rng.state(),
    exact_resume: false,
    replay_refill_required: true,
  }
}

///|
pub fn TrackingProtocol::restore(
  self : TrackingProtocol,
  saved : WarmState,
) -> Json raise {
  self.pending_inspection = None
  guard !self.eval_mode &&
    saved.format == "moonrobo.aligned.isaac-warm-state.v1" &&
    saved.config.to_json() == self.config.to_json() &&
    saved.num_envs == self.adapter.num_envs &&
    saved.xi.length() == self.adapter.num_envs &&
    !saved.exact_resume &&
    saved.replay_refill_required else {
    fail("GPU warm checkpoint configuration/asset/protocol differs")
  }
  for row in saved.xi {
    guard row.length() == 33 &&
      row.all(v => !v.is_nan() && !v.is_inf()) &&
      row[0] > 0.0 else {
      fail("invalid GPU warm context")
    }
  }
  self.sampler.restore(
    saved.bin_returns,
    saved.bin_average,
    saved.bin_completed,
  )
  self.rng.set_state(saved.rng)
  for i, row in saved.xi {
    self.xi[i] = row.copy()
  }
  (self.adapter.apply_context)(self.all_ids(), self.xi, 0.3)
  self.reset()
  {
    "exact_resume": false,
    "replay_refill_required": true,
    "physical_episodes_reset": self.adapter.num_envs.to_json(),
  }
}

///|
/// Evaluation permanently ends training episodes; callers must save first.
pub fn TrackingProtocol::for_evaluation(self : TrackingProtocol) -> Unit raise {
  self.pending_inspection = None
  self.eval_mode = true
  for row in self.xi {
    for j in 0..<33 {
      row[j] = 0.0
    }
    row[0] = 1.0
  }
  (self.adapter.apply_context)(self.all_ids(), self.xi, 1.0)
  self.reset()
}

///|
pub fn TrackingProtocol::evaluation_reset(
  self : TrackingProtocol,
  frame : Int32,
) -> Unit raise {
  guard self.eval_mode else {
    fail("evaluation view requires for_evaluation first")
  }
  self.reset(frames=Array::make(self.adapter.num_envs, frame))
}

///|
pub fn TrackingProtocol::evaluation_step(
  self : TrackingProtocol,
  action : Array[Double],
) -> @aligned.Transition raise {
  guard self.eval_mode else { fail("evaluation view is not enabled") }
  self.step(Array::makei(self.adapter.num_envs, _ => action.copy())).transitions[0]
}
