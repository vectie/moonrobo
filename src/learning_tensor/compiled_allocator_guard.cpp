// Small optional library linked against the same libc10_cuda as the frozen
// tensor plugin. No replacement allocator, interception or model parameters.
#include <c10/cuda/CUDACachingAllocator.h>
#include <cuda_runtime_api.h>
#include <cmath>
#include <cstdint>
#include <limits>

extern "C" int64_t mr_install_compiled_allocator_cap_v1(int device) noexcept {
  try {
    namespace ca = c10::cuda::CUDACachingAllocator;
    constexpr int64_t cap = 20LL << 30;
    int count = 0;
    size_t available = 0, total = 0;
    if (device != 0 || cudaGetDeviceCount(&count) != cudaSuccess || count != 1 ||
        cudaSetDevice(device) != cudaSuccess ||
        cudaMemGetInfo(&available, &total) != cudaSuccess ||
        available <= (24ULL << 30) || total <= static_cast<size_t>(cap) ||
        ca::name() != "native") return -1;
    ca::init(count);
    // Never relax an already tighter cap or install one after allocations.
    if (ca::get()->getDeviceStats(device).reserved_bytes[0].peak != 0) return -2;
    const double fraction = std::nextafter(double(cap) / double(total), 0.0);
    const double existing = ca::getMemoryFraction(device);
    if (!(existing >= fraction && existing <= 1.0)) return -3;
    ca::setMemoryFraction(fraction, device);
    const double actual = ca::getMemoryFraction(device);
    const double bytes = actual * static_cast<double>(total);
    if (!std::isfinite(bytes) || bytes > cap || bytes < cap - 2) return -4;
    return cap;
  } catch (...) { return -5; }
}
