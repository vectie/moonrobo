#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <time.h>

int64_t moonrobo_native_trainer_unix_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + (int64_t)now.tv_nsec / 1000000;
}

double moonrobo_shared_monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1.0;
  return (double)now.tv_sec * 1000.0 + (double)now.tv_nsec / 1000000.0;
}
