///|
// Package-local fixed-input seams exercise the same learner core with the cheap
// differentiable heads from the preserved upstream tests. Ordinary training
// always uses its physical Context; no alternative heads enter checkpoints.
priv struct FixedLearningHeads {
  observation : (@geometry.State, @tensor.Tensor) -> @tensor.Tensor raise
  reward : (@geometry.State, @tensor.Tensor, @tensor.Tensor) -> @tensor.Tensor raise
  soft_failure : (@geometry.State) -> @tensor.Tensor raise
  critic_features : (@geometry.State) -> @tensor.Tensor raise
}

///|
priv enum UpdatePhase {
  World
  Actor
  CriticStep(Int32)
}

///|
priv struct UpdateObserver {
  observe : (UpdatePhase, Bool, Array[@tensor.Tensor], @tensor.Adam) -> Unit raise
}

///|
fn Learner::observed_parameters(
  self : Learner,
  phase : UpdatePhase,
) -> Array[@tensor.Tensor] {
  match phase {
    World => self.world.net.parameters()
    Actor => self.policy.parameters()
    CriticStep(_) => self.critic.net.parameters()
  }
}
