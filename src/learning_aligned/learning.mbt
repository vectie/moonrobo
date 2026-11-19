///|
pub(all) struct LearnerConfig {
  wm_hidden : Array[Int32]
  policy_hidden : Array[Int32]
  critic_hidden : Array[Int32]
  hist : Int32
  goal_frames : Int32
  horizon : Int32
  wm_window : Int32
  wm_batches : Int32
  wm_batch : Int32
  policy_batch : Int32
  learning_rate : Double
  gamma : Double
  lam : Double
  critic_epochs : Int32
  critic_minibatches : Int32
  observation_noise : Bool
} derive(Debug, ToJson, FromJson)

///|
pub fn LearnerConfig::default() -> LearnerConfig {
  {
    wm_hidden: [2048, 2048, 2048],
    policy_hidden: [2048, 1024, 512, 256],
    critic_hidden: [256, 128],
    hist: 10,
    goal_frames: 10,
    horizon: 32,
    wm_window: 8,
    wm_batches: 10,
    wm_batch: 2048,
    policy_batch: 4096,
    learning_rate: 0.0002,
    gamma: 0.99,
    lam: 0.95,
    critic_epochs: 5,
    critic_minibatches: 4,
    observation_noise: true,
  }
}

///|
pub struct Learner {
  config : LearnerConfig
  kin : Kinematics
  motion : MotionLibrary
  mode : ObservationMode
  reward_cfg : RewardConfig
  default_q : Array[Double]
  wm : WorldModel
  policy : Policy
  critic : Critic
  opt_wm : @numeric.Adam
  opt_policy : @numeric.Adam
  opt_critic : @numeric.Adam
  rng : @numeric.Rng
}

///|
pub fn Learner::new(
  kin : Kinematics,
  motion : MotionLibrary,
  config~ : LearnerConfig = LearnerConfig::default(),
  mode~ : ObservationMode = Paper,
  reward_cfg~ : RewardConfig = RewardConfig::default(),
  seed~ : UInt32 = 1U,
) -> Learner raise {
  guard config.hist > 0 &&
    config.goal_frames > 0 &&
    config.horizon > 0 &&
    config.policy_batch > 0 &&
    config.critic_epochs > 0 &&
    config.critic_minibatches > 0 else {
    fail("invalid aligned learner context or update configuration")
  }
  guard motion.bodies.length() == motion.states.length() else {
    fail("aligned training requires reference FK body cache")
  }
  let rng = @numeric.Rng::new(seed)
  let wm = WorldModel::new(rng, hidden=config.wm_hidden)
  let policy = Policy::new(
    mode.dim(),
    73 * config.goal_frames,
    rng,
    hist=config.hist,
    hidden=config.policy_hidden,
  )
  let critic = Critic::new(
    184 + 73 * config.goal_frames,
    rng,
    hidden=config.critic_hidden,
  )
  {
    config,
    kin,
    motion,
    mode,
    reward_cfg,
    default_q: default_joint_positions(),
    wm,
    policy,
    critic,
    opt_wm: @numeric.Adam::new(wm.net.parameters.length(), config.learning_rate),
    opt_policy: @numeric.Adam::new(
      policy.encoder.parameters.length() + policy.decoder.parameters.length(),
      config.learning_rate,
      beta2=0.95,
    ),
    opt_critic: @numeric.Adam::new(
      critic.net.parameters.length(),
      config.learning_rate,
    ),
    rng,
  }
}

///|
pub fn Learner::observe(self : Learner, tr : Transition) -> Unit {
  self.wm.observe(tr)
}

///|
fn Learner::noise_ad(
  self : Learner,
  t : @numeric.Tape,
  row : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  if !self.config.observation_noise {
    return row
  }
  let widths = observation_noise(self.mode)
  Array::makei(row.length(), i => {
    t.add(row[i], t.scalar((self.rng.uniform() * 2.0 - 1.0) * widths[i]))
  })
}

///|
pub fn Learner::action(
  self : Learner,
  state : State,
  previous : Array[Double],
  xi : Array[Double],
  frame : Int32,
  history : Array[Array[Double]],
  reset : Bool,
  action_noise~ : Double = 0.1,
) -> (Array[Double], Array[Array[Double]]) {
  let obs = observation(
    state,
    previous,
    xi,
    self.default_q,
    self.motion.states[frame],
    self.mode,
  )
  let noisy = if self.config.observation_noise {
    let widths = observation_noise(self.mode)
    Array::makei(obs.length(), i => {
      obs[i] + (self.rng.uniform() * 2.0 - 1.0) * widths[i]
    })
  } else {
    obs
  }
  let history = if reset || history.is_empty() {
    Array::makei(self.config.hist, _ => noisy.copy())
  } else {
    let next = history[1:].to_owned()
    next.push(noisy)
    next
  }
  let goal = self.motion.goal(frame, self.config.goal_frames)
  self.policy.update_normalizers([noisy], [goal])
  let action = self.policy
    .forward(history, goal)
    .map(x => (x + action_noise * self.rng.normal()).max(-20.0).min(20.0))
  (action, history)
}

