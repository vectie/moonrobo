///|
fn state_batch_slice(
  s : @geometry.State,
  start : Int32,
  count : Int32,
) -> @geometry.State raise {
  {
    p: s.p.narrow(0, start, count),
    rotation: s.rotation.narrow(0, start, count),
    v: s.v.narrow(0, start, count),
    w: s.w.narrow(0, start, count),
    q: s.q.narrow(0, start, count),
    qd: s.qd.narrow(0, start, count),
  }
}

///|
fn policy_batch_slice(
  batch : PolicyBatch,
  start : Int32,
  count : Int32,
) -> PolicyBatch raise {
  {
    state: batch.state.narrow(0, start, count),
    previous: batch.previous.narrow(0, start, count),
    xi: batch.xi.narrow(0, start, count),
    history: batch.history.narrow(0, start, count),
    references: batch.references.map(s => state_batch_slice(s, start, count)),
    reference_fk: batch.reference_fk.map(t => t.narrow(1, start, count)),
    goals: batch.goals.map(g => g.narrow(0, start, count)),
    step_noise: batch.step_noise.map(x => x.narrow(0, start, count)),
    // The original logical-batch permutations are used after reassembly only.
    critic_orders: batch.critic_orders,
  }
}

///|
struct ActorChunk {
  loss : @tensor.Tensor
  weighted_reward_sum : @tensor.Tensor
  survival_sum : @tensor.Tensor
  critic_input : @tensor.Tensor?
  rewards : @tensor.Tensor
  failures : @tensor.Tensor
}

///|
// Each chunk keeps the complete H-step graph and tail, backwards once, then
// returns only detached critic data and detached scalar metrics. No activation
// graph is retained between chunks; every tail uses the OLD critic normalizer.
fn Learner::backward_actor_chunk(
  self : Learner,
  batch : PolicyBatch,
  logical_batch : Int32,
  frozen_world : Network,
  frozen_critic : Network,
  train_critic : Bool,
  norms~ : ActorNormSnapshot? = None,
) -> ActorChunk raise {
  let c = self.config
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let n = batch.state.shape()[0]
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
  let actor_forward_timing = @tensor.profile_begin("actor.forward")
  errdefer @tensor.profile_cancel(actor_forward_timing)
  let encoded_goals = if self.optimizations.batch_actor_encoder {
    guard c.horizon <= 32 && n <= 512 else {
      fail("batched actor encoder requires H<=32 and microbatch<=512")
    }
    Some(
      @tensor.operator_span("diag.policy.encoder.batch", () => {
        let goals = self.backend.concat(batch.goals[:c.horizon].to_owned())
        let normalized = match norms {
          Some(norms) => norms.goal.apply(goals)
          None => self.policy.goal_norm.apply(goals)
        }
        self.policy.encoder.forward(normalized).tanh()
      }),
    )
  } else {
    None
  }
  for t in 0..<c.horizon {
    let step_range = if diagnostic {
      @tensor.operator_range_begin("diag.actor.step.\{t}")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(step_range)
    let action = match encoded_goals {
      None => self.policy.forward_actor(history, batch.goals[t], norms)
      Some(encoded) =>
        self.policy.decode_actor(history, encoded.narrow(0, t * n, n), norms)
    }
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
        source_order=self.optimizations.smc_source_order,
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
          source_order=self.optimizations.smc_source_order,
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
  let all_states = concat_states(self.backend, states[1:].to_owned())
  let all_refs = concat_states(self.backend, batch.references[1:].to_owned())
  let cached = if self.optimizations.reuse_geometry {
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
  let reward_range = @tensor.operator_range_begin("diag.actor.reward.batch")
  errdefer @tensor.operator_range_cancel(reward_range)
  let rewards = @tensor.profile_span("actor.reward", () => {
    (match cached {
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
    }).reshape([c.horizon, n])
  })
  @tensor.operator_range_end(reward_range)
  let failures = @tensor.operator_span("diag.actor.soft_failure", () => {
    @tensor.profile_span("actor.soft_failure", () => {
      self.context.soft_failure(all_states, all_refs).reshape([c.horizon, n])
    })
  })
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
          self.context.critic_features(state, batch.references[c.horizon], xi_n)
      },
      batch.goals[c.horizon],
    ],
    axis=-1,
  )
  let tail = self.critic.forward(tail_input, frozen_net=frozen_critic)
  @tensor.profile_end(actor_tail_timing)
  @tensor.operator_range_end(tail_range)
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
  let loss = total.sum().affine(-1.0 / logical_batch.to_double())
  @tensor.operator_span("diag.actor.backward", () => {
    @tensor.profile_span("actor.backward", () => loss.backward())
  })
  let critic_input = if train_critic {
    Some(
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
      .reshape([c.horizon + 1, n, 184 + 73 * c.goal_frames]),
    )
  } else {
    None
  }
  {
    loss: loss.stop_gradient(),
    weighted_reward_sum: (match packed_return {
      Some(packed) => packed.narrow(0, 1, 1).sum()
      None => self.backend.stack(weighted).sum()
    }).stop_gradient(),
    survival_sum: survival.stop_gradient().sum().stop_gradient(),
    critic_input,
    rewards: rewards.stop_gradient(),
    failures: failures.stop_gradient(),
  }
}

