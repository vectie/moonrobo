///|
type NativeCriticGraph

///|
pub struct CriticGraph {
  backend : Backend
  native : NativeCriticGraph
}

///|
pub(all) struct CriticGraphMemory {
  static_bytes : Int64
  retained_gradient_bytes : Int64
  private_pool_reserved_bytes : Int64
  private_pool_allocated_bytes : Int64
  replay_count : Int64
} derive(Debug, ToJson)

///|
#borrow(backend)
extern "c" fn critic_graph_supported_native(backend : Backend) -> Bool = "mr_critic_graph_supported_call"

///|
#borrow(backend, parameters, input, target)
extern "c" fn critic_graph_create_native(
  backend : Backend,
  parameters : FixedArray[NativeTensor],
  input : NativeTensor,
  target : NativeTensor,
  pool_budget : Int64,
  minimum_free : Int64,
) -> NativeCriticGraph = "mr_critic_graph_create_call"

///|
#borrow(backend, graph)
extern "c" fn critic_graph_buffer_native(
  backend : Backend,
  graph : NativeCriticGraph,
  kind : Int32,
) -> NativeTensor = "mr_critic_graph_buffer_call"

///|
#borrow(backend, graph)
extern "c" fn critic_graph_begin_native(
  backend : Backend,
  graph : NativeCriticGraph,
) -> Int32 = "mr_critic_graph_begin_call"

///|
#borrow(backend, graph, loss)
extern "c" fn critic_graph_end_native(
  backend : Backend,
  graph : NativeCriticGraph,
  loss : NativeTensor,
) -> Int32 = "mr_critic_graph_end_call"

///|
#borrow(backend, graph, input, target)
extern "c" fn critic_graph_replay_native(
  backend : Backend,
  graph : NativeCriticGraph,
  input : NativeTensor,
  target : NativeTensor,
) -> NativeTensor = "mr_critic_graph_replay_call"

///|
#borrow(backend, graph, output)
extern "c" fn critic_graph_stats_native(
  backend : Backend,
  graph : NativeCriticGraph,
  output : FixedArray[Int64],
) -> Int32 = "mr_critic_graph_stats_call"

///|
#borrow(backend, graph)
extern "c" fn critic_graph_close_native(
  backend : Backend,
  graph : NativeCriticGraph,
) -> Int32 = "mr_critic_graph_close_call"

///|
/// Checks the complete optional symbol family and CUDA runtime availability.
pub fn Backend::has_critic_cuda_graph(self : Backend) -> Bool {
  critic_graph_supported_native(self)
}

///|
/// Capture deterministic FP32 critic forward, mean squared loss and backward.
/// The synchronous callback must contain only tensor forward operations; no
/// RNG, normalizer updates, parameter mutation, optimizer, tracing or readback.
/// Three warmups and capture do not update parameters/Adam. Each replay resets
/// existing gradients in place. Never call Adam::zero_grad while the graph is
/// live. Close before checkpoint load, parameter replacement or leaving the fit.
/// Native capture begin/end failure poisons graph execution for the process;
/// abort training and restart rather than attempting eager/graph recovery.
/// Unsafe native storage is retained until process exit after such a failure.
/// All graph setup/replay/close calls must be serialized across the process;
/// the current learner uses one synchronous owner thread, not concurrent graphs.
pub fn Backend::capture_critic_graph(
  self : Backend,
  parameters : Array[Tensor],
  input : Tensor,
  target : Tensor,
  forward : (Tensor) -> Tensor raise,
  pool_budget_bytes~ : Int64 = 1073741824L,
  minimum_free_bytes~ : Int64 = 17179869184L,
) -> CriticGraph raise {
  guard self.has_critic_cuda_graph() else {
    raise Native(
      "critic CUDA graph unavailable: matching CUDA graph plugin and CUDA device required",
    )
  }
  let native = critic_graph_create_native(
    self,
    FixedArray::makei(parameters.length(), i => parameters[i].native),
    input.native,
    target.native,
    pool_budget_bytes,
    minimum_free_bytes,
  )
  self.check()
  let graph = CriticGraph::{ backend: self, native, }
  errdefer graph.cancel()
  let static_input = Tensor::{
    backend: self,
    native: critic_graph_buffer_native(self, native, 0),
  }
  self.check()
  let static_target = Tensor::{
    backend: self,
    native: critic_graph_buffer_native(self, native, 1),
  }
  self.check()
  for step in 0..<3 {
    if step > 0 {
      for parameter in parameters {
        parameter.zero_gradient()
      }
    }
    forward(static_input).sub(static_target).square().mean().backward()
  }
  ignore(critic_graph_begin_native(self, native))
  self.check()
  let loss = forward(static_input).sub(static_target).square().mean()
  loss.backward()
  ignore(critic_graph_end_native(self, native, loss.native))
  self.check()
  graph
}

///|
/// Replace this minibatch's gradients and return an independent loss scalar.
pub fn CriticGraph::replay(
  self : CriticGraph,
  input : Tensor,
  target : Tensor,
) -> Tensor raise TensorError {
  let native = critic_graph_replay_native(
    self.backend,
    self.native,
    input.native,
    target.native,
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
pub fn CriticGraph::memory(
  self : CriticGraph,
) -> CriticGraphMemory raise TensorError {
  let out = FixedArray::make(5, 0L)
  ignore(critic_graph_stats_native(self.backend, self.native, out))
  self.backend.check()
  {
    static_bytes: out[0],
    retained_gradient_bytes: out[1],
    private_pool_reserved_bytes: out[2],
    private_pool_allocated_bytes: out[3],
    replay_count: out[4],
  }
}

///|
/// Explicitly drain pending work and release graph-owned storage. Idempotent.
pub fn CriticGraph::close(self : CriticGraph) -> Unit raise TensorError {
  ignore(critic_graph_close_native(self.backend, self.native))
  self.backend.check()
}

///|
/// Cleanup that preserves an earlier error; never used to hide replay failures.
pub fn CriticGraph::cancel(self : CriticGraph) -> Unit {
  ignore(critic_graph_close_native(self.backend, self.native))
}
