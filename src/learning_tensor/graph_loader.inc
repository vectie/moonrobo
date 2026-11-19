/* Optional graph ABI family. The owning backend is retained by MoonBit. */
typedef struct {
  void *library_id;
  void *value;
  void (*destroy)(void *);
  void *(*buffer)(void *, int, char *, int);
  int (*begin)(void *, char *, int);
  int (*end)(void *, void *, char *, int);
  void *(*replay)(void *, void *, void *, char *, int);
  int (*stats)(void *, int64_t *, int, char *, int);
  int (*close)(void *, char *, int);
} NativeCriticGraph;
static int mr_graph_symbols_present(Backend *b) {
  const char *names[] = {"mr_critic_graph_supported_v1", "mr_critic_graph_create_v1", "mr_critic_graph_buffer_v1", "mr_critic_graph_begin_v1", "mr_critic_graph_end_v1", "mr_critic_graph_replay_v1", "mr_critic_graph_stats_v1", "mr_critic_graph_close_v1", "mr_critic_graph_destroy_v1"};
  if (!b || !b->library) return 0;
  for (int i = 0; i < 9; ++i) if (!dlsym(b->library, names[i])) return 0;
  return 1;
}
MOONBIT_FFI_EXPORT int32_t mr_critic_graph_supported_call(Backend *b) {
  if (!mr_graph_symbols_present(b)) return 0;
  int (*supported)(void) = NULL;
  *(void **)(&supported) = dlsym(b->library, "mr_critic_graph_supported_v1");
  return supported();
}
static void mr_graph_cleanup(void *ptr) {
  NativeCriticGraph *g = ptr;
  if (g->value && g->destroy) g->destroy(g->value);
}
MOONBIT_FFI_EXPORT NativeCriticGraph *mr_critic_graph_create_call(
    Backend *b, NativeTensor **parameters, NativeTensor *input, NativeTensor *target,
    int64_t pool_budget, int64_t minimum_free) {
  b->error[0] = 0;
  NativeCriticGraph *g = moonbit_make_external_object(mr_graph_cleanup, sizeof(NativeCriticGraph));
  memset(g, 0, sizeof(*g)); g->library_id = b->library;
  if (!mr_graph_symbols_present(b)) { strcpy(b->error, "plugin lacks optional critic CUDA graph extension"); return g; }
  if (!valid(b, input) || !valid(b, target)) return g;
  int n = Moonbit_array_length(parameters);
  if (n < 1 || n > 4096) { strcpy(b->error, "invalid critic CUDA graph parameter count"); return g; }
  void **raw = handles(b, parameters, n);
  if (!raw) return g;
  void *(*create)(void **, int, void *, void *, int64_t, int64_t, char *, int) = NULL;
  *(void **)(&create) = dlsym(b->library, "mr_critic_graph_create_v1");
  *(void **)(&g->destroy) = dlsym(b->library, "mr_critic_graph_destroy_v1");
  *(void **)(&g->buffer) = dlsym(b->library, "mr_critic_graph_buffer_v1");
  *(void **)(&g->begin) = dlsym(b->library, "mr_critic_graph_begin_v1");
  *(void **)(&g->end) = dlsym(b->library, "mr_critic_graph_end_v1");
  *(void **)(&g->replay) = dlsym(b->library, "mr_critic_graph_replay_v1");
  *(void **)(&g->stats) = dlsym(b->library, "mr_critic_graph_stats_v1");
  *(void **)(&g->close) = dlsym(b->library, "mr_critic_graph_close_v1");
  g->value = create(raw, n, input->value, target->value, pool_budget, minimum_free, b->error, sizeof(b->error));
  free(raw);
  if (!g->value && !b->error[0]) strcpy(b->error, "critic CUDA graph creation failed");
  return g;
}
static int mr_graph_valid(Backend *b, NativeCriticGraph *g) {
  b->error[0] = 0;
  if (!g || !g->value || g->library_id != b->library) { strcpy(b->error, "empty or mismatched critic CUDA graph handle"); return 0; }
  return 1;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_critic_graph_buffer_call(Backend *b, NativeCriticGraph *g, int kind) {
  if (!mr_graph_valid(b, g)) return wrap(b, NULL);
  return wrap(b, g->buffer(g->value, kind, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_critic_graph_begin_call(Backend *b, NativeCriticGraph *g) {
  if (!mr_graph_valid(b, g)) return -1;
  return g->begin(g->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_critic_graph_end_call(Backend *b, NativeCriticGraph *g, NativeTensor *loss) {
  if (!mr_graph_valid(b, g) || !valid(b, loss)) return -1;
  return g->end(g->value, loss->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_critic_graph_replay_call(Backend *b, NativeCriticGraph *g, NativeTensor *input, NativeTensor *target) {
  if (!mr_graph_valid(b, g) || !valid(b, input) || !valid(b, target)) return wrap(b, NULL);
  return wrap(b, g->replay(g->value, input->value, target->value, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_critic_graph_stats_call(Backend *b, NativeCriticGraph *g, int64_t *out) {
  if (!mr_graph_valid(b, g)) return -1;
  return g->stats(g->value, out, Moonbit_array_length(out), b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_critic_graph_close_call(Backend *b, NativeCriticGraph *g) {
  if (!mr_graph_valid(b, g)) return -1;
  return g->close(g->value, b->error, sizeof(b->error));
}
