// Optional ABI-2 critic F+B graph. CPU builds retain the symbols but explicitly
// report unsupported. CUDA builds must opt in with matching PyTorch/CUDA headers.
// G1 is a process-serialized API. Owner/claim checks reject observed misuse;
// they are not a general concurrent graph-operation scheduler.
#if defined(MR_ENABLE_CUDA_GRAPH) && MR_ENABLE_CUDA_GRAPH
#include <ATen/cuda/CUDAGraph.h>
#include <ATen/cuda/CUDAEvent.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDACachingAllocator.h>
#include <atomic>
static_assert(TORCH_VERSION_MAJOR == 2 && TORCH_VERSION_MINOR == 11,
              "CUDA graph extension is audited against PyTorch 2.11");
namespace {
struct CriticGraph;
std::mutex critic_graph_capture_mutex;
CriticGraph *active_critic_graph = nullptr;
// PyTorch 2.11 capture failures can leave allocator/generator registration
// incomplete. There is no supported in-process recovery; stop graph training.
std::atomic<bool> critic_graph_process_poisoned{false};
void require_graph_process_healthy() {
  if (critic_graph_process_poisoned.load())
    throw std::runtime_error("critic CUDA graph process poisoned by failed capture begin/end or cleanup; abort training and restart the process");
}
struct CriticGraph {
  std::thread::id owner = std::this_thread::get_id();
  int device;
  c10::cuda::CUDAStream stream;
  std::unique_ptr<c10::cuda::CUDAStreamGuard> stream_guard;
  at::cuda::CUDAGraph graph;
  torch::Tensor input, target, loss;
  std::vector<torch::Tensor> parameters, gradients;
  std::vector<void *> parameter_addresses, gradient_addresses;
  int64_t pool_budget, static_bytes = 0, gradient_bytes = 0;
  int64_t pool_reserved = 0, pool_allocated = 0, replays = 0;
  bool capturing = false, ready = false, closed = false;
  bool claimed_scope = false, setup_work_started = false;
  explicit CriticGraph(int d, int64_t budget)
      : device(d), stream(c10::cuda::getStreamFromPool(false, d)), pool_budget(budget) {}
  void check_owner() {
    if (owner != std::this_thread::get_id())
      throw std::invalid_argument("critic CUDA graph must stay on its creating OS thread");
    if (closed) throw std::invalid_argument("critic CUDA graph is closed");
  }
  void release_scope() {
    stream_guard.reset();
    std::lock_guard<std::mutex> lock(critic_graph_capture_mutex);
    if (active_critic_graph == this) active_critic_graph = nullptr;
    claimed_scope = false;
  }
  void poison_capture() noexcept {
    critic_graph_process_poisoned.store(true);
    ready = false;
    capturing = false;
    // Restore the owner thread's stream, but never retry capture_end/reset or
    // drain/free GPU state after a partial ATen capture failure. The originating
    // exception is retained by the caller, and this graph remains allocated.
    try { release_scope(); } catch (...) {}
  }
  void finish_capture() {
    try { graph.capture_end(); }
    catch (...) { poison_capture(); throw; }
    capturing = false;
  }
  void validate_addresses() {
    for (size_t i = 0; i < parameters.size(); ++i) {
      auto &p = parameters[i];
      if (p.data_ptr() != parameter_addresses[i] || !p.grad().defined() ||
          p.grad().data_ptr() != gradient_addresses[i])
        throw std::invalid_argument("critic CUDA graph parameter/gradient storage changed; invalidate before checkpoint load or zero_grad(set_to_none)");
    }
  }
  void sample_pool() {
    auto snapshot = c10::cuda::CUDACachingAllocator::get()->snapshot(graph.pool(), false);
    pool_reserved = 0; pool_allocated = 0;
    for (auto &segment : snapshot.segments) {
      if (segment.device == device && segment.owner_private_pool_id == graph.pool()) {
        pool_reserved += static_cast<int64_t>(segment.total_size);
        pool_allocated += static_cast<int64_t>(segment.allocated_size);
      }
    }
    if (pool_reserved > pool_budget)
      throw std::runtime_error("critic CUDA graph private pool exceeds admitted budget");
  }
  void close() {
    if (closed) return;
    check_owner();
    {
      std::lock_guard<std::mutex> lock(critic_graph_capture_mutex);
      if (active_critic_graph && active_critic_graph != this)
        throw std::runtime_error("cannot drain a critic CUDA graph while another graph is constructing/capturing");
      // Hold a teardown claim until after the final drain/free, so a concurrent
      // constructor cannot start capture between stream restoration and sync.
      active_critic_graph = this; claimed_scope = true;
    }
    if (critic_graph_process_poisoned.load()) {
      release_scope();
      require_graph_process_healthy();
    }
    if (capturing) {
      finish_capture();
    }
    stream_guard.reset();
    // Teardown is outside the measured replay interval. Drain all graph uses
    // before releasing static/private-pool storage, including exception paths.
    try {
      if (setup_work_started) {
        c10::cuda::CUDAGuard guard(device);
        C10_CUDA_CHECK(cudaDeviceSynchronize());
      }
      graph.reset();
      loss = torch::Tensor(); input = torch::Tensor(); target = torch::Tensor();
      parameters.clear(); gradients.clear();
    } catch (...) { poison_capture(); throw; }
    release_scope();
    closed = true; ready = false;
  }
  ~CriticGraph() {
    try { close(); } catch (...) {}
  }
};
struct CriticGraphDeleter {
  void operator()(CriticGraph *g) const noexcept {
    if (!g) return;
    // Construction can also fail after asynchronous setup work has started.
    // A failed drain must retain storage, just like explicit handle teardown.
    try { g->close(); } catch (...) { return; }
    delete g;
  }
};
CriticGraph &critic_graph(void *p) {
  if (!p) throw std::invalid_argument("empty critic CUDA graph handle");
  auto &g = *static_cast<CriticGraph *>(p); g.check_owner();
  require_graph_process_healthy();
  {
    std::lock_guard<std::mutex> lock(critic_graph_capture_mutex);
    if (active_critic_graph && active_critic_graph != &g)
      throw std::runtime_error("critic CUDA graph operation overlaps another capture scope");
  }
  return g;
}
void graph_check_input(const torch::Tensor &x, const torch::Tensor &target) {
  if (!x.is_cuda() || x.dim() != 2 || x.size(0) < 1 || x.size(1) < 1 ||
      target.dim() != 1 || target.size(0) != x.size(0) ||
      target.device() != x.device() || x.scalar_type() != torch::kFloat32 ||
      target.scalar_type() != torch::kFloat32 || !x.is_contiguous() || !target.is_contiguous())
    throw std::invalid_argument("critic CUDA graph requires contiguous FP32 [batch,width] input and [batch] target on one CUDA device");
}
}
extern "C" int mr_critic_graph_supported_v1() { return mr_tensor_device_count() > 0; }
extern "C" void *mr_critic_graph_create_v1(void **parameters, int count, void *input,
                                           void *target, int64_t pool_budget,
                                           int64_t minimum_free, char *err, int cap) {
  try {
    if (count < 1 || count > 4096 || pool_budget < 1048576 || pool_budget > 4LL*1024*1024*1024 || minimum_free < 0)
      throw std::invalid_argument("invalid critic CUDA graph parameter count or memory budget");
    auto &x = unbox(input); auto &y = unbox(target); graph_check_input(x, y);
    int device = x.get_device();
    std::unique_ptr<CriticGraph, CriticGraphDeleter> g;
    {
      std::lock_guard<std::mutex> lock(critic_graph_capture_mutex);
      require_graph_process_healthy();
      if (active_critic_graph) throw std::runtime_error("overlapping critic CUDA graph construction is prohibited");
      // Check and claim while holding the lock BEFORE stream acquisition or any
      // allocation, gradient mutation or setup work. Rejected overlap has no
      // temporary graph whose destructor could synchronize an active capture.
      g.reset(new CriticGraph(device, pool_budget));
      active_critic_graph = g.get(); g->claimed_scope = true;
    }
    std::unordered_set<void *> unique;
    for (int i = 0; i < count; ++i) {
      auto &p = unbox(parameters[i]);
      if (!p.is_leaf() || !p.requires_grad() || !p.is_contiguous() || p.scalar_type() != torch::kFloat32 || p.device() != x.device() || !unique.insert(p.unsafeGetTensorImpl()).second)
        throw std::invalid_argument("critic CUDA graph requires distinct contiguous FP32 leaf parameters on input device");
      g->parameters.push_back(p); g->parameter_addresses.push_back(p.data_ptr());
      g->gradient_bytes += p.numel() * p.element_size();
    }
    g->static_bytes = (x.numel() + y.numel()) * x.element_size();
    if (g->static_bytes > 1024LL*1024*1024 || g->gradient_bytes > 1024LL*1024*1024)
      throw std::invalid_argument("critic CUDA graph static/gradient payload exceeds bounded G1 scope");
    {
      c10::cuda::CUDAGuard guard(device);
      size_t available = 0, total = 0; C10_CUDA_CHECK(cudaMemGetInfo(&available, &total));
      uint64_t required = static_cast<uint64_t>(minimum_free) + pool_budget + 2 * g->static_bytes + g->gradient_bytes;
      if (static_cast<uint64_t>(available) < required)
        throw std::runtime_error("critic CUDA graph rejected by free-memory reserve before allocation");
    }
    {
      g->setup_work_started = true;
      torch::NoGradGuard no_grad;
      g->input = x.detach().clone(); g->target = y.detach().clone();
      // Warmup starts from absent gradients so unused parameters cannot be
      // disguised by preallocated zeros. No optimizer state is touched.
      for (auto &p : g->parameters) p.mutable_grad() = torch::Tensor();
    }
    at::cuda::CUDAEvent ready;
    ready.record(c10::cuda::getCurrentCUDAStream(device));
    ready.block(g->stream);
    g->stream_guard = std::make_unique<c10::cuda::CUDAStreamGuard>(g->stream);
    return g.release();
  } catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" void *mr_critic_graph_buffer_v1(void *p, int kind, char *err, int cap) {
  return tensor([&] {
    auto &g = critic_graph(p);
    if (g.ready || g.capturing) throw std::invalid_argument("static buffers are accessible only during graph setup");
    if (kind == 0) return g.input;
    if (kind == 1) return g.target;
    throw std::invalid_argument("unknown critic graph buffer");
  }, err, cap);
}
extern "C" int mr_critic_graph_begin_v1(void *p, char *err, int cap) {
  return status([&] {
    auto &g = critic_graph(p);
    if (g.ready || g.capturing || !g.stream_guard) throw std::invalid_argument("invalid critic CUDA graph capture state");
    g.stream.synchronize();
    for (auto &parameter : g.parameters) {
      if (!parameter.grad().defined() || parameter.grad().sizes() != parameter.sizes() || !parameter.grad().is_contiguous())
        throw std::invalid_argument("critic CUDA graph warmup did not produce every parameter gradient");
      g.gradients.push_back(parameter.grad()); g.gradient_addresses.push_back(parameter.grad().data_ptr());
    }
    try { g.graph.capture_begin(); }
    catch (...) { g.poison_capture(); throw; }
    g.capturing = true;
    torch::NoGradGuard no_grad;
    for (auto &gradient : g.gradients) gradient.zero_();
  }, err, cap);
}
extern "C" int mr_critic_graph_end_v1(void *p, void *loss, char *err, int cap) {
  return status([&] {
    auto &g = critic_graph(p);
    if (!g.capturing) throw std::invalid_argument("critic CUDA graph is not capturing");
    auto &value = unbox(loss);
    if (value.numel() != 1 || value.get_device() != g.device || value.scalar_type() != torch::kFloat32)
      throw std::invalid_argument("critic CUDA graph loss must be a FP32 CUDA scalar");
    g.finish_capture();
    g.validate_addresses(); g.loss = value.detach();
    g.ready = true;
    g.sample_pool();
    g.release_scope();
  }, err, cap);
}
extern "C" void *mr_critic_graph_replay_v1(void *p, void *input, void *target, char *err, int cap) {
  return tensor([&] {
    auto &g = critic_graph(p);
    if (!g.ready || g.capturing) throw std::invalid_argument("critic CUDA graph is not ready");
    auto &x = unbox(input); auto &y = unbox(target); graph_check_input(x, y);
    if (x.sizes() != g.input.sizes() || y.sizes() != g.target.sizes() || x.get_device() != g.device)
      throw std::invalid_argument("critic CUDA graph shape/device changed; rebuild outside update loop");
    g.validate_addresses();
    c10::cuda::CUDAGuard guard(g.device);
    {
      torch::NoGradGuard no_grad;
      g.input.copy_(x); g.target.copy_(y);
    }
    g.graph.replay(); ++g.replays;
    // Each caller owns a detached scalar snapshot, never overwritten next replay.
    return g.loss.detach().clone();
  }, err, cap);
}
extern "C" int mr_critic_graph_stats_v1(void *p, int64_t *out, int n, char *err, int cap) {
  return status([&] {
    auto &g = critic_graph(p);
    if (!g.ready || n != 5) throw std::invalid_argument("invalid critic CUDA graph stats request");
    out[0] = g.static_bytes; out[1] = g.gradient_bytes; out[2] = g.pool_reserved;
    out[3] = g.pool_allocated; out[4] = g.replays;
  }, err, cap);
}
extern "C" int mr_critic_graph_close_v1(void *p, char *err, int cap) {
  return status([&] { if (p) static_cast<CriticGraph *>(p)->close(); }, err, cap);
}
extern "C" void mr_critic_graph_destroy_v1(void *p) {
  if (!p) return;
  auto *g = static_cast<CriticGraph *>(p);
  // A misuse on a foreign thread cannot restore another thread's stream state;
  // retain the object rather than releasing potentially in-flight storage.
  if (g->owner != std::this_thread::get_id()) return;
  try { g->close(); } catch (...) { return; }
  delete g;
}
#else
extern "C" int mr_critic_graph_supported_v1() { return 0; }
extern "C" void *mr_critic_graph_create_v1(void **, int, void *, void *, int64_t, int64_t, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable: build with MR_ENABLE_CUDA_GRAPH=1 and matching CUDA/PyTorch 2.11 headers"); return nullptr; }
extern "C" void *mr_critic_graph_buffer_v1(void *, int, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable"); return nullptr; }
extern "C" int mr_critic_graph_begin_v1(void *, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable"); return -1; }
extern "C" int mr_critic_graph_end_v1(void *, void *, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable"); return -1; }
extern "C" void *mr_critic_graph_replay_v1(void *, void *, void *, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable"); return nullptr; }
extern "C" int mr_critic_graph_stats_v1(void *, int64_t *, int, char *err, int cap) { error(err, cap, "critic CUDA graph unavailable"); return -1; }
extern "C" int mr_critic_graph_close_v1(void *, char *, int) { return 0; }
extern "C" void mr_critic_graph_destroy_v1(void *) {}
#endif
