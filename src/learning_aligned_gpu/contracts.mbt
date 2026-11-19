///|
/// Time axis is second; all flat states are 71D with WXYZ quaternion.
pub(all) struct WorldBatch {
  s : @tensor.Tensor
  s1 : @tensor.Tensor
  actions : @tensor.Tensor
  xi : @tensor.Tensor
  mask : @tensor.Tensor
}

///|
/// References/goals include the final bootstrap frame. History is already noisy.
/// step_noise holds additive sensor noise (not action noise) for each future step.
pub(all) struct PolicyBatch {
  state : @tensor.Tensor
  previous : @tensor.Tensor
  xi : @tensor.Tensor
  history : @tensor.Tensor
  references : Array[@geometry.State]
  reference_fk : @tensor.Tensor?
  goals : Array[@tensor.Tensor]
  step_noise : Array[@tensor.Tensor]
  critic_orders : Array[@tensor.Tensor]
}

///|
pub(all) struct WorldMetrics {
  wm_loss : Double
  wm_error_last : Double
  wm_updates : Int32
}

///|
pub(all) struct PolicyMetrics {
  policy_loss : Double
  critic_loss : Double
  // SMC reports the final critic minibatch, while critic_loss retains our mean.
  critic_loss_last : Double
  imagined_reward : Double
  imagined_survival : Double
  imagined_steps : Int32
  critic_updates : Int32
}
