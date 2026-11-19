#include <moonbit.h>
#include <stdint.h>
#if !defined(_WIN32)
#include <sys/stat.h>
#include <unistd.h>
#endif

// Metadata only: never fork/exec or load the checked program/library. POSIX
// native launchers require an existing regular file executable by this user.
MOONBIT_FFI_EXPORT int32_t moonrobo_supervisor_executable(const unsigned char *path) {
#if defined(_WIN32)
  // The E1 native adapter/launcher targets POSIX. Do not assert readiness on an
  // unsupported host based solely on file existence or a filename extension.
  (void)path;
  return 0;
#else
  struct stat info;
  return path && path[0] && stat((const char *)path, &info) == 0 &&
    S_ISREG(info.st_mode) && access((const char *)path, X_OK) == 0;
#endif
}

MOONBIT_FFI_EXPORT int32_t moonrobo_supervisor_readable_file(const unsigned char *path) {
#if defined(_WIN32)
  (void)path;
  return 0;
#else
  struct stat info;
  return path && path[0] && stat((const char *)path, &info) == 0 &&
    S_ISREG(info.st_mode) && access((const char *)path, R_OK) == 0;
#endif
}
