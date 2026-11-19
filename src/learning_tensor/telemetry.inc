// Optional ABI-2 telemetry extension. Only official generic LibTorch headers:
// CUDA runtime functions come from this plugin's existing dependency graph.
#include <ATen/detail/CUDAHooksInterface.h>
#include <c10/core/CachingDeviceAllocator.h>
#include <c10/core/DeviceGuard.h>
#include <c10/util/env.h>

extern "C" int mr_tensor_cuda_memory_stats_v1(int, int, int64_t *, int, char *, int);

namespace {
struct TelemetryRuntime {
  int (*memory_info)(size_t *, size_t *);
  int (*synchronize)();
  const char *(*error_string)(int);

  TelemetryRuntime() {
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(&mr_tensor_cuda_memory_stats_v1), &info))
      throw std::runtime_error("cannot locate telemetry plugin dependencies");
    void *module = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL);
    if (!module) throw std::runtime_error("cannot access telemetry plugin dependencies");
    memory_info = reinterpret_cast<int (*)(size_t *, size_t *)>(dlsym(module, "cudaMemGetInfo"));
    synchronize = reinterpret_cast<int (*)()>(dlsym(module, "cudaDeviceSynchronize"));
    error_string = reinterpret_cast<const char *(*)(int)>(dlsym(module, "cudaGetErrorString"));
    dlclose(module); // The loader retains the plugin itself for process life.
    if (!memory_info || !synchronize || !error_string)
      throw std::runtime_error("CUDA allocator telemetry unsupported: CUDA runtime symbols unavailable");
  }
  void check(int code) const {
    if (code != 0) throw std::runtime_error(error_string(code));
  }
};

c10::DeviceAllocator *telemetry_allocator(int device) {
  const auto count = mr_tensor_device_count();
  if (count <= 0)
    throw std::runtime_error("CUDA allocator telemetry unsupported: CPU build or no accessible CUDA device");
  if (device < 0 || device >= count || device > std::numeric_limits<c10::DeviceIndex>::max())
    throw std::invalid_argument("invalid CUDA device for allocator telemetry");
  if (c10::utils::check_env("PYTORCH_NO_CUDA_MEMORY_CACHING") == true ||
      c10::utils::check_env("PYTORCH_NO_HIP_MEMORY_CACHING") == true)
    throw std::runtime_error("CUDA allocator telemetry unsupported: uncached allocations bypass tracked statistics");
  // CUDAHooks returns the active allocator, including any explicit replacement.
  // Do not reinterpret a CUDA-specific vtable or resolve mangled C++ symbols.
  auto *allocator = dynamic_cast<c10::DeviceAllocator *>(at::detail::getCUDAHooks().getCUDADeviceAllocator());
  if (!allocator || !allocator->initialized())
    throw std::runtime_error("CUDA allocator telemetry unsupported: allocator is unavailable or uninitialized");
  if (!at::detail::getCUDAHooks().hasPrimaryContext(static_cast<c10::DeviceIndex>(device)))
    throw std::runtime_error("CUDA allocator telemetry unsupported: selected device has no initialized primary context");
  return allocator;
}
}

// Output order: allocated current/peak, reserved current/peak, CUDA free/total.
// Exactly six Int64 values, published only after the entire query succeeds.
extern "C" int mr_tensor_cuda_memory_stats_v1(int device, int synchronize,
                                                int64_t *out, int count, char *err, int cap) {
  return status([&] {
    if (!out || count != 6 || (synchronize != 0 && synchronize != 1))
      throw std::invalid_argument("invalid CUDA allocator telemetry arguments");
    auto *allocator = telemetry_allocator(device);
    TelemetryRuntime runtime;
    // Official generic guard preserves PyTorch's logical-device TLS and uses
    // deferred restoration instead of raw cudaSetDevice on an unused prior GPU.
    c10::DeviceGuard guard(c10::Device(c10::DeviceType::CUDA, static_cast<c10::DeviceIndex>(device)));
    if (synchronize) runtime.check(runtime.synchronize());
    const auto stats = allocator->getDeviceStats(static_cast<c10::DeviceIndex>(device));
    const auto aggregate = static_cast<size_t>(c10::CachingAllocator::StatType::AGGREGATE);
    const auto allocated = stats.allocated_bytes[aggregate];
    const auto reserved = stats.reserved_bytes[aggregate];
    size_t free_bytes = 0, total_bytes = 0;
    runtime.check(runtime.memory_info(&free_bytes, &total_bytes));
    if (allocated.current < 0 || allocated.peak < allocated.current ||
        reserved.current < 0 || reserved.peak < reserved.current ||
        free_bytes > total_bytes || total_bytes > static_cast<size_t>(INT64_MAX))
      throw std::runtime_error("invalid CUDA allocator telemetry statistics");
    const int64_t values[6] = {allocated.current, allocated.peak, reserved.current,
      reserved.peak, static_cast<int64_t>(free_bytes), static_cast<int64_t>(total_bytes)};
    std::memcpy(out, values, sizeof(values));
  }, err, cap);
}

// Explicit measurement-window operation; never invoked implicitly by a query.
extern "C" int mr_tensor_cuda_reset_memory_peaks_v1(int device, int synchronize, char *err, int cap) {
  return status([&] {
    if (synchronize != 0 && synchronize != 1)
      throw std::invalid_argument("invalid CUDA peak reset synchronization flag");
    auto *allocator = telemetry_allocator(device);
    TelemetryRuntime runtime;
    c10::DeviceGuard guard(c10::Device(c10::DeviceType::CUDA, static_cast<c10::DeviceIndex>(device)));
    if (synchronize) runtime.check(runtime.synchronize());
    allocator->resetPeakStats(static_cast<c10::DeviceIndex>(device));
  }, err, cap);
}
