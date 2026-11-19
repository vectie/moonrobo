/* Optional extension; include at the end of loader.c. No Backend ABI changes. */
typedef struct {
  void *value;
  char error[4096];
  void (*destroy)(void *);
  int64_t (*begin)(void *, const char *, char *, int);
  int (*end)(void *, int64_t, int, char *, int);
  const char *(*report)(void *, char *, int);
  int (*close)(void *, char *, int);
} NativeProfile;
static void cleanup_profile(void *p) {
  NativeProfile *profile = p;
  if (profile->value && profile->destroy) profile->destroy(profile->value);
}
MOONBIT_FFI_EXPORT NativeProfile *mr_profile_create_call(Backend *b, int32_t device, int32_t capacity, int32_t nvtx) {
  NativeProfile *p = moonbit_make_external_object(cleanup_profile, sizeof(NativeProfile));
  memset(p, 0, sizeof(*p));
  b->error[0] = 0;
  void *(*create)(int, int, int, char *, int) = NULL;
  *(void **)(&create) = dlsym(b->library, "mr_profile_create_v1");
  *(void **)(&p->destroy) = dlsym(b->library, "mr_profile_destroy_v1");
  *(void **)(&p->begin) = dlsym(b->library, "mr_profile_begin_v1");
  *(void **)(&p->end) = dlsym(b->library, "mr_profile_end_v1");
  *(void **)(&p->report) = dlsym(b->library, "mr_profile_report_v1");
  *(void **)(&p->close) = dlsym(b->library, "mr_profile_close_v1");
  if (!create || !p->destroy || !p->begin || !p->end || !p->report || !p->close) {
    strcpy(b->error, "plugin lacks optional execution profiling extension; rebuild plugin"); return p;
  }
  p->value = create(device, capacity, nvtx, b->error, sizeof(b->error));
  if (!p->value && !b->error[0]) strcpy(b->error, "profiling create failed");
  return p;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_profile_error_call(NativeProfile *p) { return to_bytes(p->error); }
MOONBIT_FFI_EXPORT int64_t mr_profile_begin_call(NativeProfile *p, moonbit_bytes_t label) {
  p->error[0] = 0;
  int32_t n = Moonbit_array_length(label);
  if (n < 1 || n > 160 || memchr(label, 0, (size_t)n)) {
    strcpy(p->error, "profiling label must contain 1..160 ASCII characters without NUL"); return -1;
  }
  char text[161]; memcpy(text, label, n); text[n] = 0;
  return p->begin(p->value, text, p->error, sizeof(p->error));
}
MOONBIT_FFI_EXPORT int32_t mr_profile_end_call(NativeProfile *p, int64_t token, int32_t cancelled) {
  p->error[0] = 0;
  return p->end(p->value, token, cancelled, p->error, sizeof(p->error));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_profile_report_call(NativeProfile *p) {
  p->error[0] = 0;
  const char *report = p->report(p->value, p->error, sizeof(p->error));
  return to_bytes(report ? report : "");
}
MOONBIT_FFI_EXPORT int32_t mr_profile_close_call(NativeProfile *p) {
  p->error[0] = 0;
  return p->close(p->value, p->error, sizeof(p->error));
}
