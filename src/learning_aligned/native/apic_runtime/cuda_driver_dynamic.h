#pragma once

// Use the real CUDA SDK declarations for every ABI, including versioned names.
// The native runtime loads the host driver injected by --gpus all; no driver
// stub, copied host driver, CUDA context or Python interpreter is needed to
// compile this adapter. First driver use occurs inside mr_apic_open.
#include <cuda.h>
#include <dlfcn.h>
#include <stdexcept>
#include <string>

#if CUDA_VERSION != 13000
#error "This build pins the real CUDA 13.0 driver header"
#endif

namespace moonrobo_apic_cuda {
#define MR_CUDA_STRING_IMPL(name) #name
#define MR_CUDA_STRING(name) MR_CUDA_STRING_IMPL(name)
#define MR_CUDA_MEMBER(name) decltype(&::name) name##_fn = nullptr

class Driver {
  void* library_ = nullptr;
  template <class Function> Function symbol(const char* name) {
    dlerror();
    void* address = dlsym(library_, name);
    const char* error = dlerror();
    if (error || !address)
      throw std::runtime_error(std::string("CUDA driver symbol ") + name +
                               ": " + (error ? error : "null address"));
    return reinterpret_cast<Function>(address);
  }
public:
  MR_CUDA_MEMBER(cuInit);
  MR_CUDA_MEMBER(cuGetErrorString);
  MR_CUDA_MEMBER(cuDeviceGet);
  MR_CUDA_MEMBER(cuDevicePrimaryCtxRetain);
  MR_CUDA_MEMBER(cuDevicePrimaryCtxRelease);
  MR_CUDA_MEMBER(cuCtxSetCurrent);
  MR_CUDA_MEMBER(cuStreamCreate);
  MR_CUDA_MEMBER(cuStreamDestroy);
  MR_CUDA_MEMBER(cuStreamSynchronize);
  MR_CUDA_MEMBER(cuMemHostAlloc);
  MR_CUDA_MEMBER(cuMemFreeHost);
  MR_CUDA_MEMBER(cuMemcpyDtoDAsync);
  MR_CUDA_MEMBER(cuMemcpyDtoHAsync);
  MR_CUDA_MEMBER(cuMemcpyHtoDAsync);
  MR_CUDA_MEMBER(cuMemcpyHtoD);
  MR_CUDA_MEMBER(cuMemcpy2DAsync);
  MR_CUDA_MEMBER(cuMemGetInfo);

  Driver() {
    library_ = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library_) {
      const char* error = dlerror();
      throw std::runtime_error(std::string("load injected libcuda.so.1: ") +
                               (error ? error : "unknown loader error"));
    }
    try {
#define MR_CUDA_LOAD(name) name##_fn = symbol<decltype(name##_fn)>(MR_CUDA_STRING(name))
      MR_CUDA_LOAD(cuInit);
      MR_CUDA_LOAD(cuGetErrorString);
      MR_CUDA_LOAD(cuDeviceGet);
      MR_CUDA_LOAD(cuDevicePrimaryCtxRetain);
      MR_CUDA_LOAD(cuDevicePrimaryCtxRelease);
      MR_CUDA_LOAD(cuCtxSetCurrent);
      MR_CUDA_LOAD(cuStreamCreate);
      MR_CUDA_LOAD(cuStreamDestroy);
      MR_CUDA_LOAD(cuStreamSynchronize);
      MR_CUDA_LOAD(cuMemHostAlloc);
      MR_CUDA_LOAD(cuMemFreeHost);
      MR_CUDA_LOAD(cuMemcpyDtoDAsync);
      MR_CUDA_LOAD(cuMemcpyDtoHAsync);
      MR_CUDA_LOAD(cuMemcpyHtoDAsync);
      MR_CUDA_LOAD(cuMemcpyHtoD);
      MR_CUDA_LOAD(cuMemcpy2DAsync);
      MR_CUDA_LOAD(cuMemGetInfo);
#undef MR_CUDA_LOAD
    } catch (...) {
      dlclose(library_);
      throw;
    }
  }
  Driver(const Driver&) = delete;
  Driver& operator=(const Driver&) = delete;
  // Keep the driver loaded for process lifetime, including graph destruction.
};
inline Driver& driver() { static Driver instance; return instance; }
#undef MR_CUDA_MEMBER
#undef MR_CUDA_STRING
#undef MR_CUDA_STRING_IMPL
}  // namespace moonrobo_apic_cuda

// cuda.h maps some names to versioned ABI symbols. Resolve those names above
// before replacing call sites with exact typed function pointers.
#undef cuInit
#undef cuGetErrorString
#undef cuDeviceGet
#undef cuDevicePrimaryCtxRetain
#undef cuDevicePrimaryCtxRelease
#undef cuCtxSetCurrent
#undef cuStreamCreate
#undef cuStreamDestroy
#undef cuStreamSynchronize
#undef cuMemHostAlloc
#undef cuMemFreeHost
#undef cuMemcpyDtoDAsync
#undef cuMemcpyDtoHAsync
#undef cuMemcpyHtoDAsync
#undef cuMemcpyHtoD
#undef cuMemcpy2DAsync
#undef cuMemGetInfo
#define cuInit ::moonrobo_apic_cuda::driver().cuInit_fn
#define cuGetErrorString ::moonrobo_apic_cuda::driver().cuGetErrorString_fn
#define cuDeviceGet ::moonrobo_apic_cuda::driver().cuDeviceGet_fn
#define cuDevicePrimaryCtxRetain ::moonrobo_apic_cuda::driver().cuDevicePrimaryCtxRetain_fn
#define cuDevicePrimaryCtxRelease ::moonrobo_apic_cuda::driver().cuDevicePrimaryCtxRelease_fn
#define cuCtxSetCurrent ::moonrobo_apic_cuda::driver().cuCtxSetCurrent_fn
#define cuStreamCreate ::moonrobo_apic_cuda::driver().cuStreamCreate_fn
#define cuStreamDestroy ::moonrobo_apic_cuda::driver().cuStreamDestroy_fn
#define cuStreamSynchronize ::moonrobo_apic_cuda::driver().cuStreamSynchronize_fn
#define cuMemHostAlloc ::moonrobo_apic_cuda::driver().cuMemHostAlloc_fn
#define cuMemFreeHost ::moonrobo_apic_cuda::driver().cuMemFreeHost_fn
#define cuMemcpyDtoDAsync ::moonrobo_apic_cuda::driver().cuMemcpyDtoDAsync_fn
#define cuMemcpyDtoHAsync ::moonrobo_apic_cuda::driver().cuMemcpyDtoHAsync_fn
#define cuMemcpyHtoDAsync ::moonrobo_apic_cuda::driver().cuMemcpyHtoDAsync_fn
#define cuMemcpyHtoD ::moonrobo_apic_cuda::driver().cuMemcpyHtoD_fn
#define cuMemcpy2DAsync ::moonrobo_apic_cuda::driver().cuMemcpy2DAsync_fn
#define cuMemGetInfo ::moonrobo_apic_cuda::driver().cuMemGetInfo_fn
