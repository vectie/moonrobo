///|
// RunningNorm update/restore rebinds its tensors. A snapshot owns the current
// mean and computed std only for one logical actor update; it is never stored
// on the network/learner or serialized. Running statistics have no gradients.
priv struct ActorRunningNorm {
  mean : @tensor.Tensor
  std : @tensor.Tensor
  variance : @tensor.Tensor
  compiled_bf16_input : @tensor.CompiledBlock?
}

///|
fn RunningNorm::actor_snapshot(self : RunningNorm) -> ActorRunningNorm raise {
  guard self.compiled_bf16_input is None || self.eps == 0.01 else {
    fail("compiled BF16 normalization requires the exported epsilon")
  }
  {
    mean: self.mean,
    std: self.std(),
    variance: self.variance,
    compiled_bf16_input: self.compiled_bf16_input,
  }
}

///|
fn ActorRunningNorm::apply(
  self : ActorRunningNorm,
  values : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.compiled_bf16_input is Some(block) {
    return block.forward([values, self.mean, self.variance])
  }
  // Keep subtraction and division separate and in the original order.
  values.sub(self.mean).div(self.std)
}

///|
priv struct ActorNormSnapshot {
  goal : ActorRunningNorm
  observation : ActorRunningNorm
  world_input : ActorRunningNorm
  world_output : ActorRunningNorm
}

///|
fn Learner::snapshot_actor_norms(self : Learner) -> ActorNormSnapshot? raise {
  if self.optimizations.actor_norm_snapshot {
    Some(
      @tensor.profile_span("actor.norm_snapshot", () => {
        goal: self.policy.goal_norm.actor_snapshot(),
        observation: self.policy.obs_norm.actor_snapshot(),
        world_input: self.world.input_norm.actor_snapshot(),
        world_output: self.world.output_norm.actor_snapshot(),
      }),
    )
  } else {
    None
  }
}

///|
fn Policy::forward_actor(
  self : Policy,
  history : @tensor.Tensor,
  goals : @tensor.Tensor,
  norms : ActorNormSnapshot?,
) -> @tensor.Tensor raise {
  match norms {
    None => self.forward(history, goals)
    Some(norms) => {
      let batch = history.shape()[0]
      let encoder_range = @tensor.operator_range_begin("diag.policy.encoder")
      errdefer @tensor.operator_range_cancel(encoder_range)
      let z = self.encoder.forward(norms.goal.apply(goals)).tanh()
      @tensor.operator_range_end(encoder_range)
      let h = norms.observation
        .apply(history)
        .reshape([batch, self.hist * self.obs_dim])
      let decoder_range = @tensor.operator_range_begin("diag.policy.decoder")
      errdefer @tensor.operator_range_cancel(decoder_range)
      let output = self.decoder.forward(self.backend.concat([z, h], axis=-1))
      @tensor.operator_range_end(decoder_range)
      self.project_actions(output)
    }
  }
}

///|
fn Policy::decode_actor(
  self : Policy,
  history : @tensor.Tensor,
  encoded : @tensor.Tensor,
  norms : ActorNormSnapshot?,
) -> @tensor.Tensor raise {
  let h = (match norms {
    Some(norms) => norms.observation.apply(history)
    None => self.obs_norm.apply(history)
  }).reshape([history.shape()[0], self.hist * self.obs_dim])
  @tensor.operator_span("diag.policy.decoder", () => {
    self.project_actions(
      self.decoder.forward(self.backend.concat([encoded, h], axis=-1)),
    )
  })
}

///|
fn WorldModel::delta_actor(
  self : WorldModel,
  inputs : @tensor.Tensor,
  frozen_net : Network,
  norms : ActorNormSnapshot?,
) -> @tensor.Tensor raise {
  match norms {
    None => self.delta(inputs, frozen_net~)
    Some(norms) => {
      let range = @tensor.operator_range_begin("diag.world.mlp")
      errdefer @tensor.operator_range_cancel(range)
      let output = frozen_net
        .forward(norms.world_input.apply(inputs))
        .mul(norms.world_output.std)
        .add(norms.world_output.mean)
      @tensor.operator_range_end(range)
      output
    }
  }
}
