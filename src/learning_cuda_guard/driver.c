// Dedicated diagnostic-process query only: no LibTorch, tensor allocations,
// streams, kernels, synchronization, cache changes or training RNG calls.
// cuDevicePrimaryCtxRetain has real driver/context overhead; it is not free.
#include <moonbit.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <dlfcn.h>
#if defined(__has_include)
#if __has_include(<cuda.h>)
#include <cuda.h>
#if CUDA_VERSION == 13000
#define MR_GUARD_CUDA13 1
#endif
#endif
#endif
#ifndef MR_GUARD_CUDA13
#define MR_GUARD_CUDA13 0
#endif

static char guard_error[1024];
static int guard_opened = 0;
#if MR_GUARD_CUDA13
static void *driver;
static CUdevice device;
static CUcontext context;
static CUresult (*init_fn)(unsigned int);
static CUresult (*device_get_fn)(CUdevice *, int);
static CUresult (*retain_fn)(CUcontext *, CUdevice);
static CUresult (*release_fn)(CUdevice);
static CUresult (*set_current_fn)(CUcontext);
static CUresult (*memory_info_fn)(size_t *, size_t *);
static CUresult (*error_string_fn)(CUresult, const char **);
#define STR_IMPL(x) #x
#define STR(x) STR_IMPL(x)
static int checked(CUresult status, const char *operation) {
  if (status == CUDA_SUCCESS) return 0;
  const char *message = "unknown CUDA driver error";
  if (error_string_fn) error_string_fn(status, &message);
  snprintf(guard_error, sizeof(guard_error), "%s: code=%d %s", operation, (int)status, message ? message : "unknown");
  return -1;
}
#endif

MOONBIT_FFI_EXPORT int32_t mr_cuda_guard_capability(void) { return MR_GUARD_CUDA13; }
MOONBIT_FFI_EXPORT int32_t mr_cuda_guard_open(int32_t ordinal) {
  guard_error[0] = 0;
  if (guard_opened || ordinal != 0) {
    snprintf(guard_error, sizeof(guard_error), "one fresh guard process for visible CUDA device0 is required"); return -1;
  }
#if MR_GUARD_CUDA13
  driver = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!driver) { snprintf(guard_error, sizeof(guard_error), "load injected libcuda.so.1: %s", dlerror()); return -1; }
#define LOAD(field, name) do { \
    *(void **)(&field) = dlsym(driver, STR(name)); \
    if (!field) { snprintf(guard_error, sizeof(guard_error), "missing CUDA13 driver symbol: %s", STR(name)); return -1; } \
  } while (0)
  LOAD(init_fn, cuInit); LOAD(device_get_fn, cuDeviceGet);
  LOAD(retain_fn, cuDevicePrimaryCtxRetain); LOAD(release_fn, cuDevicePrimaryCtxRelease);
  LOAD(set_current_fn, cuCtxSetCurrent); LOAD(memory_info_fn, cuMemGetInfo);
  LOAD(error_string_fn, cuGetErrorString);
#undef LOAD
  if (checked(init_fn(0), "cuInit") || checked(device_get_fn(&device, ordinal), "cuDeviceGet")) return -1;
  if (checked(retain_fn(&context, device), "cuDevicePrimaryCtxRetain")) return -1;
  guard_opened = 1;
  if (checked(set_current_fn(context), "cuCtxSetCurrent")) {
    // Preserve the original error if the best-effort cleanup also fails.
    (void)release_fn(device); guard_opened = 0; return -1;
  }
  return 0;
#else
  snprintf(guard_error, sizeof(guard_error), "CUDA guard requires the real matching CUDA13.0 header at native build time"); return -1;
#endif
}

MOONBIT_FFI_EXPORT int32_t mr_cuda_guard_sample(int64_t *output) {
  guard_error[0] = 0;
  if (!guard_opened || !output || Moonbit_array_length(output) != 2) {
    snprintf(guard_error, sizeof(guard_error), "CUDA guard is not open or sample shape is invalid"); return -1;
  }
#if MR_GUARD_CUDA13
  size_t available = 0, total = 0;
  if (checked(set_current_fn(context), "cuCtxSetCurrent") || checked(memory_info_fn(&available, &total), "cuMemGetInfo")) return -1;
  if (available > total || total > INT64_MAX || total == 0) {
    snprintf(guard_error, sizeof(guard_error), "invalid driver CUDA memory statistics"); return -1;
  }
  output[0] = (int64_t)available; output[1] = (int64_t)total;
  return 0;
#else
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int32_t mr_cuda_guard_close(void) {
  guard_error[0] = 0;
  if (!guard_opened) return 0;
#if MR_GUARD_CUDA13
  // There is no work/stream to drain. Detach and release only this process's
  // retained primary context; never call reset or affect another process.
  if (checked(set_current_fn(NULL), "detach primary context")) return -1;
  if (checked(release_fn(device), "cuDevicePrimaryCtxRelease")) return -1;
  guard_opened = 0; context = NULL;
  // Keep libcuda loaded to process exit; unloading driver TLS is unnecessary.
#endif
  return 0;
}

MOONBIT_FFI_EXPORT int32_t mr_cuda_guard_error(uint8_t *output) {
  int capacity = Moonbit_array_length(output);
  size_t count = strlen(guard_error);
  if (capacity <= 0) return 0;
  if (count > (size_t)capacity) count = (size_t)capacity;
  memcpy(output, guard_error, count); return (int32_t)count;
}
MOONBIT_FFI_EXPORT void mr_cuda_guard_flush(void) { fflush(stdout); fflush(stderr); }
