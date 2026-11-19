MOONBIT_FFI_EXPORT NativeTensor* mr_tensor_axis_angle_submitted_call(
    Backend* b, NativeTensor* angle, double x, double y, double z) {
  b->error[0] = 0;
  void* (*op)(void*, double, double, double, char*, int) = NULL;
  *(void**)(&op) = dlsym(b->library, "mr_tensor_axis_angle_submitted_v1");
  if (!op) { strcpy(b->error, "plugin lacks submitted axis-angle"); return wrap(b, NULL); }
  if (!angle || !angle->value || angle->library_id != b->library) {
    strcpy(b->error, "submitted axis-angle backend mismatch"); return wrap(b, NULL);
  }
  return wrap(b, op(angle->value, x, y, z, b->error, sizeof(b->error)));
}
