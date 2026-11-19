///|
// Communication execution modes share exactly the same call sites, parameter
// order and averaging/clipping order. Zero keeps the original per-parameter
// collective; an explicit bucket capacity enables the bounded candidate.
fn Learner::average_gradients(
  self : Learner,
  parameters : Array[@tensor.Tensor],
) -> Unit raise {
  if self.collective is Some(group) {
    if self.optimizations.gradient_bucket_bytes == 0 {
      group.average_gradients(parameters)
    } else {
      group.average_gradients_bucketed(
        parameters,
        bucket_bytes=self.optimizations.gradient_bucket_bytes,
      )
    }
  }
}
