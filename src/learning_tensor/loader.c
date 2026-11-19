#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Backend Backend;
typedef struct {
  void *library_id;
  void (*destroy)(void *);
  void *value;
} NativeTensor;
typedef struct {
  void *library_id;
  void (*destroy)(void *);
  void *value;
} NativeAdam;
typedef struct {
  void *library_id;
  void (*destroy)(void *);
  void *value;
} NativeCollective;
struct Backend {
  void *library;
  char error[4096];
  double *staged_values;
  int64_t staged_shape[8];
  int32_t staged_count, staged_rank;
  int (*abi)(void);
  const char *(*version)(void);
  void *(*create)(const double *, const int64_t *, int, int, int, int, char *, int);
  void (*destroy)(void *);
  void *(*binary)(void *, void *, int, char *, int);
  void *(*unary)(void *, int, char *, int);
  int (*backward)(void *, int, char *, int);
  int (*zero_grad)(void *, char *, int);
  int (*rank)(void *, char *, int);
  int64_t (*dim)(void *, int, char *, int);
  int64_t (*size)(void *, char *, int);
  double (*value_at)(void *, int64_t, int, char *, int);
  int (*device_count)(void);
  int64_t (*cuda_free_bytes)(int, char *, int);
  int (*cuda_memory_stats_v1)(int, int, int64_t *, int, char *, int);
  int (*cuda_reset_memory_peaks_v1)(int, int, char *, int);
  int (*cuda_fp32_settings_v1)(int32_t *, int, char *, int);
  int (*configure_cuda_tf32_v1)(int, int, int, int, int32_t *, int, char *, int);
  int (*read)(void *, double *, int64_t, int, char *, int);
  int (*metadata)(void *, int, char *, int);
  void *(*shape_op)(void *, int, const int64_t *, int, char *, int);
  void *(*scalar_op)(void *, int, double, double, char *, int);
  void *(*join)(void **, int, int, int, char *, int);
  void *(*index_select)(void *, void *, int, char *, int);
  void *(*pullback)(void *, void *, void *, int, char *, int);
  void *(*where)(void *, void *, void *, char *, int);
  void *(*adam_create)(void **, int, double, double, double, double, char *, int);
  void (*adam_destroy)(void *);
  int (*adam_step)(void *, double, double, char *, int);
  int (*adam_zero_grad)(void *, char *, int);
  int (*adam_learning_rate)(void *, double, char *, int);
  int (*adam_checkpoint)(void *, const char *, int, char *, int);
  int (*adam_audit_metadata)(void *, char *, int, char *, int);
  void *(*adam_audit_tensor)(void *, int, int, char *, int);
  int (*nccl_id)(unsigned char *, char *, int);
  void *(*nccl_connect)(const unsigned char *, int, int, int, int, char *, int);
  int (*nccl_close)(void *, char *, int);
  void (*nccl_destroy)(void *);
  void *(*nccl_reduce)(void *, void *, int, char *, int);
  int (*nccl_broadcast)(void *, void *, int, char *, int);
  int (*nccl_gradients)(void *, void **, int, char *, int);
  int (*nccl_control)(void *, const int64_t *, int64_t *, int, int, char *, int);
};
static moonbit_bytes_t to_bytes(const char *s) {
  size_t n = strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, s, n);
  return out;
}
static void cleanup_backend(void *ptr) {
  Backend *b = ptr;
  free(b->staged_values);
  /* LibTorch has process-global pools. Keep the module loaded for process life. */
}
static void cleanup_tensor(void *ptr) {
  NativeTensor *t = ptr;
  if (t->value && t->destroy) t->destroy(t->value);
}
static NativeTensor *wrap(Backend *b, void *value);
MOONBIT_FFI_EXPORT Backend *mr_tensor_open(moonbit_bytes_t path) {
  Backend *b = moonbit_make_external_object(cleanup_backend, sizeof(Backend));
  memset(b, 0, sizeof(*b));
  int32_t path_length = Moonbit_array_length(path);
  char *terminated_path = malloc((size_t)path_length + 1);
  if (!terminated_path) { strcpy(b->error, "plugin path allocation failed"); return b; }
  memcpy(terminated_path, path, (size_t)path_length);
  terminated_path[path_length] = '\0';
  if (strlen(terminated_path) != (size_t)path_length) {
    free(terminated_path);
    strcpy(b->error, "plugin path contains a NUL byte");
    return b;
  }
  b->library = dlopen(terminated_path, RTLD_NOW | RTLD_LOCAL);
  free(terminated_path);
  if (!b->library) { snprintf(b->error, sizeof(b->error), "%s", dlerror()); return b; }
#define LOAD(field, symbol) do { *(void **)(&b->field) = dlsym(b->library, symbol); if (!b->field) { snprintf(b->error, sizeof(b->error), "missing tensor ABI symbol %s", symbol); return b; } } while (0)
  LOAD(abi, "mr_tensor_abi"); LOAD(version, "mr_tensor_version");
  if (b->abi() != 2) { strcpy(b->error, "unsupported tensor ABI version (expected 2)"); return b; }
  LOAD(create, "mr_tensor_create"); LOAD(destroy, "mr_tensor_destroy");
  LOAD(binary, "mr_tensor_binary"); LOAD(unary, "mr_tensor_unary");
  LOAD(backward, "mr_tensor_backward"); LOAD(zero_grad, "mr_tensor_zero_grad");
  LOAD(rank, "mr_tensor_rank"); LOAD(dim, "mr_tensor_dim");
  LOAD(size, "mr_tensor_size"); LOAD(value_at, "mr_tensor_value");
  LOAD(device_count, "mr_tensor_device_count");
  LOAD(cuda_free_bytes, "mr_tensor_cuda_free_bytes");
  LOAD(read, "mr_tensor_read"); LOAD(metadata, "mr_tensor_metadata");
  LOAD(shape_op, "mr_tensor_shape_op"); LOAD(scalar_op, "mr_tensor_scalar_op");
  LOAD(join, "mr_tensor_join"); LOAD(index_select, "mr_tensor_index_select");
  LOAD(pullback, "mr_tensor_pullback"); LOAD(adam_create, "mr_adam_create");
  LOAD(where, "mr_tensor_where");
  LOAD(adam_destroy, "mr_adam_destroy"); LOAD(adam_step, "mr_adam_step");
  LOAD(adam_zero_grad, "mr_adam_zero_grad"); LOAD(adam_learning_rate, "mr_adam_learning_rate");
  LOAD(adam_checkpoint, "mr_adam_checkpoint");
  LOAD(nccl_id, "mr_nccl_unique_id"); LOAD(nccl_connect, "mr_nccl_connect");
  LOAD(nccl_close, "mr_nccl_close"); LOAD(nccl_destroy, "mr_nccl_destroy");
  LOAD(nccl_reduce, "mr_nccl_all_reduce"); LOAD(nccl_broadcast, "mr_nccl_broadcast");
  LOAD(nccl_gradients, "mr_nccl_average_gradients"); LOAD(nccl_control, "mr_nccl_control");
  /* Optional extensions: old ABI-2 plugins remain usable for training. */
  *(void **)(&b->adam_audit_metadata) = dlsym(b->library, "mr_adam_audit_metadata");
  *(void **)(&b->adam_audit_tensor) = dlsym(b->library, "mr_adam_audit_tensor");
  *(void **)(&b->cuda_memory_stats_v1) = dlsym(b->library, "mr_tensor_cuda_memory_stats_v1");
  *(void **)(&b->cuda_reset_memory_peaks_v1) = dlsym(b->library, "mr_tensor_cuda_reset_memory_peaks_v1");
  *(void **)(&b->cuda_fp32_settings_v1) = dlsym(b->library, "mr_tensor_cuda_fp32_settings_v1");
  *(void **)(&b->configure_cuda_tf32_v1) = dlsym(b->library, "mr_tensor_configure_cuda_tf32_v1");
#undef LOAD
  return b;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_tensor_error(Backend *b) { return to_bytes(b->error); }
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_tensor_torch_version(Backend *b) { return to_bytes(b->version ? b->version() : ""); }
MOONBIT_FFI_EXPORT int32_t mr_tensor_device_count(Backend *b) { return b->device_count ? b->device_count() : -1; }
MOONBIT_FFI_EXPORT int64_t mr_tensor_cuda_free_bytes_call(Backend *b, int32_t device) {
  b->error[0] = 0;
  return b->cuda_free_bytes(device, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_cuda_memory_telemetry(Backend *b) {
  return b->cuda_memory_stats_v1 && b->cuda_reset_memory_peaks_v1;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_cuda_fp32_control(Backend *b) {
  return b->cuda_fp32_settings_v1 && b->configure_cuda_tf32_v1;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_cuda_fp32_settings_call(Backend *b, int32_t *out) {
  b->error[0] = 0;
  if (!b->cuda_fp32_settings_v1) {
    strcpy(b->error, "plugin lacks optional CUDA FP32 precision extension; rebuild plugin"); return -1;
  }
  if (Moonbit_array_length(out) != 7) { strcpy(b->error, "invalid FP32 precision output size"); return -1; }
  int result = b->cuda_fp32_settings_v1(out, 7, b->error, sizeof(b->error));
  if (result && !b->error[0]) strcpy(b->error, "CUDA precision query failed");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_configure_cuda_tf32_call(Backend *b, int32_t matmul, int32_t conv, int32_t rnn, int32_t startup, int32_t *out) {
  b->error[0] = 0;
  if (!b->configure_cuda_tf32_v1) {
    strcpy(b->error, "plugin lacks optional CUDA FP32 precision extension; rebuild plugin"); return -1;
  }
  if (Moonbit_array_length(out) != 7) { strcpy(b->error, "invalid FP32 precision output size"); return -1; }
  int result = b->configure_cuda_tf32_v1(matmul, conv, rnn, startup, out, 7, b->error, sizeof(b->error));
  if (result && !b->error[0]) strcpy(b->error, "CUDA precision startup setting failed");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_cuda_memory_stats_call(Backend *b, int32_t device, int32_t synchronize, int64_t *output) {
  b->error[0] = 0;
  if (!b->cuda_memory_stats_v1) {
    strcpy(b->error, "plugin lacks optional CUDA allocator telemetry extension; rebuild plugin"); return -1;
  }
  if (Moonbit_array_length(output) != 6) {
    strcpy(b->error, "CUDA allocator telemetry output must contain six Int64 values"); return -1;
  }
  int result = b->cuda_memory_stats_v1(device, synchronize, output, 6, b->error, sizeof(b->error));
  if (result && !b->error[0]) strcpy(b->error, "CUDA allocator telemetry query failed");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_cuda_reset_memory_peaks_call(Backend *b, int32_t device, int32_t synchronize) {
  b->error[0] = 0;
  if (!b->cuda_reset_memory_peaks_v1) {
    strcpy(b->error, "plugin lacks optional CUDA allocator telemetry extension; rebuild plugin"); return -1;
  }
  int result = b->cuda_reset_memory_peaks_v1(device, synchronize, b->error, sizeof(b->error));
  if (result && !b->error[0]) strcpy(b->error, "CUDA allocator peak reset failed");
  return result;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_begin(Backend *b, int32_t rank, int32_t count) {
  b->error[0] = 0;
  if (!b->create || rank < 0 || rank > 8 || count < 0) {
    strcpy(b->error, "invalid tensor input or uninitialized backend"); return -1;
  }
  double *values = calloc((size_t)(count ? count : 1), sizeof(double));
  if (!values) { strcpy(b->error, "tensor staging allocation failed"); return -1; }
  free(b->staged_values); b->staged_values = values;
  b->staged_rank = rank; b->staged_count = count;
  memset(b->staged_shape, 0, sizeof(b->staged_shape));
  return 0;
}
MOONBIT_FFI_EXPORT void mr_tensor_put_dim(Backend *b, int32_t index, int32_t dim) {
  if (index >= 0 && index < b->staged_rank) b->staged_shape[index] = dim;
}
MOONBIT_FFI_EXPORT void mr_tensor_put_value(Backend *b, int32_t index, double value) {
  if (index >= 0 && index < b->staged_count) b->staged_values[index] = value;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_make(Backend *b, int32_t cuda_device, int32_t requires_grad, int32_t dtype) {
  b->error[0] = 0;
  if (!b->create || !b->staged_values) {
    strcpy(b->error, "tensor backend or staging buffer is unavailable");
    return wrap(b, NULL);
  }
  void *value = b->create(b->staged_values, b->staged_shape, b->staged_rank, cuda_device, requires_grad, dtype, b->error, sizeof(b->error));
  free(b->staged_values); b->staged_values = NULL;
  if (!value && !b->error[0]) strcpy(b->error, "LibTorch tensor creation failed");
  NativeTensor *out = moonbit_make_external_object(cleanup_tensor, sizeof(NativeTensor));
  out->library_id = b->library; out->destroy = b->destroy; out->value = value; return out;
}
static NativeTensor *wrap(Backend *b, void *value) {
  NativeTensor *out = moonbit_make_external_object(cleanup_tensor, sizeof(NativeTensor));
  out->library_id = b->library; out->destroy = b->destroy; out->value = value; return out;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_binary_call(Backend *b, NativeTensor *a, NativeTensor *c, int32_t op) {
  b->error[0] = 0;
  if (!b->binary || !a || !c || !a->value || !c->value || a->library_id != b->library || c->library_id != b->library) { strcpy(b->error, "tensor backend mismatch or empty tensor"); return wrap(b, NULL); }
  void *value = b->binary(a->value, c->value, op, b->error, sizeof(b->error));
  if (!value && !b->error[0]) strcpy(b->error, "LibTorch binary operation failed");
  return wrap(b, value);
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_unary_call(Backend *b, NativeTensor *a, int32_t op) {
  b->error[0] = 0;
  if (!b->unary || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "tensor backend mismatch or empty tensor"); return wrap(b, NULL); }
  void *value = b->unary(a->value, op, b->error, sizeof(b->error));
  if (!value && !b->error[0]) strcpy(b->error, "LibTorch unary operation failed");
  return wrap(b, value);
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_backward_call(Backend *b, NativeTensor *a, int32_t retain_graph) {
  b->error[0] = 0;
  if (!b->backward || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor backward handle"); return -1; }
  return b->backward(a->value, retain_graph, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_zero_grad_call(Backend *b, NativeTensor *a) {
  b->error[0] = 0;
  if (!b->zero_grad || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor gradient handle"); return -1; }
  return b->zero_grad(a->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_rank_call(Backend *b, NativeTensor *a) {
  b->error[0] = 0;
  if (!b->rank || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor shape handle"); return -1; }
  return b->rank(a->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_dim_call(Backend *b, NativeTensor *a, int32_t axis) {
  b->error[0] = 0;
  if (!b->dim || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor dimension handle"); return -1; }
  int64_t dimension = b->dim(a->value, axis, b->error, sizeof(b->error));
  if (dimension > INT32_MAX) { strcpy(b->error, "dimension exceeds MoonBit array limit"); return -1; }
  return (int32_t)dimension;
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_size_call(Backend *b, NativeTensor *a) {
  b->error[0] = 0;
  if (!b->size || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor size handle"); return -1; }
  int64_t size = b->size(a->value, b->error, sizeof(b->error));
  if (size > INT32_MAX) { strcpy(b->error, "tensor exceeds MoonBit array limit"); return -1; }
  return (int32_t)size;
}
MOONBIT_FFI_EXPORT double mr_tensor_value_call(Backend *b, NativeTensor *a, int32_t index, int32_t gradient) {
  b->error[0] = 0;
  if (!b->value_at || !a || !a->value || a->library_id != b->library) { strcpy(b->error, "invalid tensor value handle"); return 0; }
  return b->value_at(a->value, index, gradient, b->error, sizeof(b->error));
}

static int valid(Backend *b, NativeTensor *a) {
  if (a && a->value && a->library_id == b->library) return 1;
  strcpy(b->error, "tensor backend mismatch or empty tensor"); return 0;
}
static void **handles(Backend *b, NativeTensor **values, int n) {
  void **out = malloc((size_t)(n ? n : 1) * sizeof(void *));
  if (!out) { strcpy(b->error, "tensor handle array allocation failed"); return NULL; }
  for (int i = 0; i < n; ++i) {
    if (!valid(b, values[i])) { free(out); return NULL; }
    out[i] = values[i]->value;
  }
  return out;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_create_bulk(Backend *b, int32_t *shape, double *values, int32_t device, int32_t grad, int32_t dtype) {
  b->error[0] = 0;
  int n = Moonbit_array_length(shape);
  int64_t dimensions[8], count = 1;
  if (n > 8) { strcpy(b->error, "tensor rank exceeds 8"); return wrap(b, NULL); }
  for (int i = 0; i < n; ++i) {
    dimensions[i] = shape[i];
    if (shape[i] < 0 || (shape[i] && count > INT32_MAX / shape[i])) {
      strcpy(b->error, "invalid tensor shape"); return wrap(b, NULL);
    }
    count *= shape[i];
  }
  if (count != Moonbit_array_length(values)) { strcpy(b->error, "tensor value count mismatch"); return wrap(b, NULL); }
  return wrap(b, b->create(values, dimensions, n, device, grad, dtype, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_read_call(Backend *b, NativeTensor *a, double *values, int32_t gradient) {
  b->error[0] = 0;
  if (!valid(b, a)) return -1;
  return b->read(a->value, values, Moonbit_array_length(values), gradient, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_metadata_call(Backend *b, NativeTensor *a, int32_t field) {
  b->error[0] = 0;
  if (!valid(b, a)) return -2;
  return b->metadata(a->value, field, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_shape_call(Backend *b, NativeTensor *a, int32_t op, int32_t *args) {
  b->error[0] = 0;
  if (!valid(b, a)) return wrap(b, NULL);
  int n = Moonbit_array_length(args);
  int64_t wide[8];
  if (n > 8) { strcpy(b->error, "too many tensor shape arguments"); return wrap(b, NULL); }
  for (int i = 0; i < n; ++i) wide[i] = args[i];
  return wrap(b, b->shape_op(a->value, op, wide, n, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_scalar_call(Backend *b, NativeTensor *a, int32_t op, double x, double y) {
  b->error[0] = 0;
  if (!valid(b, a)) return wrap(b, NULL);
  return wrap(b, b->scalar_op(a->value, op, x, y, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_join_call(Backend *b, NativeTensor **values, int32_t axis, int32_t stack) {
  b->error[0] = 0;
  int n = Moonbit_array_length(values);
  void **raw = handles(b, values, n);
  if (!raw) return wrap(b, NULL);
  void *result = b->join(raw, n, axis, stack, b->error, sizeof(b->error));
  free(raw); return wrap(b, result);
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_index_select_call(Backend *b, NativeTensor *a, NativeTensor *indices, int32_t axis) {
  b->error[0] = 0;
  if (!valid(b, a) || !valid(b, indices)) return wrap(b, NULL);
  return wrap(b, b->index_select(a->value, indices->value, axis, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_pullback_call(Backend *b, NativeTensor *a, NativeTensor *input, NativeTensor *cotangent, int32_t retain_graph) {
  b->error[0] = 0;
  if (!valid(b, a) || !valid(b, input) || !valid(b, cotangent)) return wrap(b, NULL);
  return wrap(b, b->pullback(a->value, input->value, cotangent->value, retain_graph, b->error, sizeof(b->error)));
}
static void cleanup_adam(void *ptr) {
  NativeAdam *a = ptr;
  if (a->value && a->destroy) a->destroy(a->value);
}
MOONBIT_FFI_EXPORT NativeAdam *mr_adam_create_call(Backend *b, NativeTensor **parameters, double lr, double beta1, double beta2, double eps) {
  b->error[0] = 0;
  NativeAdam *a = moonbit_make_external_object(cleanup_adam, sizeof(NativeAdam));
  a->library_id = b->library; a->destroy = b->adam_destroy; a->value = NULL;
  int n = Moonbit_array_length(parameters);
  void **raw = handles(b, parameters, n);
  if (!raw) return a;
  a->value = b->adam_create(raw, n, lr, beta1, beta2, eps, b->error, sizeof(b->error));
  free(raw); return a;
}
static int valid_adam(Backend *b, NativeAdam *a) {
  if (a && a->value && a->library_id == b->library) return 1;
  strcpy(b->error, "invalid Adam backend or handle"); return 0;
}
MOONBIT_FFI_EXPORT int32_t mr_adam_step_call(Backend *b, NativeAdam *a, double max_norm, double max_value) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return -1;
  return b->adam_step(a->value, max_norm, max_value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_where_call(Backend *b, NativeTensor *condition, NativeTensor *yes, NativeTensor *no) {
  b->error[0] = 0;
  if (!valid(b, condition) || !valid(b, yes) || !valid(b, no)) return wrap(b, NULL);
  return wrap(b, b->where(condition->value, yes->value, no->value, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_adam_zero_call(Backend *b, NativeAdam *a) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return -1;
  return b->adam_zero_grad(a->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_adam_rate_call(Backend *b, NativeAdam *a, double lr) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return -1;
  return b->adam_learning_rate(a->value, lr, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_adam_checkpoint_call(Backend *b, NativeAdam *a, moonbit_bytes_t path, int32_t load) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return -1;
  int n = Moonbit_array_length(path);
  if (memchr(path, 0, n)) { strcpy(b->error, "NUL byte in checkpoint path"); return -1; }
  char *terminated = malloc((size_t)n + 1);
  if (!terminated) { strcpy(b->error, "checkpoint path allocation failed"); return -1; }
  memcpy(terminated, path, n); terminated[n] = 0;
  int result = b->adam_checkpoint(a->value, terminated, load, b->error, sizeof(b->error));
  free(terminated); return result;
}

static void cleanup_collective(void *ptr) {
  NativeCollective *c = ptr;
  if (c->value && c->destroy) c->destroy(c->value);
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_adam_audit_metadata_call(Backend *b, NativeAdam *a) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return to_bytes("");
  if (!b->adam_audit_metadata) { strcpy(b->error, "plugin lacks optional Adam audit extension; rebuild the plugin"); return to_bytes(""); }
  const int capacity = 2 * 1024 * 1024;
  char *metadata = calloc((size_t)capacity, 1);
  if (!metadata) { strcpy(b->error, "optimizer audit buffer allocation failed"); return to_bytes(""); }
  int result = b->adam_audit_metadata(a->value, metadata, capacity, b->error, sizeof(b->error));
  moonbit_bytes_t out = to_bytes(result == 0 ? metadata : "");
  free(metadata); return out;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_adam_audit_tensor_call(Backend *b, NativeAdam *a, int32_t index, int32_t kind) {
  b->error[0] = 0;
  if (!valid_adam(b, a)) return wrap(b, NULL);
  if (!b->adam_audit_tensor) { strcpy(b->error, "plugin lacks optional Adam audit extension; rebuild the plugin"); return wrap(b, NULL); }
  return wrap(b, b->adam_audit_tensor(a->value, index, kind, b->error, sizeof(b->error)));
}
static int valid_collective(Backend *b, NativeCollective *c) {
  if (c && c->value && c->library_id == b->library) return 1;
  strcpy(b->error, "invalid NCCL backend or handle"); return 0;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_nccl_id_call(Backend *b) {
  b->error[0] = 0;
  moonbit_bytes_t out = moonbit_make_bytes(128, 0);
  b->nccl_id(out, b->error, sizeof(b->error));
  return out;
}
MOONBIT_FFI_EXPORT NativeCollective *mr_nccl_connect_call(Backend *b, moonbit_bytes_t id, int32_t rank, int32_t world, int32_t device, int32_t timeout) {
  b->error[0] = 0;
  NativeCollective *c = moonbit_make_external_object(cleanup_collective, sizeof(NativeCollective));
  c->library_id = b->library; c->destroy = b->nccl_destroy; c->value = NULL;
  if (Moonbit_array_length(id) != 128) { strcpy(b->error, "NCCL unique ID must contain 128 bytes"); return c; }
  c->value = b->nccl_connect(id, rank, world, device, timeout, b->error, sizeof(b->error));
  if (!c->value && !b->error[0]) strcpy(b->error, "NCCL communicator creation failed");
  return c;
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_close_call(Backend *b, NativeCollective *c) {
  b->error[0] = 0;
  if (!valid_collective(b, c)) return -1;
  return b->nccl_close(c->value, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_nccl_reduce_call(Backend *b, NativeCollective *c, NativeTensor *t, int32_t op) {
  b->error[0] = 0;
  if (!valid_collective(b, c) || !valid(b, t)) return wrap(b, NULL);
  return wrap(b, b->nccl_reduce(c->value, t->value, op, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_broadcast_call(Backend *b, NativeCollective *c, NativeTensor *t, int32_t root) {
  b->error[0] = 0;
  if (!valid_collective(b, c) || !valid(b, t)) return -1;
  return b->nccl_broadcast(c->value, t->value, root, b->error, sizeof(b->error));
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_gradients_call(Backend *b, NativeCollective *c, NativeTensor **parameters) {
  b->error[0] = 0;
  if (!valid_collective(b, c)) return -1;
  int n = Moonbit_array_length(parameters);
  void **raw = handles(b, parameters, n);
  if (!raw) return -1;
  int result = b->nccl_gradients(c->value, raw, n, b->error, sizeof(b->error));
  free(raw); return result;
}
MOONBIT_FFI_EXPORT int32_t mr_nccl_control_call(Backend *b, NativeCollective *c, int64_t *input, int64_t *output, int32_t op) {
  b->error[0] = 0;
  if (!valid_collective(b, c)) return -1;
  int n = Moonbit_array_length(input);
  if (Moonbit_array_length(output) != n) { strcpy(b->error, "NCCL control input/output size mismatch"); return -1; }
  return b->nccl_control(c->value, input, output, n, op, b->error, sizeof(b->error));
}
// Optional native and exact-operation submission extensions.
#include "layer_norm_loader.inc"
#include "fk_submitted_loader.inc"
#include "profiling_loader.inc"
#include "collective_bucket_loader.inc"
#include "graph_loader.inc"
#include "precision_loader.inc"
#include "adam_checked_norm_loader.inc"
#include "adam_smc_loader.inc"
#include "operator_diagnostics_loader.inc"
#include "smc_algebra_loader.inc"
#include "native_cross_loader.inc"
#include "compact_rotation_loader.inc"
#include "fused_rotation_loader.inc"
#include "geometry_tail_loader.inc"
#include "geometry_vjp_loader.inc"
#include "compact_heading_loader.inc"
#include "split_sections_loader.inc"
MOONBIT_FFI_EXPORT int32_t mr_muon_update_call(Backend *b, NativeTensor *p,
                                               NativeTensor *momentum, double lr) {
  b->error[0] = 0;
  int (*op)(void *, void *, double, char *, int) = NULL;
  *(void **)(&op) = dlsym(b->library, "mr_muon_update_v1");
  if (!op || !p || !momentum || !p->value || !momentum->value ||
      p->library_id != b->library || momentum->library_id != b->library) {
    strcpy(b->error, "Muon extension unavailable or tensor backend mismatch");
    return -1;
  }
  return op(p->value, momentum->value, lr, b->error, sizeof(b->error));
}
#include "compiled_block_loader.inc"

typedef struct {
  void *id, *sim;
  void (*destroy)(void *);
  void *(*exchange)(void *, int, void *, char *, int);
} Mjlab;
static void cleanup_mjlab(void *ptr) {
  Mjlab *s = ptr;
  if (s->sim) s->destroy(s->sim);
  s->sim = NULL;
}
MOONBIT_FFI_EXPORT Mjlab *mr_mjlab_open_call(Backend *b, moonbit_bytes_t path) {
  Mjlab *s = moonbit_make_external_object(cleanup_mjlab, sizeof(Mjlab));
  memset(s, 0, sizeof(*s));
  s->id = b->library;
  b->error[0] = 0;
  void *(*open_sim)(const char *, char *, int) = NULL;
  *(void **)(&open_sim) = dlsym(b->library, "mr_mjlab_open_v1");
  *(void **)(&s->destroy) = dlsym(b->library, "mr_mjlab_close_v1");
  *(void **)(&s->exchange) = dlsym(b->library, "mr_mjlab_exchange_v1");
  if (!open_sim || !s->destroy || !s->exchange) {
    strcpy(b->error, "LibTorch plugin was built without the mjlab physics provider"); return s;
  }
  int n = Moonbit_array_length(path);
  if (n <= 0 || memchr(path, 0, n)) { strcpy(b->error, "invalid mjlab config path"); return s; }
  char *file = malloc((size_t)n+1);
  if (!file) { strcpy(b->error, "mjlab path allocation failed"); return s; }
  memcpy(file, path, n); file[n] = 0;
  s->sim = open_sim(file, b->error, sizeof(b->error));
  free(file);
  return s;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_mjlab_exchange_call(Backend *b, Mjlab *s, int op,
                                                         NativeTensor **args) {
  b->error[0] = 0;
  int n = Moonbit_array_length(args);
  if (!s->sim || s->id != b->library || n > 1) {
    strcpy(b->error, "invalid mjlab session or arguments"); return wrap(b, NULL);
  }
  if (n && !valid(b, args[0])) return wrap(b, NULL);
  return wrap(b, s->exchange(s->sim, op, n ? args[0]->value : NULL, b->error, sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_checkpoint_call(Backend *b, NativeTensor *t,
                                                     moonbit_bytes_t path, int32_t load) {
  int (*op)(void *, const char *, int, char *, int) = NULL;
  b->error[0] = 0;
  *(void **)(&op) = dlsym(b->library, "mr_tensor_checkpoint_v1");
  if (!op) { strcpy(b->error, "tensor checkpoint extension unavailable"); return -1; }
  if (!valid(b,t)) return -1;
  int n = Moonbit_array_length(path);
  if (!n || memchr(path, 0, n)) { strcpy(b->error, "invalid checkpoint path"); return -1; }
  char *file = malloc((size_t)n + 1);
  if (!file) { strcpy(b->error, "checkpoint path allocation failed"); return -1; }
  memcpy(file, path, n); file[n] = 0;
  int result = op(t->value, file, load, b->error, sizeof(b->error));
  free(file);
  return result;
}

MOONBIT_FFI_EXPORT int32_t mr_adam_author_call(Backend *b, NativeAdam *a, NativeTensor **all, double clip) {
  b->error[0] = 0;
  int (*op)(void *,void **,int,double,char *,int) = NULL;
  *(void **)(&op) = dlsym(b->library,"mr_adam_author_v1");
  if (!op) { strcpy(b->error,"missing fused GenCoord optimizer"); return -1; }
  if (!valid_adam(b,a)) return -1;
  int n = Moonbit_array_length(all);
  void **raw = handles(b,all,n);
  if (!raw) return -1;
  int result = op(a->value,raw,n,clip,b->error,sizeof(b->error));
  free(raw); return result;
}

MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_group_sum_call(
    Backend *b, NativeTensor *values, NativeTensor *indices, int32_t groups) {
  b->error[0] = 0;
  if (!valid(b, values) || !valid(b, indices)) return wrap(b, NULL);
  void *(*op)(void *, void *, int, char *, int) = NULL;
  *(void **)(&op) = dlsym(b->library, "mr_tensor_group_sum_v1");
  if (!op) {
    strcpy(b->error, "tensor plugin lacks grouped sum");
    return wrap(b, NULL);
  }
  return wrap(b, op(values->value, indices->value, groups, b->error, sizeof(b->error)));
}
