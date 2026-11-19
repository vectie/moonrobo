///|
pub(all) struct Learner {
  backend : @tensor.Backend
  context : @geometry.Context
  config : @aligned.LearnerConfig
  mode : @aligned.ObservationMode
  cuda_device : Int32
  collective : @tensor.Collective?
  world : WorldModel
  policy : Policy
  critic : Critic
  opt_world : @tensor.Adam
  opt_policy : @tensor.Adam
  opt_critic : @tensor.Adam
  error_floor : @tensor.Tensor
  execution : BatchExecutionPlan
  optimizations : ExecutionOptimizations
  graph_diagnostics : CriticGraphDiagnostics
  // Installed only by an explicitly selected fixed-shape execution profile.
  mut compiled_reference_context : @geometry.Context?
  mut compiled_actor_steps : (@tensor.CompiledBlock, @tensor.CompiledBlock)?
  mut compiled_actor_reward : (@tensor.CompiledBlock, Array[@tensor.Tensor])?
  mut compiled_critic_features : @tensor.CompiledBlock?
  mut smc_gae_order : Bool
  mut smc_adam : Bool
}

///|
pub fn Learner::new(
  backend : @tensor.Backend,
  context : @geometry.Context,
  config~ : @aligned.LearnerConfig = @aligned.LearnerConfig::default(),
  mode~ : @aligned.ObservationMode = Paper,
  cuda_device~ : Int32 = -1,
  seed~ : UInt32 = 1U,
  collective~ : @tensor.Collective? = None,
  world_microbatch~ : Int32 = 0,
  actor_microbatch~ : Int32 = 0,
  optimizations~ : ExecutionOptimizations = ExecutionOptimizations::default(),
) -> Learner raise {
  if cuda_device >= 0 &&
    (
      optimizations.heading_mode == @geometry.OrthonormalAtlas ||
      optimizations.rotation_error_mode == @geometry.GeodesicSquared
    ) {
    guard backend.has_cuda_fp32_control() else {
      fail("corrected geometry requires verified IEEE FP32 matrix arithmetic")
    }
    let precision = backend.cuda_fp32_settings()
    guard precision.matmul_precision == @tensor.IEEE &&
      precision.matmul_permission == @tensor.ContextDisallows else {
      fail(
        "corrected geometry requires allow_tf32=false; BF16 MLPs remain supported",
      )
    }
  }
  if optimizations.batch_actor_encoder {
    guard config.horizon > 0 &&
      config.horizon <= 32 &&
      actor_microbatch > 0 &&
      actor_microbatch <= 512 else {
      fail(
        "batched actor encoder requires H<=32 and actor microbatch in 1..512",
      )
    }
  }
  if optimizations.smc_world_rotation ||
    optimizations.smc_xi_normalization ||
    optimizations.smc_actor_return {
    guard backend.has_smc_algebra() else {
      fail("SMC algebra requires its optional LibTorch extension")
    }
  }
  if optimizations.smc_actor_return {
    let rows = if actor_microbatch > 0 {
      actor_microbatch.min(config.policy_batch)
    } else {
      config.policy_batch
    }
    guard config.horizon <= 64 &&
      config.horizon.to_int64() * rows.to_int64() <= 262144L else {
      fail("SMC actor return exceeds its admitted shape")
    }
  }
  if optimizations.split_actor_return {
    guard backend.has_split_sections() &&
      !optimizations.smc_actor_return &&
      config.horizon > 0 &&
      config.horizon <= 64 else {
      fail(
        "return split requires native split, original sequential return, H<=64",
      )
    }
  }
  if optimizations.split_world_delta {
    guard backend.has_split_sections() else {
      fail("native split extension required")
    }
  }
  if optimizations.fused_axis_rotation || optimizations.fused_skew {
    guard backend.has_fused_rotation() else {
      fail("fused rotation plugin required")
    }
  }
  if optimizations.fused_so3_tail || optimizations.fused_cross_forward {
    guard backend.has_geometry_tail() else {
      fail("geometry tail plugin required")
    }
    guard !optimizations.fused_so3_tail ||
      optimizations.detached_rotation_constants else {
      fail("SO3 tail requires detached constants")
    }
  }
  if optimizations.fused_cross_vjp || optimizations.fused_so3_coefficients {
    guard backend.has_geometry_vjp() else {
      fail("geometry VJP plugin required")
    }
  }
  if optimizations.fused_so3_coefficients_forward ||
    optimizations.split_so3_coefficients {
    guard optimizations.fused_so3_coefficients &&
      (
        !optimizations.fused_so3_coefficients_forward ||
        backend.has_coefficient_forward()
      ) &&
      (!optimizations.split_so3_coefficients || backend.has_split_sections()) else {
      fail("coefficient assembly requires accepted VJP and matching plugin")
    }
  }
  if optimizations.fused_so3_coefficients_full {
    guard optimizations.fused_so3_coefficients &&
      backend.has_coefficient_full_forward() else {
      fail(
        "full coefficient assembly requires accepted VJP and matching plugin",
      )
    }
  }
  if optimizations.compact_skew {
    guard backend.has_compact_rotation() else {
      fail("compact skew plugin required")
    }
  }
  let context = context
    .with_native_cross(optimizations.native_cross)
    .with_cross_preserve_forward(optimizations.native_cross_preserve_forward)
    .with_body_orientation_batched(optimizations.body_orientation_batched)
    .with_sparse_joint_axis(optimizations.sparse_joint_axis)
    .with_rotation_error_mode(optimizations.rotation_error_mode)
    .with_heading_mode(optimizations.heading_mode)
    .with_zero_joint_pivot(optimizations.zero_joint_pivot)
    .with_compact_axis_rotation(optimizations.compact_axis_rotation)
    .with_static_fk_pruning(optimizations.static_fk_pruning)
    .with_compact_heading(optimizations.compact_heading)
    .with_fused_axis_rotation(optimizations.fused_axis_rotation)
    .with_fused_cross_forward(optimizations.fused_cross_forward)
    .with_fused_cross_vjp(optimizations.fused_cross_vjp)
  let execution : BatchExecutionPlan = { world_microbatch, actor_microbatch, }
  execution.validate(config)
  if collective is Some(group) {
    guard group.world_size >= 2 &&
      group.rank >= 0 &&
      group.rank < group.world_size &&
      group.cuda_device == cuda_device &&
      cuda_device >= 0 else {
      fail("native distributed learner requires a matching CUDA communicator")
    }
  }
  guard config.hist > 0 &&
    config.goal_frames > 0 &&
    config.horizon > 0 &&
    config.wm_window > 0 &&
    config.critic_epochs > 0 &&
    config.critic_minibatches > 0 else {
    fail("invalid aligned GPU learner config")
  }
  if optimizations.mlp_precision == Bf16 {
    guard backend.has_bf16_linear() else {
      fail("BF16 MLP precision requested but unavailable in the tensor plugin")
    }
  }
  if optimizations.adam_checked_norm {
    guard backend.has_checked_norm_adam() else {
      fail(
        "checked-norm Adam explicitly requested but unavailable in the tensor plugin",
      )
    }
  }
  if optimizations.critic_cuda_graph {
    guard cuda_device >= 0 && backend.has_critic_cuda_graph() else {
      fail(
        "critic CUDA graph explicitly requested but unavailable for this backend/device",
      )
    }
    guard config.policy_batch > 0 &&
      config.horizon <= 2147483647 / config.policy_batch else {
      fail("critic CUDA graph configured sample count exceeds supported range")
    }
    let samples = config.horizon * config.policy_batch
    guard samples % config.critic_minibatches.min(samples) == 0 else {
      fail("critic CUDA graph G1 requires equal minibatch shapes")
    }
  }
  guard optimizations.gradient_bucket_bytes == 0 ||
    (
      optimizations.gradient_bucket_bytes >= 1048576 &&
      optimizations.gradient_bucket_bytes <= 67108864
    ) else {
    fail("gradient bucket capacity must be zero or between 1 and 64 MiB")
  }
  if optimizations.gradient_bucket_bytes > 0 {
    guard collective is Some(_) && backend.has_gradient_buckets() else {
      fail(
        "gradient buckets require a CUDA collective and optional bucket extension",
      )
    }
  }
  let rng = @numeric.Rng::new(seed)
  let world = WorldModel::new(
    backend,
    rng,
    cuda_device~,
    hidden=config.wm_hidden,
    layer_norm_mode=optimizations.layer_norm_mode,
    linear_mode=optimizations.world_linear_mode,
    mlp_precision=optimizations.mlp_precision,
  )
  let policy = Policy::new(
    backend,
    mode.dim(),
    73 * config.goal_frames,
    rng,
    cuda_device~,
    hist=config.hist,
    hidden=config.policy_hidden,
    linear_mode=optimizations.policy_linear_mode,
    mlp_precision=optimizations.mlp_precision,
    active_joints=context.active_joint_count(),
  )
  let critic = Critic::new(
    backend,
    184 + 73 * config.goal_frames,
    rng,
    cuda_device~,
    hidden=config.critic_hidden,
    linear_mode=optimizations.critic_linear_mode,
    mlp_precision=optimizations.mlp_precision,
  )
  let floor = Array::makei(70, i => {
    if i < 3 {
      0.003
    } else if i < 6 {
      0.005
    } else if i < 9 {
      0.02
    } else if i < 12 {
      0.05
    } else if i < 41 {
      0.003
    } else {
      0.05
    }
  })
  {
    backend,
    context,
    config,
    mode,
    cuda_device,
    collective,
    execution,
    optimizations,
    graph_diagnostics: CriticGraphDiagnostics::new(),
    compiled_actor_steps: None,
    compiled_reference_context: None,
    compiled_actor_reward: None,
    compiled_critic_features: None,
    smc_gae_order: false,
    smc_adam: false,
    world,
    policy,
    critic,
    opt_world: backend.adam(
      world.net.parameters(),
      learning_rate=config.learning_rate,
    ),
    opt_policy: backend.adam(
      policy.parameters(),
      learning_rate=config.learning_rate,
      beta2=0.95,
    ),
    opt_critic: backend.adam(
      critic.net.parameters(),
      learning_rate=config.learning_rate,
    ),
    error_floor: backend.from_values(
      [70],
      floor,
      cuda_device~,
      requires_grad=false,
      dtype=Float32,
    ),
  }
}

