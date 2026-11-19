// NCCL public ABI subset verified against NVIDIA/nccl v2.28.9-1 src/nccl.h.in.
// No CUDA/NCCL build-time headers; use the exact libraries linked by LibTorch.
namespace {
struct NcclId { char bytes[128]; };
struct NcclConfig {
  size_t size; unsigned int magic, version;
  int blocking, cgaClusterSize, minCTAs, maxCTAs;
  const char *netName;
  int splitShare, trafficClass;
  const char *commName;
  int collnetEnable, CTAPolicy, shrinkShare, nvlsCTAs, nChannelsPerNetPeer, nvlinkCentricSched;
};
static_assert(sizeof(NcclId) == 128 && sizeof(NcclConfig) == 80 && sizeof(void *) == 8, "NCCL public ABI mismatch");
using Comm = void *;
using CudaStream = void *;
struct NcclApi {
  void *module = nullptr;
  int (*version)(int *) = nullptr;
  int (*id)(NcclId *) = nullptr;
  int (*init)(Comm *, int, NcclId, int, NcclConfig *) = nullptr;
  int (*abort)(Comm) = nullptr;
  int (*async_error)(Comm, int *) = nullptr;
  int (*reduce)(const void *, void *, size_t, int, int, Comm, CudaStream) = nullptr;
  int (*broadcast)(const void *, void *, size_t, int, int, Comm, CudaStream) = nullptr;
  const char *(*nccl_error)(int) = nullptr;
  int (*get_device)(int *) = nullptr;
  int (*set_device)(int) = nullptr;
  int (*stream_create)(CudaStream *, unsigned) = nullptr;
  int (*stream_query)(CudaStream) = nullptr;
  int (*stream_destroy)(CudaStream) = nullptr;
  const char *(*cuda_error)(int) = nullptr;
  NcclApi() {
    if (mr_tensor_device_count() < 1) throw std::runtime_error("NCCL requires a CUDA-enabled LibTorch and an available CUDA device");
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(&mr_tensor_cuda_free_bytes), &info)) throw std::runtime_error("cannot locate LibTorch plugin dependencies");
    module = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL);
    if (!module) throw std::runtime_error("cannot open LibTorch plugin dependency scope");
#define NCCL_LOAD(field, name) do { *reinterpret_cast<void **>(&field) = dlsym(module, name); if (!field) throw std::runtime_error("missing LibTorch dependency symbol " name); } while (0)
    NCCL_LOAD(version, "ncclGetVersion"); NCCL_LOAD(id, "ncclGetUniqueId");
    NCCL_LOAD(init, "ncclCommInitRankConfig"); NCCL_LOAD(abort, "ncclCommAbort");
    NCCL_LOAD(async_error, "ncclCommGetAsyncError"); NCCL_LOAD(reduce, "ncclAllReduce");
    NCCL_LOAD(broadcast, "ncclBroadcast"); NCCL_LOAD(nccl_error, "ncclGetErrorString");
    NCCL_LOAD(get_device, "cudaGetDevice"); NCCL_LOAD(set_device, "cudaSetDevice");
    NCCL_LOAD(stream_create, "cudaStreamCreateWithFlags"); NCCL_LOAD(stream_query, "cudaStreamQuery");
    NCCL_LOAD(stream_destroy, "cudaStreamDestroy"); NCCL_LOAD(cuda_error, "cudaGetErrorString");
