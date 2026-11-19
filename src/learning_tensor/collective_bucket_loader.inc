/* Optional ABI-2 extension; include after valid_collective/handles definitions.
 * The library remains loaded for process life, as with the base tensor API. */
typedef int (*mr_bucket_gradients_fn)(void *, void **, int, int64_t, char *, int);
static mr_bucket_gradients_fn mr_bucket_gradients_symbol(Backend *b) {
  if (!b || !b->library) return NULL;
  mr_bucket_gradients_fn result = NULL;
  *(void **)(&result) = dlsym(b->library, "mr_nccl_average_gradients_bucketed_v1");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_has_gradient_buckets(Backend *b) {
  return mr_bucket_gradients_symbol(b) != NULL;
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_gradients_bucketed_call(
    Backend *b, NativeCollective *c, NativeTensor **parameters, int32_t bucket_bytes) {
  b->error[0] = 0;
  mr_bucket_gradients_fn operation = mr_bucket_gradients_symbol(b);
  if (!operation) {
    strcpy(b->error, "plugin lacks optional gradient bucket extension; rebuild plugin");
    return -1;
  }
  if (!valid_collective(b, c)) return -1;
  int n = Moonbit_array_length(parameters);
  if (n < 1 || n > 4096 || bucket_bytes < 1024 * 1024 || bucket_bytes > 64 * 1024 * 1024) {
    strcpy(b->error, "gradient buckets require 1..4096 parameters and 1..64 MiB");
    return -1;
  }
  void **raw = handles(b, parameters, n);
  if (!raw) return -1;
  int result = operation(c->value, raw, n, bucket_bytes, b->error, sizeof(b->error));
  free(raw);
  if (result && !b->error[0]) strcpy(b->error, "gradient bucket averaging failed");
  return result;
}
