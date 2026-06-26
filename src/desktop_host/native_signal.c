#include "moonbit.h"

#if !defined(_WIN32)
#include <signal.h>
#endif

MOONBIT_FFI_EXPORT void moonrobo_desktop_host_ignore_sigpipe(void) {
#if !defined(_WIN32)
  signal(SIGPIPE, SIG_IGN);
#endif
}
