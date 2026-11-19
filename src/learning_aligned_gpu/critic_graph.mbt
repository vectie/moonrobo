///|
pub struct CriticGraphDiagnostics {
  mut captures : Int64
  mut replays : Int64
  mut peak_static_bytes : Int64
  mut peak_gradient_bytes : Int64
  mut peak_private_pool_reserved_bytes : Int64
  mut peak_private_pool_allocated_bytes : Int64
} derive(ToJson)

///|
fn CriticGraphDiagnostics::new() -> CriticGraphDiagnostics {
  {
    captures: 0L,
    replays: 0L,
    peak_static_bytes: 0L,
    peak_gradient_bytes: 0L,
    peak_private_pool_reserved_bytes: 0L,
    peak_private_pool_allocated_bytes: 0L,
  }
}

///|
/// Runtime-only graph route evidence. Graphs themselves never enter checkpoints.
pub fn Learner::critic_graph_diagnostics(self : Learner) -> Json {
  self.graph_diagnostics.to_json()
}

///|
fn Learner::validate_graph_samples(
  self : Learner,
  batch_size : Int32,
) -> Unit raise {
  if !self.optimizations.critic_cuda_graph {
    return
  }
  guard batch_size > 0 && self.config.horizon <= 2147483647 / batch_size else {
    fail("critic CUDA graph sample count exceeds supported range")
  }
  let samples = self.config.horizon * batch_size
  let chunks = self.config.critic_minibatches.min(samples)
  guard samples % chunks == 0 else {
    fail(
      "critic CUDA graph G1 requires equal minibatch shapes; no eager remainder fallback",
    )
  }
}

///|
priv struct CriticGraphCache {
  learner : Learner
  mut graph : @tensor.CriticGraph?
}

///|
fn CriticGraphCache::new(learner : Learner) -> CriticGraphCache {
  { learner, graph: None, }
}

///|
fn CriticGraphCache::loss(
  self : CriticGraphCache,
  input : @tensor.Tensor,
  target : @tensor.Tensor,
  trace : CriticTrace?,
) -> @tensor.Tensor raise {
  let normalized = @tensor.profile_span("critic.graph.normalize", () => {
    if self.learner.optimizations.reuse_critic_normalization {
      input
    } else {
      self.learner.critic.norm.apply(input).stop_gradient()
    }
  })
  if trace is Some(recorder) {
    recorder.normalized(normalized, false)
  }
  let graph = match self.graph {
    Some(graph) => graph
    None => {
      let graph = @tensor.profile_span("critic.graph.setup", () => {
        self.learner.backend.capture_critic_graph(
          self.learner.critic.net.parameters(),
          normalized,
          target,
          x => self.learner.critic.net.forward(x).reshape([-1]),
          pool_budget_bytes=1073741824L,
          minimum_free_bytes=17179869184L,
        )
      })
      self.graph = Some(graph)
      self.learner.graph_diagnostics.captures += 1L
      graph
    }
  }
  @tensor.profile_span("critic.graph.replay", () => {
    graph.replay(normalized, target)
  })
}

///|
fn CriticGraphCache::close(self : CriticGraphCache) -> Unit raise {
  if self.graph is Some(graph) {
    let memory = graph.memory()
    let report = self.learner.graph_diagnostics
    report.replays += memory.replay_count
    report.peak_static_bytes = report.peak_static_bytes.max(memory.static_bytes)
    report.peak_gradient_bytes = report.peak_gradient_bytes.max(
      memory.retained_gradient_bytes,
    )
    report.peak_private_pool_reserved_bytes = report.peak_private_pool_reserved_bytes.max(
      memory.private_pool_reserved_bytes,
    )
    report.peak_private_pool_allocated_bytes = report.peak_private_pool_allocated_bytes.max(
      memory.private_pool_allocated_bytes,
    )
    @tensor.profile_span("critic.graph.teardown", () => graph.close())
    self.graph = None
  }
}

///|
fn CriticGraphCache::cancel(self : CriticGraphCache) -> Unit {
  if self.graph is Some(graph) {
    graph.cancel()
    self.graph = None
  }
}
