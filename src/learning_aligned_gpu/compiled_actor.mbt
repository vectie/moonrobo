///|
// Candidate packages must pass version-matched mathematics and full-update
// gates. Corrected geometry must not be accepted by matching legacy SMC bugs;
// a shared compiled-artifact control checks wiring, not independent accuracy.
// This preparation is outside the 32-step loop; all state/history derivatives
// cross the exported nodes, and all live parameter versions remain guarded.
fn Learner::prepare_compiled_actor_inputs(
  self : Learner,
  batch : PolicyBatch,
  frozen_world : Network,
) -> (@tensor.Tensor, Array[@tensor.Tensor])? raise {
  guard self.compiled_actor_steps is Some(_) else { return None }
  let n = batch.state.shape()[0]
  guard n == 4096 &&
    self.config.horizon == 32 &&
    self.config.hist == 10 &&
    self.config.goal_frames == 10 &&
    self.mode.dim() == 99 &&
    self.config.observation_noise &&
    self.optimizations.mlp_precision == Bf16 &&
    self.collective is None &&
    self.policy.goal_norm.compiled_bf16_input is None &&
    self.policy.obs_norm.compiled_bf16_input is None else {
    fail("compiled actor package requires original full4096 BF16 protocol")
  }
  let frames = self.backend.from_values(
    [32, n],
    Array::makei(32 * n, i => i.to_double()),
    cuda_device=self.cuda_device,
    requires_grad=false,
    dtype=Int64,
  )
  Some(
    (
      frames,
      [
        ..self.policy.parameters(),
        ..frozen_world.parameters(),
        self.policy.obs_norm.mean,
        self.policy.obs_norm.variance,
        self.policy.goal_norm.mean,
        self.policy.goal_norm.variance,
        self.world.input_norm.mean,
        self.world.input_norm.variance,
        self.world.output_norm.mean,
        self.world.output_norm.variance,
        self.backend.concat(batch.references.map(r => r.rotation)),
        self.backend.concat(batch.goals),
        self.backend.concat(batch.step_noise),
        // SMC's live default posture is rank one. The geometry backend keeps
        // a [1, 29] broadcast view; reshape without changing any values.
        self.context.default_joint_positions().reshape([29]),
      ],
    ),
  )
}

///|
// Experimental versioned FP32 reward/termination boundary. Only the frozen
// full4096/H32 signature is admitted; all inputs and derivatives remain live.
fn Learner::run_compiled_actor_reward(
  self : Learner,
  batch : PolicyBatch,
  state : @geometry.State,
  actions : Array[@tensor.Tensor],
  previous : Array[@tensor.Tensor],
) -> (@tensor.Tensor, @tensor.Tensor)? raise {
  guard self.compiled_actor_reward is Some((block, constants)) else {
    return None
  }
  guard self.compiled_actor_steps is Some(_) &&
    self.config.horizon == 32 &&
    batch.state.shape()[0] == 4096 &&
    constants.length() == 5 &&
    self.collective is None &&
    self.optimizations.mlp_precision == Bf16 &&
    self.execution.actor_microbatch == 0 else {
    fail("compiled reward requires original full4096 BF16 protocol")
  }
  let rows = 33 * 4096
  let packed = match batch.reference_fk {
    Some(table) => table.reshape([rows, 14, 18])
    None =>
      self.context
      .pack_reference_bodies(concat_states(self.backend, batch.references))
      .reshape([rows, 14, 18])
  }
  // cat allocates dense outputs for the original graph's stride contract.
  let dense = (t : @tensor.Tensor) => self.backend.concat([t])
  let frames = self.backend.from_values(
    [32 * 4096],
    Array::makei(32 * 4096, i => (i + 4096).to_double()),
    cuda_device=self.cuda_device,
    requires_grad=false,
    dtype=Int64,
  )
  let outputs = block.forward_many([
    constants[0],
    state.rotation,
    state.p,
    constants[1],
    constants[2],
    state.q,
    state.qd,
    state.w,
    state.v,
    self.backend.concat(batch.references.map(s => s.p)),
    frames,
    self.backend.concat(batch.references.map(s => s.rotation)),
    dense(packed.narrow(2, 0, 3)),
    dense(packed.narrow(2, 3, 9)).reshape([rows, 14, 3, 3]),
    dense(packed.narrow(2, 12, 3)),
    dense(packed.narrow(2, 15, 3)),
    self.backend.concat(actions),
    self.backend.concat(previous),
    constants[3],
    constants[4],
  ])
  guard outputs.length() == 2 else { fail("compiled reward output count") }
  Some((outputs[0], outputs[1]))
}

///|
// Detached critic preparation only. The actor's differentiable tail must keep
// its VJP and must never enter this inference-only package.
fn Learner::run_compiled_critic_features(
  self : Learner,
  states : Array[@geometry.State],
  batch : PolicyBatch,
  xi_n : @tensor.Tensor,
) -> @tensor.Tensor? raise {
  guard self.compiled_critic_features is Some(block) else { return None }
  guard self.compiled_actor_reward is Some((_, constants)) &&
    constants.length() == 5 &&
    states.length() == 33 &&
    self.config.horizon == 32 &&
    batch.state.shape()[0] == 4096 &&
    self.optimizations.mlp_precision == Bf16 &&
    self.execution.actor_microbatch == 0 &&
    self.collective is None else {
    fail(
      "compiled critic features require validated original full4096 BF16 protocol",
    )
  }
  let rows = 33 * 4096
  let state = detach_state(concat_states(self.backend, states))
  let reference = detach_state(concat_states(self.backend, batch.references))
  let packed = match batch.reference_fk {
    Some(table) => table.reshape([rows, 14, 18])
    None =>
      self.context.pack_reference_bodies(reference).reshape([rows, 14, 18])
  }
  let frames = self.backend.from_values(
    [rows],
    Array::makei(rows, i => i.to_double()),
    cuda_device=self.cuda_device,
    requires_grad=false,
    dtype=Int64,
  )
  let inputs = [
    state.rotation,
    reference.p,
    frames,
    reference.rotation,
    constants[0],
    state.p,
    constants[1],
    constants[2],
    state.q,
    state.qd,
    state.w,
    state.v,
    self.backend.concat([packed.narrow(2, 0, 3)]),
    reference.q,
    self.backend.concat(Array::make(33, xi_n)),
    self.backend.concat(batch.goals),
  ]
  let result = block.forward(inputs.map(t => t.stop_gradient()))
  guard result.shape() == [rows, 914] else {
    fail("compiled critic features output shape")
  }
  Some(result.stop_gradient())
}