///|
pub fn Learner::set_learning_rate(self : Learner, rate : Double) -> Unit raise {
  self.opt_world.set_learning_rate(rate)
  self.opt_policy.set_learning_rate(rate)
  self.opt_critic.set_learning_rate(rate)
}

///|
pub fn Learner::observe(
  self : Learner,
  state : @tensor.Tensor,
  actions : @tensor.Tensor,
  xi : @tensor.Tensor,
  next : @tensor.Tensor,
) -> Unit raise {
  errdefer self.abort_distributed()
  let s = @geometry.State::from_flat71(self.backend, state.stop_gradient())
  let s1 = @geometry.State::from_flat71(self.backend, next.stop_gradient())
  self.world.input_norm.update(
    @geometry.world_inputs(
      self.backend,
      s,
      actions.stop_gradient(),
      self.normalize_xi(xi),
      heading_mode=self.optimizations.heading_mode,
      compact_heading=self.optimizations.compact_heading,
    ),
    collective=self.collective,
  )
  self.world.output_norm.update(
    @geometry.world_targets(
      self.backend,
      s,
      s1,
      heading_mode=self.optimizations.heading_mode,
      compact_heading=self.optimizations.compact_heading,
      smc_rotation=self.optimizations.smc_world_rotation,
    ),
    collective=self.collective,
  )
}

