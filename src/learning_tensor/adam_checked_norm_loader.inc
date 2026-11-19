/* Optional ABI-2 route. Include after Backend/NativeAdam/valid_adam. */
typedef int (*mr_checked_norm_adam_fn)(void *, double, double, char *, int);
static mr_checked_norm_adam_fn mr_checked_norm_adam_symbol(Backend *b) {
  if (!b || !b->library) return NULL;
  mr_checked_norm_adam_fn result = NULL;
  *(void **)(&result) = dlsym(b->library, "mr_adam_step_checked_norm_v1");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_adam_has_checked_norm(Backend *b) {
  return mr_checked_norm_adam_symbol(b) != NULL;
}
MOONBIT_FFI_EXPORT int32_t mr_adam_step_checked_norm_call(
    Backend *b, NativeAdam *a, double max_norm, double max_value) {
  b->error[0] = 0;
  mr_checked_norm_adam_fn operation = mr_checked_norm_adam_symbol(b);
  if (!operation) {
    strcpy(b->error, "plugin lacks optional checked-norm Adam extension; rebuild plugin");
    return -1;
  }
  if (!valid_adam(b, a)) return -1;
  const int result = operation(a->value, max_norm, max_value, b->error, sizeof(b->error));
  if (result && !b->error[0]) strcpy(b->error, "checked-norm Adam failed");
  return result;
}
