#include <stdint.h>
#include <time.h>
#include <moonbit.h>
MOONBIT_FFI_EXPORT int64_t mr_bucket_benchmark_monotonic_ns(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
}
