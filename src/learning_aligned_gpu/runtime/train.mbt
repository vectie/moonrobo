///|
pub(all) struct TrainingCounters {
  mut physical_transitions : Int64
  mut imagined_transitions : Int64
  mut actor_updates : Int64
  mut model_updates : Int64
  mut critic_updates : Int64
  mut model_fit_transition_slots : Int64
} derive(Debug, ToJson, FromJson)

///|
pub fn TrainingCounters::new() -> TrainingCounters {
  {
    physical_transitions: 0L,
    imagined_transitions: 0L,
    actor_updates: 0L,
    model_updates: 0L,
    critic_updates: 0L,
    model_fit_transition_slots: 0L,
  }
}

///|
pub(all) struct IterationMetrics {
  iteration : Int32
  learning_rate : Double
  world : @gpu.WorldMetrics
  policy : @gpu.PolicyMetrics?
  actor_readiness : @aligned.ActorReadiness?
}

///|
pub fn IterationMetrics::to_json(self : IterationMetrics) -> Json {
  let policy = match self.policy {
    None => Json::null()
    Some(p) =>
      {
        "pi_loss": p.policy_loss,
        "v_loss": p.critic_loss,
        "imagined_reward": p.imagined_reward,
        "imagined_survival": p.imagined_survival,
        "imagined_steps": p.imagined_steps,
        "critic_updates": p.critic_updates,
      }
  }
  {
    "iteration": self.iteration,
    "learning_rate": self.learning_rate,
    "world": {
      "wm_loss": self.world.wm_loss,
      "wm_err8": self.world.wm_error_last,
      "wm_updates": self.world.wm_updates,
    },
    "policy": policy,
    "actor_readiness": self.actor_readiness.to_json(),
    "actor_readiness_scope": "rank-local; extra steps lower effective update/data ratio",
  }
}

///|
pub struct TrainingRunner {
  learner : @gpu.Learner
  default_q : Array[Double]
  motion : @aligned.MotionLibrary
  replay : @aligned.ReplayBuffer
  counters : TrainingCounters
  histories : Array[Array[Array[Double]]]
  rng : @numeric.Rng
  collection_seed : UInt32
  capacity : Int32
  num_envs : Int32
  limits : BatchLimits
  actor_catalog : String
  resident_references : ResidentReferences?
  world_staging_max_bytes : Int64?
  world_packed_replay : Bool
  noise_staging_max_bytes : Int64?
  mut iteration : Int32
  mut step_accumulator : Double
}

///|
pub fn TrainingRunner::reference_fk_bytes(self : TrainingRunner) -> Int64 raise {
  match self.resident_references {
    Some(cache) =>
      match cache.reference_fk {
        Some(table) =>
          table.shape()[0].to_int64() * table.shape()[1].to_int64() * 4L
        None => 0L
      }
    None => 0L
  }
}

