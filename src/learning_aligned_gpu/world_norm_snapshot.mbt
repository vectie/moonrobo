///|
// A world fitting window never updates running statistics. Reuse their std
// vectors for its eight dependent steps, retaining all state/weight gradients.
priv struct WorldNormSnapshot {
  input : ActorRunningNorm
  output : ActorRunningNorm
}

///|
fn Learner::snapshot_world_norms(self : Learner) -> WorldNormSnapshot? raise {
  if self.optimizations.world_norm_snapshot {
    Some({
      input: self.world.input_norm.actor_snapshot(),
      output: self.world.output_norm.actor_snapshot(),
    })
  } else {
    None
  }
}

///|
fn WorldModel::delta_fitting(
  self : WorldModel,
  inputs : @tensor.Tensor,
  norms : WorldNormSnapshot?,
) -> @tensor.Tensor raise {
  if self.compiled_fitting_mlp is Some(block) {
    return @tensor.operator_span("diag.world.mlp", () => {
      let normalized = match norms {
        Some(n) => n.input.apply(inputs)
        None => self.input_norm.apply(inputs)
      }
      let output = block.forward([normalized, ..self.net.parameters()])
      match norms {
        Some(n) => output.mul(n.output.std).add(n.output.mean)
        None => output.mul(self.output_norm.std()).add(self.output_norm.mean)
      }
    })
  }
  match norms {
    None => self.delta(inputs)
    Some(norms) =>
      @tensor.operator_span("diag.world.mlp", () => {
        self.net
        .forward(norms.input.apply(inputs))
        .mul(norms.output.std)
        .add(norms.output.mean)
      })
  }
}