///|
fn Learner::update_policy_microbatches(
  self : Learner,
  batch : PolicyBatch,
  logical_batch : Int32,
  train_critic~ : Bool,
  trace~ : CriticTrace? = None,
) -> PolicyMetrics raise {
  let c = self.config
  let diagnostic = @tensor.operator_diagnostics_enabled()
  self.opt_world.zero_grad()
  self.opt_critic.zero_grad()
  self.opt_policy.zero_grad()
  let frozen_world = self.world.net.frozen()
  let frozen_critic = self.critic.net.frozen()
  let norms = self.snapshot_actor_norms()
  let inputs = []
  let rewards = []
  let failures = []
  let metrics = []
  for start = 0; start < logical_batch; {
    let count = self.execution.actor_microbatch.min(logical_batch - start)
    let chunk_range = if diagnostic {
      @tensor.operator_range_begin(
        "diag.actor.chunk.start\{start}.count\{count}",
      )
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(chunk_range)
    let chunk = self.backward_actor_chunk(
      policy_batch_slice(batch, start, count),
      logical_batch,
      frozen_world,
      frozen_critic,
      train_critic,
      norms~,
    )
    metrics.push(chunk.loss)
    metrics.push(chunk.weighted_reward_sum)
    metrics.push(chunk.survival_sum)
    if chunk.critic_input is Some(input) {
      inputs.push(input)
      rewards.push(chunk.rewards)
      failures.push(chunk.failures)
    }
    @tensor.operator_range_end(chunk_range)
    continue start + count
  }
  // Only three detached scalar tensors per chunk survive until this readback.
  // Preserve each scalar's original precision and the CPU Double sum order.
  let values = self.backend.stack(metrics).values()
  metrics.clear()
  let mut loss = 0.0
  let mut reward_sum = 0.0
  let mut survival_sum = 0.0
  for i = 0; i < values.length(); i = i + 3 {
    loss += values[i]
    reward_sum += values[i + 1]
    survival_sum += values[i + 2]
  }
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
  let (critic_loss, critic_loss_last, critic_updates) = if train_critic {
    // Concatenate the B axis BEFORE flattening, restoring the original t-major
    // order for GAE and caller-supplied permutations. No resampling occurs.
    let input = self.backend
      .concat(inputs, axis=1)
      .reshape([-1, 184 + 73 * c.goal_frames])
    let reward = self.backend.concat(rewards, axis=1)
    let failure = self.backend.concat(failures, axis=1)
    // Release chunk storage before the first critic activation graph is built.
    inputs.clear()
    rewards.clear()
    failures.clear()
    self.fit_microbatch_critic(
      input,
      reward,
      failure,
      batch.critic_orders,
      logical_batch,
      frozen_critic,
      trace,
    )
  } else {
    (0.0, 0.0, 0)
  }
  {
    policy_loss: loss,
    critic_loss: critic_loss / critic_updates.max(1).to_double(),
    critic_loss_last,
    imagined_reward: reward_sum / (c.horizon * logical_batch).to_double() / 0.1,
    imagined_survival: survival_sum / logical_batch.to_double(),
    imagined_steps: c.horizon * logical_batch,
    critic_updates,
  }
}

///|
// Readback storage is bounded independently of the configured critic schedule.
// Each entry owns only a detached scalar, never a minibatch activation graph.
priv struct CriticLossMetrics {
  backend : @tensor.Backend
  pending : Array[@tensor.Tensor]
  mut total : Double
  mut last : Double
}

///|
fn CriticLossMetrics::new(backend : @tensor.Backend) -> CriticLossMetrics {
  { backend, pending: [], total: 0.0, last: 0.0, }
}

///|
fn CriticLossMetrics::flush(self : CriticLossMetrics) -> Unit raise {
  if self.pending.is_empty() {
    return
  }
  let values = self.backend.stack(self.pending).values()
  self.pending.clear()
  // Continue the same CPU Double sum across readback boundaries. Summing a
  // block from zero and adding its subtotal would change floating-point order.
  for value in values {
    self.total += value
    self.last = value
  }
}

///|
fn CriticLossMetrics::append(
  self : CriticLossMetrics,
  loss : @tensor.Tensor,
) -> Unit raise {
  self.pending.push(loss.stop_gradient())
  if self.pending.length() == 256 {
    self.flush()
  }
}

///|
fn CriticLossMetrics::finish(self : CriticLossMetrics) -> Double raise {
  self.flush()
  self.total
}

///|
// The critic sees exactly one reconstructed logical trajectory. Its normalizer,
// GAE bootstrap, tensor_split remainder and per-minibatch optimizer schedule are
// unchanged; actor microbatches do not introduce critic optimizer steps.
fn Learner::fit_microbatch_critic(
  self : Learner,
  input : @tensor.Tensor,
  rewards : @tensor.Tensor,
  failures : @tensor.Tensor,
  orders : Array[@tensor.Tensor],
  n : Int32,
  frozen_critic : Network,
  trace : CriticTrace?,
) -> (Double, Double, Int32) raise {
  let c = self.config
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let critic_prepare_timing = @tensor.profile_begin("critic.prepare")
  errdefer @tensor.profile_cancel(critic_prepare_timing)
  let norm_range = @tensor.operator_range_begin("diag.critic.normalizer")
  errdefer @tensor.operator_range_cancel(norm_range)
  self.critic.norm.update(input, collective=self.collective)
  if trace is Some(recorder) {
    recorder.prepare(self, input, rewards, failures, orders)
  }
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
      rewards,
      values,
      failures,
      gamma=c.gamma,
      lam=c.lam,
    )
    .reshape([-1])
    .stop_gradient()
  @tensor.operator_range_end(gae_range)
  if trace is Some(recorder) {
    recorder.targets(values, targets)
  }
  let samples = c.horizon * n
  let inputs = prepared.narrow(0, 0, samples)
  @tensor.profile_end(critic_prepare_timing)
  let losses = CriticLossMetrics::new(self.backend)
  let mut updates = 0
  let graph_cache = if self.optimizations.critic_cuda_graph {
    Some(CriticGraphCache::new(self))
  } else {
    None
  }
  errdefer (if graph_cache is Some(cache) { cache.cancel() })
  for epoch, order in orders {
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
          let prediction_range = @tensor.operator_range_begin(
            "diag.critic.gather_and_forward",
          )
          errdefer @tensor.operator_range_cancel(prediction_range)
          let prediction = @tensor.profile_span("critic.forward", () => {
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
      let adam_range = @tensor.operator_range_begin("diag.critic.adam")
      errdefer @tensor.operator_range_cancel(adam_range)
      @tensor.profile_span("critic.adam", () => {
        self.optimizer_step(self.opt_critic, clip_norm=1.0)
      })
      @tensor.operator_range_end(adam_range)
      if trace is Some(recorder) {
        recorder.after_step(self)
      }
      // The loss storage is scalar; detaching it releases this minibatch's
      // autograd graph before the next forward/backward/Adam update.
      losses.append(vloss)
      updates += 1
      @tensor.operator_range_end(minibatch_range)
    }
  }
  if graph_cache is Some(cache) {
    cache.close()
  }
  let total = losses.finish()
  (total, losses.last, updates)
}