///|
/// Host replay and upload limits are enforced before collection. The limits do
/// not estimate autograd activations; the CLI must additionally budget networks,
/// optimizer state, physics, and BPTT memory for the selected device.
pub fn TrainingRunner::new(
  learner : @gpu.Learner,
  motion : @aligned.MotionLibrary,
  capacity : Int32,
  num_envs : Int32,
  seed~ : UInt32 = 1U,
  limits~ : BatchLimits = BatchLimits::default(),
  max_replay_values~ : Int64 = 67108864L,
  resident_reference_max_bytes~ : Int64? = None,
  world_staging_max_bytes~ : Int64? = None,
  world_packed_replay~ : Bool = false,
  noise_staging_max_bytes~ : Int64? = None,
  reference_fk_cache~ : Bool = false,
) -> TrainingRunner raise {
  errdefer learner.abort_distributed()
  let c = learner.config
  let default_q = learner.context.default_joint_values()
  guard !world_packed_replay || world_staging_max_bytes is Some(_) else {
    fail("packed replay requires admitted world staging")
  }
  guard !reference_fk_cache ||
    (
      resident_reference_max_bytes is Some(_) &&
      learner.optimizations.reuse_geometry
    ) else {
    fail("reference FK cache requires resident references and geometry reuse")
  }
  guard capacity >= c.wm_window &&
    num_envs > 0 &&
    c.wm_batches > 0 &&
    c.wm_batch > 0 &&
    c.wm_window > 0 &&
    c.hist > 0 &&
    c.goal_frames > 0 &&
    c.horizon > 0 &&
    c.critic_minibatches > 0 &&
    c.goal_frames <= motion.states.materialize_limit &&
    !motion.names.is_empty() else {
    fail(
      "invalid replay capacity, learner configuration, or reference gather limit",
    )
  }
  guard motion.clip_start.length() == motion.clip_end.length() &&
    motion.clip_start.length() == motion.names.length() else {
    fail("reference catalog clip dimensions differ")
  }
  let actor_catalog = motion.require_actor_horizon(c.horizon)
  if world_staging_max_bytes is Some(max_bytes) {
    ignore(world_staging_usage(c.wm_batch, c.wm_window, max_bytes~, limits~))
  }
  if noise_staging_max_bytes is Some(max_bytes) {
    ignore(
      noise_staging_usage(
        c.policy_batch,
        learner.mode.dim(),
        max_bytes~,
        limits~,
      ),
    )
  }
  let collection_seed = @gpu.rank_seed(seed, learner.collective)
  if learner.collective is Some(_) {
    let signature = runtime_setup_signature(
      learner, motion, capacity, num_envs, seed,
    )
    let signature = match world_staging_max_bytes {
      None => signature
      Some(cap) => signature + ":world-logical-staging:\{cap}"
    }
    let signature = match noise_staging_max_bytes {
      None => signature
      Some(cap) => signature + ":noise-logical-staging:\{cap}"
    }
    let signature = if world_packed_replay {
      signature + ":world-packed-replay"
    } else {
      signature
    }
    learner.assert_same_signature(
      "runtime setup",
      match resident_reference_max_bytes {
        None => signature
        Some(cap) => signature + ":resident-reference-cache:\{cap}"
      },
    )
  }
  ignore(
    bounded_product(
      [capacity.to_int64(), num_envs.to_int64(), 234L],
      max_replay_values,
    ),
  )
  check_policy_limits(c, c.policy_batch, learner.mode.dim(), limits)
  check_limits(
    limits,
    0L,
    bounded_product(
      [c.wm_batch.to_int64(), c.wm_window.to_int64(), 205L],
      limits.max_tensor_values.min(2147483647L),
    ),
  )
  check_limits(
    limits,
    num_envs.to_int64() * c.goal_frames.to_int64(),
    bounded_product(
      [
        num_envs.to_int64(),
        205L +
        learner.mode.dim().to_int64() * (c.hist.to_int64() + 1L) +
        73L * c.goal_frames.to_int64(),
      ],
      limits.max_tensor_values.min(2147483647L),
    ),
  )
  learner.synchronize_initial_state()
  let resident_references = match resident_reference_max_bytes {
    None => None
    Some(max_bytes) =>
      Some(
        learner.prepare_collective("resident reference construction", () => {
          ResidentReferences::new(
            learner.backend,
            motion,
            c.goal_frames,
            cuda_device=learner.cuda_device,
            dtype=Float32,
            max_bytes~,
            limits~,
            reference_context=if reference_fk_cache {
              Some(learner.context)
            } else {
              None
            },
          )
        }),
      )
  }
  {
    learner,
    default_q,
    motion,
    replay: @aligned.ReplayBuffer::new(capacity, num_envs),
    counters: TrainingCounters::new(),
    histories: Array::makei(num_envs, _ => []),
    rng: @numeric.Rng::new(collection_seed),
    collection_seed,
    capacity,
    num_envs,
    limits,
    actor_catalog,
    resident_references,
    world_staging_max_bytes,
    world_packed_replay,
    noise_staging_max_bytes,
    iteration: 0,
    step_accumulator: 0.0,
  }
}