///|
pub fn Learner::fit_world_model(
  self : Learner,
  replay : ReplayBuffer,
) -> WorldFitMetrics raise {
  let c = self.config
  self.wm.fit(
    replay,
    self.opt_wm,
    self.rng,
    batches=c.wm_batches,
    batch=c.wm_batch,
    window=c.wm_window,
  )
}

///|
pub(all) struct PolicyMetrics {
  policy_loss : Double
  critic_loss : Double
  gradient_norm : Double
  imagined_reward : Double
  imagined_survival : Double
  imagined_steps : Int32
  critic_updates : Int32
} derive(Debug, ToJson)

///|
pub fn Learner::update_policy(
  self : Learner,
  replay : ReplayBuffer,
  train_critic~ : Bool = true,
  fixed? : FixedPolicyBatch,
  gradient_trace? : (String, Int32, Array[Double], Array[Double], Double) -> Unit,
) -> PolicyMetrics raise {
  let c = self.config
  let starts = match fixed {
    Some(input) => {
      input.validate(c)
      input.starts
    }
    None =>
      replay.sample_starts(
        c.policy_batch,
        c.hist,
        n => self.rng.index(n),
        clip_end=f => self.motion.clip_end[self.motion.clip_id[f]],
        horizon=c.horizon,
      )
  }
  let t = @numeric.Tape::new()
  let enc = self.policy.encoder.bind(t)
  let dec = self.policy.decoder.bind(t)
  let wm = self.wm.net.bind(t)
  let critic = self.critic.net.bind(t)
  let critic_inputs : Array[Array[Array[Double]]] = []
  let rewards : Array[Array[Double]] = []
  let failures : Array[Array[Double]] = []
  let mut objective = t.scalar(0.0)
  let mut reward_total = 0.0
  let mut survival_total = 0.0
  for sample, start in starts {
    let mut state = lift(t, unflatten_state(start.start.s))
    let xi = start.start.xi
    let xi_n = normalize_xi(xi)
    let mut frame = start.start.frame
    let mut previous = t.vector(start.start.a_prev)
    let mut obs = start.history.map(tr => {
      self.noise_ad(
        t,
        t.vector(
          fixed_observation(
            unflatten_state(tr.s),
            tr.a_prev,
            tr.xi,
            self.default_q,
            self.motion.states[tr.frame],
            self.mode,
            fixed,
          ),
        ),
      )
    })
    let inputs : Array[Array[Double]] = []
    let episode_rewards : Array[Double] = []
    let episode_failures : Array[Double] = []
    let mut survival = t.scalar(1.0)
    let mut sample_objective = t.scalar(0.0)
    for step in 0..<=c.horizon {
      let goal = match fixed {
        Some(input) => input.goals[step][sample]
        None => self.motion.goal(frame, c.goal_frames)
      }
      let critic_input = fixed_critic_features(
        t,
        self.kin,
        state,
        self.motion.states[frame],
        self.motion.bodies[frame],
        xi_n,
        goal,
        fixed,
      )
      inputs.push(critic_input.map(v => v.value))
      if step == c.horizon {
        let tail = self.critic.net.forward(
            t,
            critic,
            self.critic.norm.apply_ad(t, critic_input),
          )[0]
        sample_objective = t.add(
          sample_objective,
          t.scale(
            t.mul(survival, tail),
            @math.pow(c.gamma, c.horizon.to_double()),
          ),
        )
        break
      }
      let latent = self.policy.encoder
        .forward(t, enc, self.policy.goal_norm.apply_ad(t, t.vector(goal)))
        .map(v => t.tanh(v))
      for row in obs {
        latent.append(self.policy.obs_norm.apply_ad(t, row))
      }
      let action = self.policy.decoder.forward(t, dec, latent)
      state = self.wm.step_ad(t, wm, state, action, xi_n)
      frame += 1
      let reward = fixed_reward(
        t,
        self.kin,
        state,
        self.motion.states[frame],
        self.motion.bodies[frame],
        action,
        previous,
        self.reward_cfg,
        fixed,
      )
      let failure = fixed_failure(
        t,
        state,
        self.motion.states[frame],
        self.reward_cfg,
        fixed,
      )
      sample_objective = t.add(
        sample_objective,
        t.scale(t.mul(survival, reward), @math.pow(c.gamma, step.to_double())),
      )
      reward_total += survival.value * reward.value
      survival = t.mul(survival, t.sub(t.scalar(1.0), failure))
      episode_rewards.push(reward.value)
      episode_failures.push(failure.value)
      let current = self.noise_ad(
        t,
        fixed_ad_observation(
          t,
          state,
          action,
          xi,
          self.default_q,
          self.motion.states[frame],
          self.mode,
          fixed,
        ),
      )
      obs = obs[1:].to_owned()
      obs.push(current)
      previous = action
    }
    objective = t.add(
      objective,
      t.scale(sample_objective, 1.0 / c.policy_batch.to_double()),
    )
    survival_total += survival.value
    critic_inputs.push(inputs)
    rewards.push(episode_rewards)
    failures.push(episode_failures)
  }
  t.backward(t.scale(objective, -1.0))
  let all_parameters = self.policy.encoder.parameters.copy()
  all_parameters.append(self.policy.decoder.parameters)
  let all_bound = enc.copy()
  all_bound.append(dec)
  let gradient_norm = self.opt_policy.step(
    all_parameters,
    t,
    all_bound,
    max_norm=1.0,
    max_value=0.1,
    gradient_trace=(raw, clipped, norm) => {
      if gradient_trace is Some(capture) {
        capture("policy", 0, raw, clipped, norm)
      }
    },
  )
  let nenc = self.policy.encoder.parameters.length()
  for i in 0..<nenc {
    self.policy.encoder.parameters[i] = all_parameters[i]
  }
  for i in 0..<self.policy.decoder.parameters.length() {
    self.policy.decoder.parameters[i] = all_parameters[nenc + i]
  }
  let mut critic_loss = 0.0
  let mut critic_updates = 0
  if train_critic {
    let rows : Array[Array[Double]] = []
    for trajectory in critic_inputs {
      rows.append(trajectory)
    }
    self.critic.norm.update(rows)
    let values = Array::makei(c.horizon + 1, step => {
      Array::makei(c.policy_batch, b => {
        self.critic.predict(critic_inputs[b][step])
      })
    })
    let reward_rows = Array::makei(c.horizon, step => {
      Array::makei(c.policy_batch, b => rewards[b][step])
    })
    let failure_rows = Array::makei(c.horizon, step => {
      Array::makei(c.policy_batch, b => failures[b][step])
    })
    let targets = lambda_returns(
      reward_rows,
      values,
      failure_rows,
      gamma=c.gamma,
      lam=c.lam,
    )
    let order = Array::makei(c.horizon * c.policy_batch, i => i)
    for epoch in 0..<c.critic_epochs {
      match fixed {
        Some(input) =>
          for i, x in input.critic_permutations[epoch] {
            order[i] = x
          }
        None => self.rng.shuffle(order)
      }
      let chunks = c.critic_minibatches.min(order.length())
      for chunk in 0..<chunks {
        let from = chunk * order.length() / chunks
        let until = (chunk + 1) * order.length() / chunks
        let ct = @numeric.Tape::new()
        let bound = self.critic.net.bind(ct)
        let errors : Array[@numeric.Value] = []
        for index in order[from:until] {
          let step = index / c.policy_batch
          let b = index % c.policy_batch
          let prediction = self.critic.net.forward(
              ct,
              bound,
              ct.vector(self.critic.norm.apply(critic_inputs[b][step])),
            )[0]
          let e = ct.sub(prediction, ct.scalar(targets[step][b]))
          errors.push(ct.mul(e, e))
        }
        let loss = ct.mean(errors)
        ct.backward(loss)
        ignore(
          self.opt_critic.step(
            self.critic.net.parameters,
            ct,
            bound,
            max_norm=1.0,
            gradient_trace=(raw, clipped, norm) => {
              if gradient_trace is Some(capture) {
                capture("critic", critic_updates, raw, clipped, norm)
              }
            },
          ),
        )
        critic_loss += loss.value
        critic_updates += 1
      }
    }
  }
  {
    policy_loss: -objective.value,
    critic_loss: critic_loss / critic_updates.max(1).to_double(),
    gradient_norm,
    imagined_reward: reward_total /
    (c.horizon * c.policy_batch).to_double() /
    0.1,
    imagined_survival: survival_total / c.policy_batch.to_double(),
    imagined_steps: c.horizon * c.policy_batch,
    critic_updates,
  }
}
