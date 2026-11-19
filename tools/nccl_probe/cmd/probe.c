/* Deliberately small public C ABI subset; no CUDA/NCCL build-time dependency.
 * ABI constants/signatures checked against NVIDIA/nccl v2.28.9-1 nccl.h.in
 * and CUDA Runtime 13.0. Runtime versions are checked before any allocation.
 * This probe is single-invocation-per-process; library handles stay loaded
 * until exit because ncclGetUniqueId owns a live bootstrap listener thread. */
#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct ncclComm *comm_t;
typedef struct CUstream_st *stream_t;
typedef struct { char bytes[128]; } unique_id_t;
_Static_assert(sizeof(float) == 4 && sizeof(unique_id_t) == 128 && sizeof(void *) == 8, "64-bit CUDA/NCCL public ABI required");
enum { NCCL_FLOAT32 = 7, NCCL_SUM = 0, CUDA_HOST_TO_DEVICE = 1, CUDA_DEVICE_TO_HOST = 2 };
static char failure[1024];
static int nccl_version, cuda_version;
static int (*get_version)(int *);
static int (*get_id)(unique_id_t *);
static int (*comm_init)(comm_t *, int, unique_id_t, int);
static int (*comm_destroy)(comm_t);
static int (*reduce_sum)(const void *, void *, size_t, int, int, comm_t, stream_t);
static const char *(*nccl_error)(int);
static int (*runtime_version)(int *);
static int (*set_device)(int);
static int (*memory_info)(size_t *, size_t *);
static int (*device_alloc)(void **, size_t);
static int (*device_free)(void *);
static int (*copy_bytes)(void *, const void *, size_t, int);
static int (*stream_create)(stream_t *);
static int (*stream_sync)(stream_t);
static int (*stream_destroy)(stream_t);
static const char *(*cuda_error)(int);

static moonbit_bytes_t result_bytes(const char *s) {
  size_t n = strlen(s);
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)n, 0);
  memcpy(result, s, n);
  return result;
}

static void deadline(int sig) {
  (void)sig;
  static const char message[] = "NCCL_PROBE_TIMEOUT: internal 55-second deadline\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(124);
}

static double seconds_now(void) {
  struct timespec time;
  clock_gettime(CLOCK_MONOTONIC, &time);
  return time.tv_sec + time.tv_nsec * 1e-9;
}

static int check(int code, const char *operation, int is_nccl) {
  if (!code) return 0;
  const char *message = is_nccl ? nccl_error(code) : cuda_error(code);
  snprintf(failure, sizeof(failure), "%s failed (%d): %s", operation, code, message);
  return -1;
}

#define LOAD(handle, destination, name) do { \
  void *symbol = dlsym(handle, name); \
  if (!symbol) { snprintf(failure, sizeof(failure), "missing symbol %s: %s", name, dlerror()); return -1; } \
  memcpy(&destination, &symbol, sizeof(symbol)); \
} while (0)

MOONBIT_FFI_EXPORT int32_t mr_nccl_probe_open(moonbit_bytes_t nccl_path, moonbit_bytes_t cuda_path) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = deadline;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGALRM, &action, NULL)) { snprintf(failure, sizeof(failure), "cannot install probe deadline"); return -1; }
  alarm(55);
  void *cuda = dlopen((const char *)cuda_path, RTLD_NOW | RTLD_GLOBAL);
  if (!cuda) { snprintf(failure, sizeof(failure), "CUDA dlopen: %s", dlerror()); return -1; }
  void *nccl = dlopen((const char *)nccl_path, RTLD_NOW | RTLD_GLOBAL);
  if (!nccl) { snprintf(failure, sizeof(failure), "NCCL dlopen: %s", dlerror()); return -1; }
  LOAD(nccl, get_version, "ncclGetVersion");
  LOAD(nccl, get_id, "ncclGetUniqueId");
  LOAD(nccl, comm_init, "ncclCommInitRank");
  LOAD(nccl, comm_destroy, "ncclCommDestroy");
  LOAD(nccl, reduce_sum, "ncclAllReduce");
  LOAD(nccl, nccl_error, "ncclGetErrorString");
  LOAD(cuda, runtime_version, "cudaRuntimeGetVersion");
  LOAD(cuda, set_device, "cudaSetDevice");
  LOAD(cuda, memory_info, "cudaMemGetInfo");
  LOAD(cuda, device_alloc, "cudaMalloc");
  LOAD(cuda, device_free, "cudaFree");
  LOAD(cuda, copy_bytes, "cudaMemcpy");
  LOAD(cuda, stream_create, "cudaStreamCreate");
  LOAD(cuda, stream_sync, "cudaStreamSynchronize");
  LOAD(cuda, stream_destroy, "cudaStreamDestroy");
  LOAD(cuda, cuda_error, "cudaGetErrorString");
  if (check(get_version(&nccl_version), "ncclGetVersion", 1) ||
      check(runtime_version(&cuda_version), "cudaRuntimeGetVersion", 0)) return -1;
  if (nccl_version != 22809 || cuda_version != 13000) {
    snprintf(failure, sizeof(failure), "pinned versions required: NCCL=22809 CUDA=13000; got %d %d", nccl_version, cuda_version);
    return -1;
  }
  const char *transport = getenv("NCCL_NET");
  if (!transport || (strcmp(transport, "IB") && strcmp(transport, "Socket"))) {
    snprintf(failure, sizeof(failure), "set NCCL_NET=IB or Socket explicitly for this experiment"); return -1;
  }
  return 0;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mr_nccl_probe_error(void) { return result_bytes(failure); }

