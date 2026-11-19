/* Optional diagnostic extension; no required ABI-2 symbols are added. */
#include <stdio.h>
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_flush_call(void) {
  int a = fflush(stdout); int b = fflush(stderr);
  return a == 0 && b == 0 ? 0 : -1;
}
typedef struct {
  void *value;
  char error[4096];
  void (*destroy)(void *);
  int (*start)(void *, char *, int);
  int64_t (*begin)(void *, const char *, char *, int);
  int (*end)(void *, int64_t, int, char *, int);
  int (*finish)(void *, int, char *, int);
  const char *(*report)(void *, char *, int);
  int (*close)(void *, char *, int);
  int (*mode)(void *, int, char *, int);
} NativeOperatorDiagnostics;
static void cleanup_operator_diagnostics(void *p) {
  NativeOperatorDiagnostics *s = p;
  if (s->value && s->destroy) s->destroy(s->value);
}
MOONBIT_FFI_EXPORT NativeOperatorDiagnostics *mr_operator_diagnostics_create_call(
    Backend *b, int32_t device, int32_t capacity, int32_t structural) {
  NativeOperatorDiagnostics *s = moonbit_make_external_object(cleanup_operator_diagnostics, sizeof(NativeOperatorDiagnostics));
  memset(s, 0, sizeof(*s)); b->error[0] = 0;
  void *(*create)(int, int, int, char *, int) = NULL;
  *(void **)(&create) = dlsym(b->library, "mr_operator_diagnostics_create_v1");
  *(void **)(&s->destroy) = dlsym(b->library, "mr_operator_diagnostics_destroy_v1");
  *(void **)(&s->start) = dlsym(b->library, "mr_operator_diagnostics_start_v1");
  *(void **)(&s->begin) = dlsym(b->library, "mr_operator_diagnostics_begin_v1");
  *(void **)(&s->end) = dlsym(b->library, "mr_operator_diagnostics_end_v1");
  *(void **)(&s->finish) = dlsym(b->library, "mr_operator_diagnostics_finish_v1");
  *(void **)(&s->report) = dlsym(b->library, "mr_operator_diagnostics_report_v1");
  *(void **)(&s->close) = dlsym(b->library, "mr_operator_diagnostics_close_v1");
  *(void **)(&s->mode) = dlsym(b->library, "mr_operator_diagnostics_mode_v1");
  if (!create || !s->destroy || !s->start || !s->begin || !s->end || !s->finish || !s->report || !s->close) {
    strcpy(b->error, "plugin lacks optional operator diagnostics extension; use a separate diagnostic build"); return s;
  }
  s->value = create(device, capacity, structural, b->error, sizeof(b->error));
  if (!s->value && !b->error[0]) strcpy(b->error, "operator diagnostics create failed");
  return s;
}
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_mode_call(NativeOperatorDiagnostics *s, int32_t mode) {
  s->error[0] = 0;
  if (!s->mode) { strcpy(s->error, "plugin lacks optional diagnostic observer modes"); return -1; }
  return s->mode(s->value, mode, s->error, sizeof(s->error));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_operator_diagnostics_error_call(NativeOperatorDiagnostics *s) { return to_bytes(s->error); }
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_start_call(NativeOperatorDiagnostics *s) {
  s->error[0] = 0; return s->start(s->value, s->error, sizeof(s->error));
}
MOONBIT_FFI_EXPORT int64_t mr_operator_diagnostics_begin_call(NativeOperatorDiagnostics *s, moonbit_bytes_t label) {
  s->error[0] = 0;
  int n = Moonbit_array_length(label);
  if (n < 1 || n > 160 || memchr(label, 0, (size_t)n)) {
    strcpy(s->error, "operator label requires 1..160 printable ASCII characters without NUL"); return -1;
  }
  char text[161]; memcpy(text, label, n); text[n] = 0;
  return s->begin(s->value, text, s->error, sizeof(s->error));
}
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_end_call(NativeOperatorDiagnostics *s, int64_t token, int32_t cancel) {
  s->error[0] = 0; return s->end(s->value, token, cancel, s->error, sizeof(s->error));
}
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_finish_call(NativeOperatorDiagnostics *s, int32_t cancel) {
  s->error[0] = 0; return s->finish(s->value, cancel, s->error, sizeof(s->error));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_operator_diagnostics_report_call(NativeOperatorDiagnostics *s) {
  s->error[0] = 0;
  const char *text = s->report(s->value, s->error, sizeof(s->error));
  return to_bytes(text ? text : "");
}
MOONBIT_FFI_EXPORT int32_t mr_operator_diagnostics_close_call(NativeOperatorDiagnostics *s) {
  s->error[0] = 0; return s->close(s->value, s->error, sizeof(s->error));
}
