#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <stdint.h>
#include <string.h>
#include <sys/statvfs.h>

/* -1 means an invalid operand, overflow, or an unavailable filesystem. */
static int64_t checked_free_bytes(uint64_t available, uint64_t fragment_size) {
  if (fragment_size == 0 || available > (uint64_t)INT64_MAX / fragment_size)
    return -1;
  return (int64_t)(available * fragment_size);
}

MOONBIT_FFI_EXPORT int64_t moonrobo_checked_disk_product(
    uint64_t available, uint64_t fragment_size) {
  return checked_free_bytes(available, fragment_size);
}

MOONBIT_FFI_EXPORT int64_t moonrobo_output_free_bytes(moonbit_bytes_t path) {
  int32_t length = Moonbit_array_length(path);
  if (length <= 0 || length > 4096 || memchr(path, 0, (size_t)length) != NULL)
    return -1;
  struct statvfs info;
  if (statvfs((const char *)path, &info) != 0)
    return -1;
  return checked_free_bytes((uint64_t)info.f_bavail,
                            (uint64_t)info.f_frsize);
}
