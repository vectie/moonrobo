///|
// Only callers that have already applied the current, fixed critic statistics
// may use this path. The bootstrap and minibatch trace sees the same normalized
// values as the baseline. There is no cache on Critic itself.
fn Critic::forward_normalized_observed(
  self : Critic,
  normalized : @tensor.Tensor,
  frozen_net : Network?,
  trace : CriticTrace?,
  bootstrap : Bool,
) -> @tensor.Tensor raise {
  let range = @tensor.operator_range_begin("diag.critic.mlp")
  errdefer @tensor.operator_range_cancel(range)
  if trace is Some(recorder) {
    recorder.normalized(normalized, bootstrap)
  }
  let output = frozen_net.unwrap_or(self.net).forward(normalized).reshape([-1])
  @tensor.operator_range_end(range)
  output
}

///|
fn Learner::prepare_critic_inputs(
  self : Learner,
  input : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.optimizations.reuse_critic_normalization {
    self.critic.norm.apply(input).stop_gradient()
  } else {
    input
  }
}

///|
fn Learner::critic_forward_prepared(
  self : Learner,
  input : @tensor.Tensor,
  frozen_net : Network?,
  trace : CriticTrace?,
  bootstrap : Bool,
) -> @tensor.Tensor raise {
  if self.optimizations.reuse_critic_normalization {
    self.critic.forward_normalized_observed(input, frozen_net, trace, bootstrap)
  } else {
    self.critic.forward_observed(input, frozen_net, trace, bootstrap)
  }
}