///|
fn validate_transition(
  tr : @aligned.Transition,
  motion : @aligned.MotionLibrary,
) -> Unit raise {
  guard tr.s.length() == 71 &&
    tr.s1.length() == 71 &&
    tr.a.length() == 29 &&
    tr.a_prev.length() == 29 &&
    tr.xi.length() == 33 &&
    tr.s.all(@numeric.finite) &&
    tr.s1.all(@numeric.finite) &&
    tr.a.all(@numeric.finite) &&
    tr.a_prev.all(@numeric.finite) &&
    tr.xi.all(@numeric.finite) &&
    @numeric.finite(tr.r) &&
    tr.frame >= 0 &&
    tr.frame < motion.states.length() &&
    tr.ep_step >= 0 else {
    fail("physical adapter returned invalid transition")
  }
}

///|
fn TrainingRunner::collect(
  self : TrainingRunner,
  steps : Int32,
  inspect_env : () -> Array[@aligned.CollectorFrame] raise,
  step_env : (Array[Array[Double]]) -> Array[@aligned.Transition] raise,
  action_noise : Double,
) -> Unit raise {
  let learner = self.learner
  let c = learner.config
  let b = learner.backend
  let device = learner.cuda_device
  let dim = learner.mode.dim()
  for _ in 0..<steps {
    let frames = @tensor.operator_span("diag.collection.inspect", inspect_env)
    guard frames.length() == self.num_envs else {
      fail("physical adapter environment count differs")
    }
    let observations : Array[Double] = []
    let goals : Array[Double] = []
    let histories : Array[Double] = []
    let prepare_range = @tensor.operator_range_begin(
      "diag.collection.observation_history_cpu",
    )
    errdefer @tensor.operator_range_cancel(prepare_range)
    for i, frame in frames {
      guard frame.frame >= 0 &&
        frame.frame < self.motion.states.length() &&
        frame.episode_step >= 0 &&
        frame.previous.length() == 29 &&
        frame.xi.length() == 33 &&
        frame.state.p.length() == 3 &&
        frame.state.rotation.length() == 9 &&
        frame.state.v.length() == 3 &&
        frame.state.w.length() == 3 &&
        frame.state.q.length() == 29 &&
        frame.state.qd.length() == 29 &&
        frame.state.p.all(@numeric.finite) &&
        frame.state.rotation.all(@numeric.finite) &&
        frame.state.v.all(@numeric.finite) &&
        frame.state.w.all(@numeric.finite) &&
        frame.state.q.all(@numeric.finite) &&
        frame.state.qd.all(@numeric.finite) else {
        fail("invalid physical collector frame")
      }
      let noisy = observation_with_noise(
        frame.state,
        frame.previous,
        frame.xi,
        self.motion.states[frame.frame],
        learner.mode,
        self.default_q,
        c.observation_noise,
        self.rng,
      )
      for j in learner.context.active_joint_count()..<29 {
        noisy[j] = 0.0
        noisy[29 + j] = 0.0
        noisy[64 + j] = 0.0
      }
      let history = if frame.episode_step == 0 || self.histories[i].is_empty() {
        Array::makei(c.hist, _ => noisy.copy())
      } else {
        let next = self.histories[i][1:].to_owned()
        next.push(noisy)
        next
      }
      self.histories[i] = history
      observations.append(noisy)
      for row in history {
        histories.append(row)
      }
      if self.resident_references is None {
        goals.append(self.motion.goal(frame.frame, c.goal_frames))
      }
    }
    @tensor.operator_range_end(prepare_range)
    let goal_range = @tensor.operator_range_begin(
      "diag.collection.goal_prepare_upload",
    )
    errdefer @tensor.operator_range_cancel(goal_range)
    let goal_tensor = match self.resident_references {
      None =>
        upload(b, goals, [self.num_envs, c.goal_frames * 73], device, Float32)
      Some(resident) => resident.goals_for_frames(frames.map(f => f.frame))
    }
    @tensor.operator_range_end(goal_range)
    let norm_range = @tensor.operator_range_begin(
      "diag.collection.policy_normalizers",
    )
    errdefer @tensor.operator_range_cancel(norm_range)
    learner.policy.update_normalizers(
      upload(b, observations, [self.num_envs, dim], device, Float32),
      goal_tensor,
      collective=learner.collective,
    )
    @tensor.operator_range_end(norm_range)
    let policy_range = @tensor.operator_range_begin(
      "diag.collection.policy_upload_forward_readback",
    )
    errdefer @tensor.operator_range_cancel(policy_range)
    // Read back only detached actions. No tensor or graph is stored in replay.
    let raw = learner.policy
      .forward(
        upload(b, histories, [self.num_envs, c.hist, dim], device, Float32),
        goal_tensor,
      )
      .stop_gradient()
      .values()
    @tensor.operator_range_end(policy_range)
    let action_range = @tensor.operator_range_begin(
      "diag.collection.action_noise_cpu",
    )
    errdefer @tensor.operator_range_cancel(action_range)
    guard raw.all(@numeric.finite) else {
      fail("policy produced nonfinite physical action")
    }
    let actions = Array::makei(self.num_envs, i => {
      Array::makei(29, j => {
        (raw[i * 29 + j] + action_noise * self.rng.normal())
        .max(-20.0)
        .min(20.0)
      })
    })
    guard actions.all(row => row.all(@numeric.finite)) else {
      fail("policy produced nonfinite physical action")
    }
    @tensor.operator_range_end(action_range)
    let transitions = @tensor.operator_span("diag.collection.physics_step", () => {
      step_env(actions)
    })
    guard transitions.length() == self.num_envs else {
      fail("physical adapter transition count differs")
    }
    let states : Array[Double] = []
    let next_states : Array[Double] = []
    let actual_actions : Array[Double] = []
    let xi : Array[Double] = []
    let transition_range = @tensor.operator_range_begin(
      "diag.collection.transition_validate_pack",
    )
    errdefer @tensor.operator_range_cancel(transition_range)
    for i, tr in transitions {
      validate_transition(tr, self.motion)
      guard tr.frame == frames[i].frame && tr.ep_step == frames[i].episode_step else {
        fail(
          "physical adapter transition does not match inspected reference/episode",
        )
      }
      states.append(tr.s)
      next_states.append(tr.s1)
      actual_actions.append(tr.a)
      xi.append(tr.xi)
    }
    @tensor.operator_range_end(transition_range)
    @tensor.operator_span("diag.collection.replay_add", () => {
      self.replay.add(transitions)
    })
    let world_norm_range = @tensor.operator_range_begin(
      "diag.collection.world_normalizers_upload",
    )
    errdefer @tensor.operator_range_cancel(world_norm_range)
    learner.observe(
      upload(b, states, [self.num_envs, 71], device, Float32),
      upload(b, actual_actions, [self.num_envs, 29], device, Float32),
      upload(b, xi, [self.num_envs, 33], device, Float32),
      upload(b, next_states, [self.num_envs, 71], device, Float32),
    )
    @tensor.operator_range_end(world_norm_range)
    self.counters.physical_transitions += self.num_envs.to_int64()
  }
}