#undef NCCL_LOAD
    int v = 0; check(version(&v));
    if (v != 22809) throw std::runtime_error("NCCL 2.28.9 is required by the verified nonblocking configuration ABI");
    // Keep module loaded: unique-ID bootstrap threads outlive this call.
  }
  void check(int code) const { if (code != 0 && code != 7) throw std::runtime_error(nccl_error(code)); }
  void cuda(int code) const { if (code != 0) throw std::runtime_error(cuda_error(code)); }
};
NcclApi &nccl_api() { static NcclApi *api = new NcclApi(); return *api; }
struct NcclDeviceGuard {
  NcclApi &api; int prior;
  NcclDeviceGuard(NcclApi &a, int device) : api(a), prior(-1) { api.cuda(api.get_device(&prior)); api.cuda(api.set_device(device)); }
  ~NcclDeviceGuard() { if (prior >= 0) api.set_device(prior); }
};
struct Collective {
  NcclApi &api;
  Comm comm = nullptr;
  CudaStream stream = nullptr;
  int rank, world, device, timeout;
  bool failed = false, closed = false;
  // Hold a buffer until communication has completed. On failure retain it until
  // process exit rather than freeing memory a failed CUDA kernel may still touch.
  torch::Tensor pending;
  // Optional bucket route also retains pack inputs/backing on any failure,
  // including a timeout while waiting for the compute stream before NCCL.
  torch::Tensor bucket_pending;
  std::vector<torch::Tensor> bucket_sources;
  Collective(NcclApi &a, int r, int w, int d, int ms) : api(a), rank(r), world(w), device(d), timeout(ms) {}
  auto deadline() const { return std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout); }
  void check_open() const { if (closed || failed || !comm) throw std::runtime_error("NCCL communicator closed or failed; terminate the distributed run"); }
  void check_time(const std::chrono::steady_clock::time_point &until) {
    if (std::chrono::steady_clock::now() >= until) throw std::runtime_error("NCCL operation deadline exceeded; terminate every rank");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  void poll_comm(const std::chrono::steady_clock::time_point &until) {
    for (;;) {
      int state = 0; api.check(api.async_error(comm, &state));
      api.check(state);
      if (state == 0) return;
      check_time(until);
    }
  }
  void fail() noexcept {
    failed = true;
    if (comm) { api.abort(comm); comm = nullptr; }
  }
  void wait_torch(const std::chrono::steady_clock::time_point &until) {
    c10::impl::VirtualGuardImpl guard(c10::DeviceType::CUDA);
    auto current = guard.getStream(c10::Device(c10::DeviceType::CUDA, device));
    while (!guard.queryStream(current)) { poll_comm(until); check_time(until); }
  }
  void wait_cuda(const std::chrono::steady_clock::time_point &until) {
    poll_comm(until);
    for (;;) {
      int result = api.stream_query(stream);
      if (result == 0) return;
      if (result != 600) api.cuda(result); // cudaErrorNotReady
      poll_comm(until); check_time(until);
    }
  }
  int type(const torch::Tensor &t) const {
    if (!t.is_cuda() || t.get_device() != device) throw std::invalid_argument("collective tensor must be on communicator CUDA device");
    switch (t.scalar_type()) {
      case torch::kFloat32: return 7;
      case torch::kFloat64: return 8;
      case torch::kBFloat16: return 9;
      case torch::kInt64: return 4;
      default: throw std::invalid_argument("collective supports Float32/Float64/BFloat16/Int64 only");
    }
  }
  void communicate(torch::Tensor value, int op, int root) {
    check_open();
    if (op != 0 && op != 2 && op != 3 && op != -1) throw std::invalid_argument("invalid collective reduction");
    if (root < 0 || root >= world) throw std::invalid_argument("invalid broadcast rank");
    int dtype_code = type(value);
    if (!value.is_contiguous()) throw std::invalid_argument("internal collective buffer must be contiguous");
    pending = value;
    auto until = deadline();
    wait_torch(until);
    int result = op == -1 ? api.broadcast(value.data_ptr(), value.data_ptr(), value.numel(), dtype_code, root, comm, stream)
                          : api.reduce(value.data_ptr(), value.data_ptr(), value.numel(), dtype_code, op, comm, stream);
    api.check(result);
    wait_cuda(until);
    pending = torch::Tensor();
  }
};
Collective &collective(void *p) { if (!p) throw std::invalid_argument("empty NCCL handle"); return *static_cast<Collective *>(p); }
template <typename F> int collective_status(void *p, F &&f, char *err, int cap) {
  try { f(collective(p)); return 0; }
  catch (const std::exception &e) { if (p) collective(p).fail(); error(err, cap, e.what()); return -1; }
  catch (...) { if (p) collective(p).fail(); error(err, cap, "unknown NCCL failure"); return -1; }
}
}
extern "C" int mr_nccl_unique_id(unsigned char *out, char *err, int cap) {
  return status([&] { NcclId id; auto &api = nccl_api(); api.check(api.id(&id)); std::memcpy(out, &id, 128); }, err, cap);
}
extern "C" void *mr_nccl_connect(const unsigned char *id, int rank, int world, int device, int timeout, char *err, int cap) {
  Collective *result = nullptr;
  try {
    if (world < 2 || world > 16 || rank < 0 || rank >= world || device < 0 || device >= mr_tensor_device_count() || timeout < 100 || timeout > 300000)
      throw std::invalid_argument("invalid NCCL rank/world/device/timeout");
    auto &api = nccl_api(); NcclDeviceGuard guard(api, device);
    result = new Collective(api, rank, world, device, timeout);
    api.cuda(api.stream_create(&result->stream, 1)); // nonblocking CUDA stream
    NcclConfig config = {sizeof(NcclConfig), 0xcafebeefU, 22809U, 0, INT_MIN, INT_MIN, INT_MIN, nullptr, INT_MIN, INT_MIN, nullptr, INT_MIN, INT_MIN, INT_MIN, INT_MIN, INT_MIN, INT_MIN};
    NcclId unique; std::memcpy(&unique, id, 128);
    auto until = result->deadline();
    api.check(api.init(&result->comm, world, unique, rank, &config));
    result->poll_comm(until);
    return result;
  } catch (const std::exception &e) {
    if (result) result->fail(); // retained on failure; process must exit
    error(err, cap, e.what()); return nullptr;
  }
}
extern "C" int mr_nccl_close(void *p, char *err, int cap) {
  return status([&] {
    auto &c = collective(p);
    if (c.closed) return;
    NcclDeviceGuard guard(c.api, c.device);
    if (c.comm) { c.api.check(c.api.abort(c.comm)); c.comm = nullptr; }
    if (!c.failed && c.stream) { c.api.cuda(c.api.stream_destroy(c.stream)); c.stream = nullptr; }
    c.closed = true;
  }, err, cap);
}
extern "C" void mr_nccl_destroy(void *p) {
  if (!p) return;
  auto &c = collective(p);
  if (c.failed) return; // Never free possibly in-flight buffers after failure.
  char err[128];
  if (mr_nccl_close(p, err, sizeof(err)) == 0) delete static_cast<Collective *>(p);
}
extern "C" void *mr_nccl_all_reduce(void *p, void *input, int op, char *err, int cap) {
  torch::Tensor output;
  int code = collective_status(p, [&](Collective &c) {
    NcclDeviceGuard guard(c.api, c.device); torch::NoGradGuard no_grad;
    auto &source = unbox(input); c.type(source);
    if (source.nbytes() > 256ULL * 1024 * 1024) throw std::invalid_argument("all_reduce clone exceeds 256 MiB bound; split the input");
    output = source.detach().contiguous().clone();
    c.communicate(output, op, 0);
  }, err, cap);
  return code == 0 ? new torch::Tensor(output) : nullptr;
}
extern "C" int mr_nccl_broadcast(void *p, void *input, int root, char *err, int cap) {
  return collective_status(p, [&](Collective &c) {
    NcclDeviceGuard guard(c.api, c.device); torch::NoGradGuard no_grad;
    auto &source = unbox(input); c.type(source);
    if (!source.is_contiguous()) throw std::invalid_argument("broadcast requires contiguous tensor");
    c.communicate(source, -1, root);
  }, err, cap);
}
extern "C" int mr_nccl_average_gradients(void *p, void **parameters, int n, char *err, int cap) {
  return collective_status(p, [&](Collective &c) {
    NcclDeviceGuard guard(c.api, c.device); torch::NoGradGuard no_grad;
    c.check_open();
    if (n < 1 || n > 4096) throw std::invalid_argument("invalid gradient parameter count");
    std::unordered_set<void *> seen;
    for (int i = 0; i < n; ++i) {
      auto &parameter = unbox(parameters[i]); c.type(parameter);
      if (!parameter.is_leaf() || !parameter.requires_grad() || !parameter.is_floating_point() || !parameter.is_contiguous() || !seen.insert(parameter.unsafeGetTensorImpl()).second)
        throw std::invalid_argument("gradient collective requires distinct contiguous floating leaf parameters");
    }
    constexpr int64_t bucket = 4LL * 1024 * 1024;
    for (int i = 0; i < n; ++i) {
      auto &parameter = unbox(parameters[i]);
      if (!parameter.grad().defined()) parameter.mutable_grad() = torch::zeros_like(parameter);
      auto gradient = parameter.mutable_grad().view({-1});
      for (int64_t offset = 0; offset < parameter.numel(); offset += bucket) {
        auto view = gradient.narrow(0, offset, std::min(bucket, parameter.numel() - offset));
        c.communicate(view, 0, 0);
        view.div_(c.world);
      }
    }
  }, err, cap);
}
// Optional ABI-2 route. One byte backing allocation is reused across all dtype
// segments; actual communication views have the original floating dtype. This
// deliberately keeps the deadline-bound synchronous stream handoff above.
// It reduces launches, but does not overlap communication with backward.
extern "C" int mr_nccl_average_gradients_bucketed_v1(
    void *p, void **parameters, int n, int64_t bucket_bytes, char *err, int cap) {
  return collective_status(p, [&](Collective &c) {
    NcclDeviceGuard guard(c.api, c.device); torch::NoGradGuard no_grad;
    c.check_open();
    if (n < 1 || n > 4096 || !parameters)
      throw std::invalid_argument("invalid gradient parameter count");
    if (bucket_bytes < 1024LL * 1024 || bucket_bytes > 64LL * 1024 * 1024)
      throw std::invalid_argument("gradient bucket must contain 1..64 MiB");
    std::unordered_set<void *> seen;
    // Validate everything before creating missing gradients or communicating.
    for (int i = 0; i < n; ++i) {
      auto &parameter = unbox(parameters[i]); c.type(parameter);
      if (!parameter.is_leaf() || !parameter.requires_grad() ||
          !parameter.is_floating_point() || !parameter.is_contiguous() ||
          !seen.insert(parameter.unsafeGetTensorImpl()).second)
        throw std::invalid_argument("gradient collective requires distinct contiguous floating leaf parameters");
      if (parameter.grad().defined()) {
        const auto &gradient = parameter.grad();
        if (gradient.sizes() != parameter.sizes() ||
            gradient.device() != parameter.device() ||
            gradient.scalar_type() != parameter.scalar_type() ||
            !gradient.is_contiguous())
          throw std::invalid_argument("gradient collective shape/device/dtype/layout mismatch");
      }
    }
    for (int i = 0; i < n; ++i) {
      auto &parameter = unbox(parameters[i]);
      if (!parameter.grad().defined()) parameter.mutable_grad() = torch::zeros_like(parameter);
    }
    c.bucket_sources.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) c.bucket_sources.push_back(unbox(parameters[i]).grad());
    struct Slice { torch::Tensor flat; int64_t offset, bucket_offset, count; };
    std::vector<Slice> slices;
    slices.reserve(static_cast<size_t>(n));
    auto backing = torch::empty({bucket_bytes},
      unbox(parameters[0]).options().dtype(torch::kUInt8).requires_grad(false));
    c.bucket_pending = backing;
    torch::Tensor bucket;
    int64_t used = 0, capacity = 0;
    auto flush = [&] {
      if (!used) return;
      auto values = bucket.narrow(0, 0, used);
      c.communicate(values, 0, 0); // waits for pack, then completed SUM
      values.div_(c.world);
      for (const auto &slice : slices)
        slice.flat.narrow(0, slice.offset, slice.count).copy_(
          values.narrow(0, slice.bucket_offset, slice.count));
      // Scatter and the next pack share the Torch stream. communicate's next
      // wait_torch observes both; no storage can be overwritten out of order.
      slices.clear(); used = 0;
    };
    for (int i = 0; i < n; ++i) {
      auto &parameter = unbox(parameters[i]);
      if (!bucket.defined() || bucket.scalar_type() != parameter.scalar_type()) {
        flush();
        const auto element_bytes = static_cast<int64_t>(parameter.element_size());
        capacity = bucket_bytes / element_bytes;
        bucket = backing.narrow(0, 0, capacity * element_bytes).view(parameter.scalar_type());
      }
      auto flat = parameter.mutable_grad().view({-1});
      for (int64_t offset = 0; offset < parameter.numel();) {
        const auto count = std::min(capacity - used, parameter.numel() - offset);
        bucket.narrow(0, used, count).copy_(flat.narrow(0, offset, count));
        slices.push_back({flat, offset, used, count});
        used += count; offset += count;
        if (used == capacity) flush();
      }
    }
    flush();
    c.bucket_sources.clear();
    c.bucket_pending = torch::Tensor();
  }, err, cap);
}
extern "C" int mr_nccl_control(void *p, const int64_t *input, int64_t *output, int n, int op, char *err, int cap) {
  return collective_status(p, [&](Collective &c) {
    NcclDeviceGuard guard(c.api, c.device); torch::NoGradGuard no_grad;
    if (n < 1 || n > 8192) throw std::invalid_argument("control vector must contain 1..8192 int64 values");
    seal_fp32_startup(); // This path can create the plugin's first tensor.
    auto cpu = torch::from_blob(const_cast<int64_t *>(input), {n}, torch::TensorOptions().dtype(torch::kInt64).device(torch::kCPU));
    auto value = cpu.to(torch::Device(torch::kCUDA, c.device));
    c.communicate(value, op, 0);
    auto result = value.to(torch::kCPU).contiguous();
    std::memcpy(output, result.data_ptr<int64_t>(), n * sizeof(int64_t));
  }, err, cap);
}