///|
fn time_slice(
  t : @tensor.Tensor,
  step : Int32,
  width : Int32,
) -> @tensor.Tensor raise {
  t.narrow(1, step, 1).reshape([-1, width])
}

///|
pub fn Learner::fit_world_batch(
  self : Learner,
  batch : WorldBatch,
) -> WorldMetrics raise {
  errdefer self.abort_distributed()
  let shape = batch.s.shape()
  guard shape.length() == 3 &&
    shape[0] > 0 &&
    shape[1] == self.config.wm_window &&
    shape[2] == 71 &&
    batch.s1.shape() == shape &&
    batch.actions.shape() == [shape[0], shape[1], 29] &&
    batch.xi.shape() == [shape[0], shape[1], 33] &&
    batch.mask.shape() == [shape[0], shape[1]] else {
    fail("invalid world fitting batch shape")
  }
  let n = shape[0]
  if self.optimizations.world_error_batched {
    guard n.to_int64() * shape[1].to_int64() <= 131072L else {
      fail("batched world error exceeds its 131072-row memory envelope")
    }
  }
  self.assert_same_signature(
    "world batch execution",
    Json(self.execution).stringify() +
    ":" +
    Json(self.optimizations).stringify() +
    ":\{n}:\{shape[1]}",
  )
  if self.execution.world_microbatch > 0 && self.execution.world_microbatch < n {
    return self.fit_world_microbatches(batch, n)
  }
  if self.world.compiled_fitting_window is Some((rollout, error)) {
    guard self.collective is None else {
      fail(
        "compiled world window requires a separately validated distributed signature",
      )
    }
    return self.fit_compiled_world_window(batch, rollout, error)
  }
  let world_forward_timing = @tensor.profile_begin("world.forward")
  errdefer @tensor.profile_cancel(world_forward_timing)
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let mut state = @geometry.State::from_flat71(
    self.backend,
    time_slice(batch.s, 0, 71),
  )
  let std = self.world.output_norm.std().maximum(self.error_floor)
  let norms = self.snapshot_world_norms()
  let errors = []
  let predicted = []
  for j in 0..<shape[1] {
    let step_range = if diagnostic {
      @tensor.operator_range_begin("diag.world.step.\{j}")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(step_range)
    let input_range = @tensor.operator_range_begin("diag.world.inputs")
    errdefer @tensor.operator_range_cancel(input_range)
    let action = time_slice(batch.actions, j, 29)
    let xi_n = self.normalize_xi(time_slice(batch.xi, j, 33))
    let inputs = @geometry.world_inputs(
      self.backend,
      state,
      action,
      xi_n,
      heading_mode=self.optimizations.heading_mode,
      compact_heading=self.optimizations.compact_heading,
    )
    @tensor.operator_range_end(input_range)
    let delta = @tensor.operator_span("diag.world.network", () => {
      self.world.delta_fitting(inputs, norms)
    })
    state = @tensor.operator_span("diag.world.integrate", () => {
      self.context.project_state(
        @geometry.world_integrate(
          self.backend,
          state,
          delta,
          heading_mode=self.optimizations.heading_mode,
          compact_heading=self.optimizations.compact_heading,
          detached_constants=self.optimizations.detached_rotation_constants,
          compact_skew=self.optimizations.compact_skew,
          fused_skew=self.optimizations.fused_skew,
          fused_so3_tail=self.optimizations.fused_so3_tail,
          fused_so3_coefficients=self.optimizations.fused_so3_coefficients,
          fused_so3_coefficients_forward=self.optimizations.fused_so3_coefficients_forward,
          fused_so3_coefficients_full=self.optimizations.fused_so3_coefficients_full,
          split_so3_coefficients=self.optimizations.split_so3_coefficients,
          split_delta=self.optimizations.split_world_delta,
        ),
      )
    })
    let error_range = @tensor.operator_range_begin("diag.world.state_error")
    errdefer @tensor.operator_range_cancel(error_range)
    if self.optimizations.world_error_batched {
      predicted.push(state)
    } else {
      let target = @geometry.State::from_flat71(
        self.backend,
        time_slice(batch.s1, j, 71),
      )
      errors.push(
        @geometry.state_error(
          self.backend,
          state,
          target,
          heading_mode=self.optimizations.heading_mode,
          compact_heading=self.optimizations.compact_heading,
          smc_rotation=self.optimizations.smc_world_rotation,
        )
        .div(std)
        .square()
        .mean_dim(-1),
      )
    }
    @tensor.operator_range_end(error_range)
    @tensor.operator_range_end(step_range)
  }
  if self.optimizations.world_error_batched {
    errors.append(self.batched_world_errors(predicted, batch.s1, std, n))
  }
  let error = self.backend.stack(errors, axis=1)
  let loss = error.mul(batch.mask).sum().affine(1.0 / n.to_double())
  @tensor.profile_end(world_forward_timing)
  self.opt_world.zero_grad()
  @tensor.profile_span("world.backward", () => loss.backward())
  if self.collective is Some(_) {
    @tensor.profile_span("world.communication", () => {
      self.average_gradients(self.world.net.parameters())
    })
  }
  @tensor.profile_span("world.adam", () => {
    self.optimizer_step(self.opt_world, clip_norm=1.0)
  })
  let mask = batch.mask.narrow(1, shape[1] - 1, 1).reshape([n])
  let last = errors[shape[1] - 1]
    .stop_gradient()
    .mul(mask)
    .sum()
    .div(mask.sum().clamp(1.0, 1.0e30))
  @tensor.operator_span("diag.world.metrics_readback", () => {
    wm_loss: loss.values()[0] / shape[1].to_double(),
    wm_error_last: last.values()[0],
    wm_updates: 1,
  })
}

///|
fn concat_states(
  backend : @tensor.Backend,
  states : Array[@geometry.State],
) -> @geometry.State raise {
  {
    p: backend.concat(states.map(s => s.p)),
    rotation: backend.concat(states.map(s => s.rotation)),
    v: backend.concat(states.map(s => s.v)),
    w: backend.concat(states.map(s => s.w)),
    q: backend.concat(states.map(s => s.q)),
    qd: backend.concat(states.map(s => s.qd)),
  }
}

///|
fn detach_state(s : @geometry.State) -> @geometry.State raise {
  {
    p: s.p.stop_gradient(),
    rotation: s.rotation.stop_gradient(),
    v: s.v.stop_gradient(),
    w: s.w.stop_gradient(),
    q: s.q.stop_gradient(),
    qd: s.qd.stop_gradient(),
  }
}

///|
pub fn lambda_returns(
  backend : @tensor.Backend,
  rewards : @tensor.Tensor,
  values : @tensor.Tensor,
  failures : @tensor.Tensor,
  gamma~ : Double = 0.99,
  lam~ : Double = 0.95,
  smc_order~ : Bool = false,
) -> @tensor.Tensor raise {
  let dims = rewards.shape()
  guard dims.length() == 2 &&
    dims[0] > 0 &&
    dims[1] > 0 &&
    failures.shape() == dims &&
    values.shape() == [dims[0] + 1, dims[1]] else {
    fail("invalid tensor GAE shapes")
  }
  let horizon = dims[0]
  let batch = dims[1]
  let out = []
  let mut carry = values.narrow(0, horizon, 1).reshape([batch])
  for k in 0..<horizon {
    let t = horizon - 1 - k
    let next = values.narrow(0, t + 1, 1).reshape([batch])
    let reward = rewards.narrow(0, t, 1).reshape([batch])
    let survive = failures
      .narrow(0, t, 1)
      .reshape([batch])
      .affine(-1.0, bias=1.0)
    let bootstrap = next.affine(1.0 - lam).add(carry.affine(lam))
    carry = reward.add(
      if smc_order {
        survive.affine(gamma).mul(bootstrap)
      } else {
        survive.mul(bootstrap).affine(gamma)
      },
    )
    out.push(carry)
  }
  backend.stack(Array::makei(horizon, i => out[horizon - 1 - i]))
}

///|
pub fn Learner::update_policy(
  self : Learner,
  batch : PolicyBatch,
  train_critic~ : Bool = true,
) -> PolicyMetrics raise {
  // Production mmap catalogs do not have a resident FK table. Build only
  // this batch, one time slice at a time; identical indices are used by the
  // reward, differentiable tail and detached critic. Never cache robot state.
  let batch = if self.compiled_actor_reward is Some(_) &&
    self.optimizations.tail_reference_fk_cache &&
    batch.reference_fk is None {
    guard batch.references.length() == 33 && batch.state.shape() == [4096, 71] else {
      fail("invalid full4096 reference batch")
    }
    guard self.compiled_reference_context is Some(reference) else {
      fail("missing batch-local reference context")
    }
    let table = self.backend.stack(
      batch.references.map(state => reference.pack_reference_bodies(state)),
    )
    { ..batch, reference_fk: Some(table), }
  } else {
    batch
  }
  self.update_policy_impl(batch, train_critic~, trace=None)
}

///|
// The public path always supplies None. Only a package-local diagnostic can
// request bounded observations of the actual existing critic updates.
fn Learner::update_policy_impl(
  self : Learner,
  batch : PolicyBatch,
  train_critic~ : Bool,
  trace~ : CriticTrace?,
) -> PolicyMetrics raise {
  errdefer self.abort_distributed()
  self.assert_same_signature(
    "policy update kind",
    if train_critic {
      "actor-critic"
    } else {
      "actor-only"
    },
  )
  let c = self.config
  let shape = batch.state.shape()
  guard shape.length() == 2 && shape[0] > 0 && shape[1] == 71 else {
    fail("invalid imagined initial state")
  }
  let n = shape[0]
  guard self.compiled_actor_steps is None ||
    self.execution.actor_microbatch == 0 ||
    self.execution.actor_microbatch >= n else {
    fail("compiled full actor package cannot silently use microbatches")
  }
  guard !self.optimizations.tail_reference_fk_cache ||
    (
      batch.reference_fk is Some(_) &&
      (
        self.execution.actor_microbatch == 0 ||
        self.execution.actor_microbatch >= n
      )
    ) else {
    fail(
      "cached critic tail requires a reference cache and an unchunked actor batch",
    )
  }
  guard !self.optimizations.batch_actor_encoder ||
    n > self.execution.actor_microbatch else {
    fail("batched actor encoder requires the microbatch execution path")
  }
  if trace is Some(recorder) {
    recorder.bind(self, n, train_critic)
  }
  if batch.reference_fk is Some(table) {
    guard self.optimizations.reuse_geometry &&
      table.shape() == [c.horizon + 1, n, self.context.reference_body_width()] else {
      fail("reference FK cache requires geometry reuse and [H+1,B,tracked*18]")
    }
  }
  if train_critic {
    self.validate_graph_samples(n)
  }
  guard batch.previous.shape() == [n, 29] &&
    batch.xi.shape() == [n, 33] &&
    batch.history.shape() == [n, c.hist, self.mode.dim()] &&
    batch.references.length() == c.horizon + 1 &&
    batch.goals.length() == c.horizon + 1 &&
    (!c.observation_noise || batch.step_noise.length() == c.horizon) &&
    (!train_critic || batch.critic_orders.length() == c.critic_epochs) else {
    fail("invalid imagined batch/context/noise/permutations")
  }
  for goal in batch.goals {
    guard goal.shape() == [n, 73 * c.goal_frames] else {
      fail("invalid preview goal shape")
    }
  }
  if c.observation_noise {
    for noise in batch.step_noise {
      guard noise.shape() == [n, self.mode.dim()] else {
        fail("invalid sensor noise shape")
      }
    }
  }
  self.assert_same_signature(
    "policy batch execution",
    Json(self.execution).stringify() +
    ":" +
    Json(self.optimizations).stringify() +
    ":\{n}:\{c.horizon}",
  )
  // The real collector masks padded sensors after adding noise. Apply the
  // same projection to the initial replay history for every imagined step.
  let batch = {
    ..batch,
    history: self.context.project_observation(batch.history),
  }
  if self.execution.actor_microbatch > 0 && self.execution.actor_microbatch < n {
    return self.update_policy_microbatches(batch, n, train_critic~, trace~)
  }
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let full_range = if diagnostic {
    @tensor.operator_range_begin("diag.actor.full.count\{n}")
  } else {
    0L
  }
  errdefer @tensor.operator_range_cancel(full_range)
  let setup_timing = @tensor.profile_begin("actor.setup")
  errdefer @tensor.profile_cancel(setup_timing)
  self.opt_world.zero_grad()
  self.opt_critic.zero_grad()
  let frozen_world = self.world.net.frozen()
  let frozen_critic = self.critic.net.frozen()
  let norms = self.snapshot_actor_norms()
  let xi_n = self.normalize_xi(batch.xi.stop_gradient())
  let mut state = @geometry.State::from_flat71(
    self.backend,
    batch.state.stop_gradient(),
  )
  let mut previous = batch.previous.stop_gradient()
  let mut history = batch.history.stop_gradient()
  let states = [state]
  let actions = []
  let previous_actions = []
  let forward_range = @tensor.operator_range_begin("diag.actor.rollout")
  errdefer @tensor.operator_range_cancel(forward_range)
  @tensor.profile_end(setup_timing)
  let actor_forward_timing = @tensor.profile_begin("actor.forward")
  errdefer @tensor.profile_cancel(actor_forward_timing)
  let compiled_inputs = self.prepare_compiled_actor_inputs(batch, frozen_world)
  for t in 0..<c.horizon {
    let step_range = if diagnostic {
      @tensor.operator_range_begin("diag.actor.step.\{t}")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(step_range)
    if compiled_inputs is Some((frames, live)) &&
      self.compiled_actor_steps is Some((initial, recurrent)) {
      let block = if t == 0 { initial } else { recurrent }
      let values = block.forward_many(
        [
          state.p,
          state.rotation,
          state.v,
          state.w,
          state.q,
          state.qd,
          history,
          frames.narrow(0, t, 1).reshape([n]),
          batch.xi,
          xi_n,
          batch.goals[t],
          ..live,
        ],
      )
      guard values.length() == 8 else { fail("compiled actor output count") }
      let action = values[6]
      previous_actions.push(previous)
      actions.push(action)
      state = {
        p: values[0],
        rotation: values[1],
        v: values[2],
        w: values[3],
        q: values[4],
        qd: values[5],
      }
      states.push(state)
      history = values[7]
      // compiled observation boundary
      previous = action
      @tensor.operator_range_end(step_range)
      continue
    }
    let action = self.policy.forward_actor(history, batch.goals[t], norms)
    previous_actions.push(previous)
    actions.push(action)
    let delta = self.world.delta_actor(
      @geometry.world_inputs(
        self.backend,
        state,
        action,
        xi_n,
        heading_mode=self.optimizations.heading_mode,
        compact_heading=self.optimizations.compact_heading,
      ),
      frozen_world,
      norms,
    )
    state = @tensor.operator_span("diag.world.integrate", () => {
      self.context.project_state(
        @geometry.world_integrate(
          self.backend,
          state,
          delta,
          heading_mode=self.optimizations.heading_mode,
          compact_heading=self.optimizations.compact_heading,
          detached_constants=self.optimizations.detached_rotation_constants,
          compact_skew=self.optimizations.compact_skew,
          fused_skew=self.optimizations.fused_skew,
          fused_so3_tail=self.optimizations.fused_so3_tail,
          fused_so3_coefficients=self.optimizations.fused_so3_coefficients,
          fused_so3_coefficients_forward=self.optimizations.fused_so3_coefficients_forward,
          fused_so3_coefficients_full=self.optimizations.fused_so3_coefficients_full,
          split_so3_coefficients=self.optimizations.split_so3_coefficients,
          split_delta=self.optimizations.split_world_delta,
        ),
      )
    })
    states.push(state)
    let mut obs = self.context.observation(
      state,
      action,
      batch.xi,
      batch.references[t + 1],
      self.mode,
    )
    if c.observation_noise {
      obs = obs.add(batch.step_noise[t])
    }
    obs = self.context.project_observation(obs)
    history = self.backend.concat(
      [history.narrow(1, 1, c.hist - 1), obs.reshape([n, 1, self.mode.dim()])],
      axis=1,
    )
    previous = action
    @tensor.operator_range_end(step_range)
  }
  @tensor.profile_end(actor_forward_timing)
  @tensor.operator_range_end(forward_range)
  let pack_timing = @tensor.profile_begin("actor.pack")
  errdefer @tensor.profile_cancel(pack_timing)
  let all_states = concat_states(self.backend, states[1:].to_owned())
  let all_refs = concat_states(self.backend, batch.references[1:].to_owned())
  let cached = if self.optimizations.reuse_geometry &&
    self.compiled_actor_reward is None {
    Some(
      @tensor.profile_span("actor.geometry", () => {
        self.context.tracking_geometry_cached(
          all_states,
          all_refs,
          batch.reference_fk.map(t => {
            t
            .narrow(0, 1, c.horizon)
            .reshape([-1, self.context.reference_body_width()])
          }),
        )
      }),
    )
  } else {
    None
  }
  @tensor.profile_end(pack_timing)
  let reward_timing = @tensor.profile_begin("actor.reward")
  errdefer @tensor.profile_cancel(reward_timing)
  let reward_range = @tensor.operator_range_begin("diag.actor.reward.batch")
  errdefer @tensor.operator_range_cancel(reward_range)
  let compiled_reward = self.run_compiled_actor_reward(
    batch, all_states, actions, previous_actions,
  )
  let rewards = @tensor.profile_span("actor.reward.result_view", () => {
    (match compiled_reward {
      Some((reward, _)) => reward
      None =>
        match cached {
          Some(tracking) =>
            tracking.reward(
              self.backend.concat(actions),
              self.backend.concat(previous_actions),
            )
          None =>
            self.context.reward(
              all_states,
              all_refs,
              self.backend.concat(actions),
              self.backend.concat(previous_actions),
            )
        }
    }).reshape([c.horizon, n])
  })
  @tensor.operator_range_end(reward_range)
  let failures = @tensor.operator_span("diag.actor.soft_failure", () => {
    (match compiled_reward {
      Some((_, failure)) => failure
      None => self.context.soft_failure(all_states, all_refs)
    }).reshape([c.horizon, n])
  })
  @tensor.profile_end(reward_timing)
  let return_timing = @tensor.profile_begin("actor.return")
  errdefer @tensor.profile_cancel(return_timing)
  let return_range = @tensor.operator_range_begin("diag.actor.return")
  errdefer @tensor.operator_range_cancel(return_range)
  let mut survival = self.backend.from_values(
    [n],
    Array::make(n, 1.0),
    cuda_device=self.cuda_device,
    requires_grad=false,
    dtype=Float32,
  )
  let mut objective = survival.affine(0.0)
  let weighted = []
  // Same chronological recurrence and discount arithmetic. One split per
  // sequence avoids H independent full-size scatter/add backward paths.
  let reward_parts = if self.optimizations.split_actor_return {
    Some(rewards.split_sections(Array::make(c.horizon, 1), axis=0))
  } else {
    None
  }
  let failure_parts = if self.optimizations.split_actor_return {
    Some(failures.split_sections(Array::make(c.horizon, 1), axis=0))
  } else {
    None
  }
  for t in 0..<(if self.optimizations.smc_actor_return { 0 } else { c.horizon }) {
    let reward = (match reward_parts {
      Some(parts) => parts[t]
      None => rewards.narrow(0, t, 1)
    }).reshape([n])
    let contribution = survival.mul(reward)
    weighted.push(contribution.stop_gradient())
    objective = objective.add(
      contribution.affine(@math.pow(c.gamma, t.to_double())),
    )
    survival = survival.mul(
      (match failure_parts {
        Some(parts) => parts[t]
        None => failures.narrow(0, t, 1)
      })
      .reshape([n])
      .affine(-1.0, bias=1.0),
    )
  }
  @tensor.operator_range_end(return_range)
  @tensor.profile_end(return_timing)
  let tail_range = @tensor.operator_range_begin("diag.critic.tail")
  errdefer @tensor.operator_range_cancel(tail_range)
  let actor_tail_timing = @tensor.profile_begin("actor.tail")
  errdefer @tensor.profile_cancel(actor_tail_timing)
  let tail_input = self.backend.concat(
    [
      match cached {
        Some(tracking) =>
          tracking.narrow((c.horizon - 1) * n, n).critic_features(xi_n)
        None =>
          if self.optimizations.tail_reference_fk_cache {
            guard batch.reference_fk is Some(reference_fk) else {
              fail("tail reference FK reuse requires the batch reference cache")
            }
            self.context.critic_features_cached_reference(
              state,
              batch.references[c.horizon],
              xi_n,
              reference_fk
              .narrow(0, c.horizon, 1)
              .reshape([n, self.context.reference_body_width()]),
            )
          } else {
            self.context.critic_features(
              state,
              batch.references[c.horizon],
              xi_n,
            )
          }
      },
      batch.goals[c.horizon],
    ],
    axis=-1,
  )
  let tail = self.critic.forward(tail_input, frozen_net=frozen_critic)
  @tensor.profile_end(actor_tail_timing)
  @tensor.operator_range_end(tail_range)
  let final_return_timing = @tensor.profile_begin("actor.return")
  errdefer @tensor.profile_cancel(final_return_timing)
  let packed_return = if self.optimizations.smc_actor_return {
    Some(rewards.actor_return_smc(failures, tail, c.gamma))
  } else {
    None
  }
  let total = match packed_return {
    Some(packed) => {
      survival = packed.narrow(0, 2, 1).reshape([n])
      packed.narrow(0, 0, 1).reshape([n])
    }
    None =>
      objective.add(
        survival.mul(tail).affine(@math.pow(c.gamma, c.horizon.to_double())),
      )
  }
  let loss = total.mean().affine(-1.0)
  self.opt_policy.zero_grad()
  @tensor.profile_end(final_return_timing)
  @tensor.operator_span("diag.actor.backward", () => {
    @tensor.profile_span("actor.backward", () => loss.backward())
  })
  if self.collective is Some(_) {
    @tensor.profile_span("actor.communication", () => {
      self.average_gradients(self.policy.parameters())
    })
  }
  let adam_range = @tensor.operator_range_begin("diag.actor.adam")
  errdefer @tensor.operator_range_cancel(adam_range)
  @tensor.profile_span("actor.adam", () => {
    self.optimizer_step(self.opt_policy, clip_norm=1.0, clip_value=0.1)
  })
  @tensor.operator_range_end(adam_range)
  let mut critic_loss = 0.0
  let mut critic_loss_last = 0.0
  let mut critic_updates = 0
  let deferred_losses = if self.optimizations.defer_scalar_metrics {
    Some(CriticLossMetrics::new(self.backend))
  } else {
    None
  }
  if train_critic {
    let critic_prepare_timing = @tensor.profile_begin("critic.prepare")
    errdefer @tensor.profile_cancel(critic_prepare_timing)
    let input = match self.run_compiled_critic_features(states, batch, xi_n) {
      Some(input) => input
      None =>
        self.backend
        .concat(
          [
            self.imagined_critic_features(
              states,
              batch.references,
              xi_n,
              cached,
              reference_fk=batch.reference_fk,
            ),
            self.backend.concat(batch.goals),
          ],
          axis=-1,
        )
        .stop_gradient()
    }
    let norm_range = @tensor.operator_range_begin("diag.critic.normalizer")
    errdefer @tensor.operator_range_cancel(norm_range)
    self.critic.norm.update(input, collective=self.collective)
    if trace is Some(recorder) {
      recorder.prepare(self, input, rewards, failures, batch.critic_orders)
    }
    // Targets are produced after norm update and before any critic optimizer step.
    let prepared = self.prepare_critic_inputs(input)
    @tensor.operator_range_end(norm_range)
    let bootstrap_range = @tensor.operator_range_begin("diag.critic.bootstrap")
    errdefer @tensor.operator_range_cancel(bootstrap_range)
    let values = self
      .critic_forward_prepared(prepared, Some(frozen_critic), trace, true)
      .reshape([c.horizon + 1, n])
      .stop_gradient()
    @tensor.operator_range_end(bootstrap_range)
    let gae_range = @tensor.operator_range_begin("diag.critic.gae")
    errdefer @tensor.operator_range_cancel(gae_range)
    let targets = lambda_returns(
        self.backend,
        rewards.stop_gradient(),
        values,
        failures.stop_gradient(),
        gamma=c.gamma,
        lam=c.lam,
        smc_order=self.smc_gae_order,
      )
      .reshape([-1])
      .stop_gradient()
    @tensor.operator_range_end(gae_range)
    if trace is Some(recorder) {
      recorder.targets(values, targets)
    }
    let inputs = prepared.narrow(0, 0, c.horizon * n)
    let samples = c.horizon * n
    @tensor.profile_end(critic_prepare_timing)
    let graph_cache = if self.optimizations.critic_cuda_graph {
      Some(CriticGraphCache::new(self))
    } else {
      None
    }
    errdefer (if graph_cache is Some(cache) { cache.cancel() })
    for epoch, order in batch.critic_orders {
      guard order.shape() == [samples] && order.dtype() == Int64 else {
        fail("invalid critic permutation shape/dtype")
      }
      let chunks = c.critic_minibatches.min(samples)
      for chunk in 0..<chunks {
        let minibatch_range = if diagnostic {
          @tensor.operator_range_begin(
            "diag.critic.epoch\{epoch}.minibatch\{chunk}",
          )
        } else {
          0L
        }
        errdefer @tensor.operator_range_cancel(minibatch_range)
        // torch.tensor_split puts remainder samples in the earliest chunks.
        let width = samples / chunks
        let remainder = samples % chunks
        let from = chunk * width + chunk.min(remainder)
        let length = width + (if chunk < remainder { 1 } else { 0 })
        let index = order.narrow(0, from, length)
        let (vloss, target) = match graph_cache {
          Some(cache) => {
            let target = targets.index_select(index)
            (cache.loss(inputs.index_select(index), target, trace), target)
          }
          None => {
            let critic_forward_timing = @tensor.profile_begin("critic.forward")
            errdefer @tensor.profile_cancel(critic_forward_timing)
            let prediction_range = @tensor.operator_range_begin(
              "diag.critic.gather_and_forward",
            )
            errdefer @tensor.operator_range_cancel(prediction_range)
            let prediction = @tensor.profile_span("critic.network", () => {
              self.critic_forward_prepared(
                inputs.index_select(index),
                None,
                trace,
                false,
              )
            })
            @tensor.operator_range_end(prediction_range)
            let target = @tensor.operator_span("diag.critic.target_gather", () => {
              targets.index_select(index)
            })
            let vloss = @tensor.operator_span("diag.critic.loss", () => {
              prediction.sub(target).square().mean()
            })
            @tensor.profile_end(critic_forward_timing)
            self.opt_critic.zero_grad()
            @tensor.operator_span("diag.critic.backward", () => {
              @tensor.profile_span("critic.backward", () => vloss.backward())
            })
            (vloss, target)
          }
        }
        if self.collective is Some(_) {
          @tensor.profile_span("critic.communication", () => {
            self.average_gradients(self.critic.net.parameters())
          })
        }
        if trace is Some(recorder) {
          recorder.before_step(self, index, target, vloss)
        }
        let critic_adam_range = @tensor.operator_range_begin("diag.critic.adam")
        errdefer @tensor.operator_range_cancel(critic_adam_range)
        @tensor.profile_span("critic.adam", () => {
          self.optimizer_step(self.opt_critic, clip_norm=1.0)
        })
        @tensor.operator_range_end(critic_adam_range)
        if trace is Some(recorder) {
          recorder.after_step(self)
        }
        match deferred_losses {
          Some(losses) => losses.append(vloss)
          None => {
            critic_loss_last = vloss.values()[0]
            critic_loss += critic_loss_last
          }
        }
        critic_updates += 1
        @tensor.operator_range_end(minibatch_range)
      }
    }
    if graph_cache is Some(cache) {
      cache.close()
    }
  }
  if deferred_losses is Some(losses) {
    critic_loss = losses.finish()
    critic_loss_last = losses.last
  }
  @tensor.operator_range_end(full_range)
  {
    policy_loss: loss.values()[0],
    critic_loss: critic_loss / critic_updates.max(1).to_double(),
    critic_loss_last,
    imagined_reward: (match packed_return {
      Some(packed) =>
        packed.narrow(0, 1, 1).mean().affine(1.0 / c.horizon.to_double())
      None => self.backend.stack(weighted).mean()
    }).values()[0] /
    0.1,
    imagined_survival: survival.stop_gradient().mean().values()[0],
    imagined_steps: c.horizon * n,
    critic_updates,
  }
}
