/* Optional ABI-2 extension. Old plugins keep the FP32 path usable. */
typedef void *(*mr_cast_float_fn)(void *, int, char *, int);
typedef void *(*mr_linear_bf16_fn)(void *, void *, void *, char *, int);
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_linear(Backend *b) {
  return b && b->library && dlsym(b->library, "mr_tensor_linear_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_linear_call(
    Backend *b, NativeTensor *input, NativeTensor *weight, NativeTensor *bias) {
  b->error[0] = 0;
  mr_linear_bf16_fn op = NULL;
  *(void **)(&op) = dlsym(b->library, "mr_tensor_linear_v1");
  if (!op) { strcpy(b->error, "plugin lacks optional native Linear extension"); return wrap(b, NULL); }
  if (!valid(b, input) || !valid(b, weight) || !valid(b, bias)) return wrap(b, NULL);
  return wrap(b, op(input->value, weight->value, bias->value, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_bf16_linear(Backend *b) {
  return b && b->library && dlsym(b->library, "mr_tensor_cast_float_v1") &&
    dlsym(b->library, "mr_tensor_linear_bf16_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_cast_float_call(
    Backend *b, NativeTensor *input, int dtype) {
  b->error[0] = 0;
  mr_cast_float_fn op = NULL;
  *(void **)(&op) = dlsym(b->library, "mr_tensor_cast_float_v1");
  if (!op) { strcpy(b->error, "plugin lacks optional floating cast extension"); return wrap(b, NULL); }
  if (!valid(b, input)) return wrap(b, NULL);
  return wrap(b, op(input->value, dtype, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_linear_bf16_call(
    Backend *b, NativeTensor *input, NativeTensor *weight, NativeTensor *bias) {
  b->error[0] = 0;
  mr_linear_bf16_fn op = NULL;
  *(void **)(&op) = dlsym(b->library, "mr_tensor_linear_bf16_v1");
  if (!op) { strcpy(b->error, "plugin lacks optional BF16 Linear extension"); return wrap(b, NULL); }
  if (!valid(b, input) || !valid(b, weight) || !valid(b, bias)) return wrap(b, NULL);
  return wrap(b, op(input->value, weight->value, bias->value, b->error, sizeof(b->error)));
}
