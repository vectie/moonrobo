#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct {
  void *library;
  char error[1024];
  int (*init)(char *, int);
  int (*capture)(double *, int, int64_t *, char *, int);
  int (*joint_index)(const char *, int32_t *, char *, int);
  int (*publish)(const double *, int, char *, int);
  int (*shutdown)(char *, int);
  int closed;
} LowController;
/* Legacy plugins can retain callbacks. All modules stay mapped. */
static void retained(void *object) { (void)object; }
MOONBIT_FFI_EXPORT LowController *moonrobo_low_open(const unsigned char *path) {
  LowController *c = moonbit_make_external_object(retained, sizeof(*c));
  memset(c, 0, sizeof(*c));
  c->library = dlopen((const char *)path, RTLD_NOW | RTLD_LOCAL);
  if (!c->library) { snprintf(c->error, sizeof(c->error), "%s", dlerror()); return c; }
  *(void **)(&c->init) = dlsym(c->library, "moonrobo_e1_low_init");
  *(void **)(&c->capture) = dlsym(c->library, "moonrobo_e1_low_capture");
  *(void **)(&c->joint_index) = dlsym(c->library, "moonrobo_e1_low_joint_index");
  *(void **)(&c->publish) = dlsym(c->library, "moonrobo_e1_low_publish");
  *(void **)(&c->shutdown) = dlsym(c->library, "moonrobo_e1_low_shutdown");
  if (!c->init || !c->capture || !c->joint_index || !c->publish) {
    strcpy(c->error, "adapter is missing low-control ABI symbols"); return c;
  }
  if (c->init(c->error, sizeof(c->error)) != 0 && !c->error[0])
    strcpy(c->error, "low controller initialization failed");
  return c;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_low_error(LowController *c) {
  int n = (int)strlen(c->error);
  moonbit_bytes_t text = moonbit_make_bytes(n, 0);
  memcpy(text, c->error, n);
  return text;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_low_capture(LowController *c, double *out, int64_t *age) {
  if (c->closed) { strcpy(c->error, "low controller is closed"); return -1; }
  return c->capture(out, Moonbit_array_length(out), age, c->error, sizeof(c->error));
}
MOONBIT_FFI_EXPORT int32_t moonrobo_low_joint_index(LowController *c, const unsigned char *name) {
  if (c->closed) { strcpy(c->error, "low controller is closed"); return -1; }
  int32_t index = -1;
  if (c->joint_index((const char *)name, &index, c->error, sizeof(c->error)) != 0) return -1;
  return index;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_low_publish(LowController *c, const double *values) {
  if (c->closed) { strcpy(c->error, "low controller is closed"); return -1; }
  return c->publish(values, Moonbit_array_length(values), c->error, sizeof(c->error));
}
MOONBIT_FFI_EXPORT int32_t moonrobo_low_close(LowController *c) {
  if (c->closed) return 0;
  if (!c->shutdown) { strcpy(c->error, "plugin does not support supervised shutdown"); return -1; }
  c->closed = 1;
  return c->shutdown(c->error, sizeof(c->error));
}
