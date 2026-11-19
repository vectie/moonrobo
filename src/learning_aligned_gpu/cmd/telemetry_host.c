#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Synchronous, bounded reads for the synchronous training phase callback.
 * Byte 0 is 0 for success, 1 for an error; the remainder is UTF-8 text.
 * No caller-controlled filesystem path, writes, or global cache operations. */
static moonbit_bytes_t telemetry_text(int failed, const char *text, size_t n) {
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)n + 1, 0);
  result[0] = (uint8_t)failed;
  if (n) memcpy(result + 1, text, n);
  return result;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_training_host_metric(int32_t index) {
  static const char *paths[] = {
    "/proc/meminfo", "/proc/self/cgroup",
    "/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.peak",
    "/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.events",
    "/sys/fs/cgroup/memory.swap.current", "/sys/fs/cgroup/memory.swap.max",
    "/sys/fs/cgroup/cpu.max"
  };
  if (index < 0 || index >= (int32_t)(sizeof(paths) / sizeof(paths[0])))
    return telemetry_text(1, "invalid host metric index", 25);
  int fd = open(paths[index], O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    char error[256];
    int n = snprintf(error, sizeof(error), "open: %s", strerror(errno));
    return telemetry_text(1, error, n < 0 ? 0 : (size_t)n < sizeof(error) ? (size_t)n : sizeof(error)-1);
  }
  char data[16385];
  size_t used = 0;
  int failure = 0;
  while (used < sizeof(data)) {
    ssize_t n = read(fd, data + used, sizeof(data) - used);
    if (n > 0) used += (size_t)n;
    else if (n == 0) break;
    else if (errno != EINTR) { failure = errno; break; }
  }
  (void)close(fd);
  if (failure) {
    char error[256];
    int n = snprintf(error, sizeof(error), "read: %s", strerror(failure));
    return telemetry_text(1, error, n < 0 ? 0 : (size_t)n < sizeof(error) ? (size_t)n : sizeof(error)-1);
  }
  if (used == 0 || used > 16384)
    return telemetry_text(1, "empty metric or exceeds 16 KiB", strlen("empty metric or exceeds 16 KiB"));
  return telemetry_text(0, data, used);
}
