///|
// All paths call this after distributed averaging and outside graph capture.
// The original optimizer operation remains the exact default route.
fn Learner::optimizer_step(
  self : Learner,
  optimizer : @tensor.Adam,
  clip_norm~ : Double,
  clip_value~ : Double = 0.0,
  observer~ : UpdateObserver? = None,
  phase~ : UpdatePhase = World,
) -> Unit raise {
  if observer is Some(listener) {
    (listener.observe)(phase, false, self.observed_parameters(phase), optimizer)
  }
  if self.smc_adam {
    optimizer.step_smc(clip_norm~, clip_value~)
  } else if self.optimizations.adam_checked_norm {
    optimizer.step_checked_norm(clip_norm~, clip_value~)
  } else {
    optimizer.step(clip_norm~, clip_value~)
  }
  if observer is Some(listener) {
    (listener.observe)(phase, true, self.observed_parameters(phase), optimizer)
  }
}