MOONBIT_FFI_EXPORT moonbit_bytes_t mr_nccl_probe_id(void) {
  unique_id_t id;
  if (check(get_id(&id), "ncclGetUniqueId", 1)) return result_bytes("");
  moonbit_bytes_t bytes = moonbit_make_bytes(128, 0);
  memcpy(bytes, &id, 128);
  return bytes;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mr_nccl_probe_run(int32_t rank, moonbit_bytes_t id_bytes, int32_t elements) {
  fflush(stdout); /* Publish MoonBit's ID-ready line even with redirected logs. */
  if (rank < 0 || rank > 1 || elements < 1 || elements > 2097152 || Moonbit_array_length(id_bytes) != 128) {
    snprintf(failure, sizeof(failure), "invalid rank, payload bound or ID length"); return result_bytes("");
  }
  unique_id_t id;
  memcpy(&id, id_bytes, 128);
  size_t size = (size_t)elements * sizeof(float), free_bytes = 0, total_bytes = 0;
  if (check(set_device(0), "cudaSetDevice", 0) || check(memory_info(&free_bytes, &total_bytes), "cudaMemGetInfo", 0)) return result_bytes("");
  if (free_bytes < (size_t)1024 * 1024 * 1024) {
    snprintf(failure, sizeof(failure), "probe refuses CUDA free memory below 1 GiB"); return result_bytes("");
  }
  float *host = malloc(size);
  void *device = NULL;
  stream_t stream = NULL;
  comm_t comm = NULL;
  double sum_ms = 0.0, min_ms = 1e100, max_ms = 0.0;
  int success = 0;
  if (!host) { snprintf(failure, sizeof(failure), "host buffer allocation failed"); return result_bytes(""); }
  if (check(device_alloc(&device, size), "cudaMalloc", 0) || check(stream_create(&stream), "cudaStreamCreate", 0)) goto cleanup;
  fprintf(stderr, "NCCL_PROBE_PHASE rank=%d communicator_init\n", rank);
  if (check(comm_init(&comm, 2, id, rank), "ncclCommInitRank", 1)) goto cleanup;
  fprintf(stderr, "NCCL_PROBE_PHASE rank=%d numerical_allreduce\n", rank);
  // One warm-up plus three timed reductions. Refill the in-place buffer each
  // time; otherwise repeated sums would conceal rank/input mistakes.
  for (int iteration = 0; iteration < 4; iteration++) {
    for (int32_t i = 0; i < elements; i++) host[i] = (float)(rank + 1) + (float)(i % 101) * 0.25f;
    if (check(copy_bytes(device, host, size, CUDA_HOST_TO_DEVICE), "cudaMemcpy H2D", 0)) goto cleanup;
    const double start = seconds_now();
    if (check(reduce_sum(device, device, (size_t)elements, NCCL_FLOAT32, NCCL_SUM, comm, stream), "ncclAllReduce", 1) ||
        check(stream_sync(stream), "cudaStreamSynchronize", 0)) goto cleanup;
    const double ms = (seconds_now() - start) * 1000.0;
    if (check(copy_bytes(host, device, size, CUDA_DEVICE_TO_HOST), "cudaMemcpy D2H", 0)) goto cleanup;
    for (int32_t i = 0; i < elements; i++) {
      const float expected = 3.0f + (float)(i % 101) * 0.5f;
      if (host[i] != expected) {
        snprintf(failure, sizeof(failure), "incorrect allreduce rank=%d iteration=%d index=%d expected=%.9g actual=%.9g", rank, iteration, i, expected, host[i]);
        goto cleanup;
      }
    }
    if (iteration) { sum_ms += ms; if (ms < min_ms) min_ms = ms; if (ms > max_ms) max_ms = ms; }
  }
  success = 1;
cleanup:
  // On failure terminate promptly via MoonBit; no possibly blocking NCCL
  // cleanup is attempted. The process exit releases its CUDA allocations.
  if (success) {
    if (check(comm_destroy(comm), "ncclCommDestroy", 1) ||
        check(stream_destroy(stream), "cudaStreamDestroy", 0) ||
        check(device_free(device), "cudaFree", 0)) success = 0;
  }
  free(host);
  if (!success) return result_bytes("");
  char report[1024];
  snprintf(report, sizeof(report),
    "{\"format\":\"moonrobo.nccl-probe.v1\",\"rank\":%d,\"world_size\":2,\"nccl_version\":%d,\"cuda_runtime_version\":%d,"
    "\"requested_transport\":\"%s\",\"float_elements\":%d,\"payload_bytes\":%zu,\"combined_explicit_buffer_bytes\":%zu,"
    "\"cuda_free_before_bytes\":%zu,\"cuda_total_bytes\":%zu,\"warmup_reductions\":1,\"timed_reductions\":3,\"all_elements_verified\":true,"
    "\"allreduce_sync_mean_ms\":%.6f,\"allreduce_sync_min_ms\":%.6f,\"allreduce_sync_max_ms\":%.6f,"
    "\"timing_excludes_host_device_copies\":true,\"transport_logs_require_review\":true}",
    rank, nccl_version, cuda_version, getenv("NCCL_NET"), elements, size, size * 2,
    free_bytes, total_bytes, sum_ms / 3, min_ms, max_ms);
  alarm(0);
  return result_bytes(report);
}