///|
/// Callbacks must supply real physical transitions; no simulated data fallback
/// is provided. Sampling is bounded by replay and BatchLimits.
/// Optional `on_phase` observes completed phases without changing the update
/// schedule. An exception stops further work and aborts an active collective;
/// already completed physical steps or optimizer updates are not rolled back.
pub fn TrainingRunner::run(
  self : TrainingRunner,
  options : @aligned.TrainingOptions,
  inspect_env : () -> Array[@aligned.CollectorFrame] raise,
  step_env : (Array[Array[Double]]) -> Array[@aligned.Transition] raise,
  on_iteration : (IterationMetrics) -> Unit raise,
  synchronize_sampler? : () -> Unit raise,
  on_phase~ : ((String, Int32) -> Unit raise)? = None,
) -> Unit raise {
  errdefer self.learner.abort_distributed()
  guard self.learner.collective is None || synchronize_sampler is Some(_) else {
    fail(
      "distributed training requires the physical sampler synchronization callback",
    )
  }
  guard options.iterations >= self.iteration &&
    options.update_to_data > 0.0 &&
    @numeric.finite(options.update_to_data) &&
    1.0 / options.update_to_data <= 2147483646.0 &&
    options.learning_rate_decay_iterations > 0 &&
    options.warmup_steps >= 0 &&
    options.world_only_iterations >= 0 &&
    @numeric.finite(options.action_noise) &&
    options.action_noise >= 0.0 else {
    fail(
      "invalid training iterations, warmup, action noise, or UTD configuration",
    )
  }
  let c = self.learner.config
  self.learner.assert_same_signature(
    "run progress and schedule",
    self.run_signature(options),
  )
  if options.iterations == self.iteration {
    return
  }
  if self.learner.any_rank(!self.replay.can_sample_windows(c.wm_window)) {
    self.collect(
      options.warmup_steps.max(c.wm_window),
      inspect_env,
      step_env,
      options.action_noise,
    )
    if synchronize_sampler is Some(sync) {
      sync()
    }
    if on_phase is Some(record) {
      record("warmup_complete", self.iteration)
    }
  }
  for it in self.iteration..<options.iterations {
    let iteration_profile = @tensor.profile_begin("iteration.training")
    errdefer @tensor.profile_cancel(iteration_profile)
    let ratio = (it.to_double() /
    options.learning_rate_decay_iterations.to_double()).min(1.0)
    let lr = c.learning_rate *
      (0.03 + 0.97 * 0.5 * (1.0 + @math.cos(@math.PI * ratio)))
    self.learner.set_learning_rate(lr)
    self.step_accumulator += 1.0 / options.update_to_data
    let collect_steps = self.step_accumulator.to_int()
    self.step_accumulator -= collect_steps.to_double()
    let collection_window = diagnostic_phase_begin(it + 1, "collection")
    errdefer diagnostic_phase_cancel(collection_window)
    @tensor.profile_span("collection.physical", () => {
      self.collect(collect_steps, inspect_env, step_env, options.action_noise)
    })
    if synchronize_sampler is Some(sync) {
      sync()
    }
    let actor_readiness = if it >= options.world_only_iterations {
      Some(
        @tensor.profile_span("collection.actor_readiness", () => {
          self.replay.ensure_actor_ready(
            f => self.motion.clip_end[self.motion.clip_id[f]],
            c.horizon,
            c.wm_window,
            steps => {
              self.collect(steps, inspect_env, step_env, options.action_noise)
            },
            any_need=need => self.learner.any_rank(need),
            after_collect=() => if synchronize_sampler is Some(sync) { sync() },
            context=self.actor_catalog +
              "; iteration=\{it + 1}; rank=" +
              (match self.learner.collective {
                Some(group) => group.rank.to_string()
                None => "0"
              }),
          )
        }),
      )
    } else {
      None
    }
    diagnostic_phase_end(collection_window, it + 1)
    if on_phase is Some(record) {
      record("collection_complete", it + 1)
    }
    let world_window = diagnostic_phase_begin(it + 1, "world")
    errdefer diagnostic_phase_cancel(world_window)
    let mut loss = 0.0
    let mut error = 0.0
    let mut updates = 0
    for world_update in 0..<c.wm_batches {
      let batch = self.learner.prepare_collective("world replay batch", () => {
        @tensor.profile_span("world.sample_prepare_upload", () => {
          sample_world_batch(
            self.learner.backend,
            self.replay,
            c,
            self.rng,
            cuda_device=self.learner.cuda_device,
            limits=self.limits,
            staging_max_bytes=self.world_staging_max_bytes,
            packed_replay=self.world_packed_replay,
          )
        })
      })
      let world_range = if @tensor.operator_diagnostics_enabled() {
        @tensor.operator_range_begin("diag.world.update.\{world_update}")
      } else {
        0L
      }
      errdefer @tensor.operator_range_cancel(world_range)
      let metrics = @tensor.profile_span("world.update", () => {
        self.learner.fit_world_batch(batch)
      })
      @tensor.operator_range_end(world_range)
      loss += metrics.wm_loss
      error += metrics.wm_error_last
      updates += metrics.wm_updates
    }
    let world : @gpu.WorldMetrics = {
      wm_loss: loss / c.wm_batches.to_double(),
      wm_error_last: error / c.wm_batches.to_double(),
      wm_updates: updates,
    }
    self.counters.model_updates += updates.to_int64()
    self.counters.model_fit_transition_slots += c.wm_batches.to_int64() *
      c.wm_batch.to_int64() *
      c.wm_window.to_int64()
    diagnostic_phase_end(world_window, it + 1)
    if on_phase is Some(record) {
      record("world_updates_complete", it + 1)
    }
    let policy = if it >= options.world_only_iterations {
      // The selected window covers the complete policy-update entry, including
      // the unchanged sampling/preparation path. Watchdog I/O stays outside it.
      if @tensor.operator_diagnostic_iteration_selected(it + 1) {
        println(
          "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"started\",\"iteration\":\{it + 1}}",
        )
        @tensor.operator_diagnostic_flush()
      }
      let operator_window = @tensor.operator_diagnostic_iteration_begin(it + 1)
      errdefer @tensor.operator_diagnostic_iteration_cancel(operator_window)
      let iteration_range = if @tensor.operator_diagnostics_enabled() {
        @tensor.operator_range_begin("diag.iteration.\{it + 1}.actor_critic")
      } else {
        0L
      }
      errdefer @tensor.operator_range_cancel(iteration_range)
      let prepare_range = @tensor.operator_range_begin("diag.actor.prepare")
      errdefer @tensor.operator_range_cancel(prepare_range)
      let batch = self.learner.prepare_collective("policy replay batch", () => {
        @tensor.profile_span("actor.sample_prepare_upload", () => {
          sample_policy_batch(
            self.learner.backend,
            self.replay,
            self.motion,
            c,
            self.learner.mode,
            self.rng,
            cuda_device=self.learner.cuda_device,
            default_q=self.default_q,
            limits=self.limits,
            resident_references=self.resident_references,
            noise_staging_max_bytes=self.noise_staging_max_bytes,
          )
        })
      })
      @tensor.operator_range_end(prepare_range)
      let metrics = @tensor.profile_span("actor_critic.update", () => {
        self.learner.update_policy(batch)
      })
      @tensor.operator_range_end(iteration_range)
      @tensor.operator_diagnostic_iteration_end(operator_window)
      if operator_window != 0L {
        println(
          "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"completed\",\"iteration\":\{it + 1}}",
        )
        @tensor.operator_diagnostic_flush()
      }
      self.counters.actor_updates += 1L
      self.counters.critic_updates += metrics.critic_updates.to_int64()
      self.counters.imagined_transitions += metrics.imagined_steps.to_int64()
      Some(metrics)
    } else {
      None
    }
    if on_phase is Some(record) {
      record(
        if policy is Some(_) {
          "actor_critic_complete"
        } else {
          "actor_critic_skipped"
        },
        it + 1,
      )
    }
    self.iteration = it + 1
    // Includes existing on_phase memory observers, excludes the outer metrics
    // callback/checkpoint. Nested durations are inclusive, never additive.
    @tensor.profile_end(iteration_profile)
    on_iteration(
      self.aggregate_metrics({
        iteration: it + 1,
        learning_rate: lr,
        world,
        policy,
        actor_readiness,
      }),
    )
  }
}
