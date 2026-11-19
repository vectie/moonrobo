// Optional ABI-2 precision extension. Never called by ordinary training unless
// explicitly requested. Build against the exact supported LibTorch version.
#include <ATen/Context.h>
#include <cstdlib>

namespace {
int tf32_env_code(const char *key) {
  const char *value = std::getenv(key);
  if (!value) return -1;
  if (value[0] == '0' && value[1] == '\0') return 0;
  if (value[0] == '1' && value[1] == '\0') return 1;
  return 2;
}
// Captured at plugin load; callers must launch with fixed environment and must
// not use an earlier initialized external LibTorch/CUDA runtime concurrently.
const int tf32_nvidia_at_load = tf32_env_code("NVIDIA_TF32_OVERRIDE");
const int tf32_torch_at_load = tf32_env_code("TORCH_ALLOW_TF32_CUBLAS_OVERRIDE");

void tf32_require_supported() {
  if (mr_tensor_device_count() <= 0 || !at::globalContext().hasCUDART() || at::globalContext().hasROCM())
    throw std::runtime_error("CUDA FP32 precision unsupported: CPU/non-CUDA build or no accessible CUDA device");
#if TORCH_VERSION_MAJOR != 2 || TORCH_VERSION_MINOR != 11
  throw std::runtime_error("CUDA FP32 precision unsupported: requires exact LibTorch 2.11 per-op API");
#endif
  if (tf32_nvidia_at_load == 2 || tf32_torch_at_load == 2)
    throw std::runtime_error("CUDA FP32 precision cannot confirm unknown override value; use unset, 0 or 1");
  if (tf32_env_code("NVIDIA_TF32_OVERRIDE") != tf32_nvidia_at_load ||
      tf32_env_code("TORCH_ALLOW_TF32_CUBLAS_OVERRIDE") != tf32_torch_at_load)
    throw std::runtime_error("CUDA FP32 precision override changed after plugin load; restart with fixed environment");
}

#if TORCH_VERSION_MAJOR == 2 && TORCH_VERSION_MINOR == 11
int tf32_precision_code(at::Float32Precision precision) {
  switch (precision) {
    case at::Float32Precision::NONE: return 0;
    case at::Float32Precision::IEEE: return 1;
    case at::Float32Precision::TF32: return 2;
    default: throw std::runtime_error("unsupported CUDA FP32 precision readback");
  }
}
void tf32_snapshot(int32_t *out) {
  auto &context = at::globalContext();
  const int32_t values[7] = {
    tf32_precision_code(context.float32Precision(at::Float32Backend::CUDA, at::Float32Op::MATMUL)),
    tf32_precision_code(context.float32Precision(at::Float32Backend::CUDA, at::Float32Op::CONV)),
    tf32_precision_code(context.float32Precision(at::Float32Backend::CUDA, at::Float32Op::RNN)),
    tf32_nvidia_at_load, tf32_torch_at_load, context.hasCuDNN() ? 1 : 0,
    fp32_tensor_creation_started ? 1 : 0,
  };
  std::memcpy(out, values, sizeof(values));
}
#endif
}

extern "C" int mr_tensor_cuda_fp32_settings_v1(int32_t *out, int count, char *err, int cap) {
  return status([&] {
    if (!out || count != 7) throw std::invalid_argument("invalid FP32 precision output buffer");
    std::lock_guard<std::mutex> guard(fp32_settings_mutex);
    tf32_require_supported();
#if TORCH_VERSION_MAJOR == 2 && TORCH_VERSION_MINOR == 11
    tf32_snapshot(out);
#endif
  }, err, cap);
}

extern "C" int mr_tensor_configure_cuda_tf32_v1(int matmul, int conv, int rnn,
                                                int before_first_tensor,
                                                int32_t *out, int count, char *err, int cap) {
  return status([&] {
    if (!out || count != 7 || (matmul != 0 && matmul != 1) ||
        (conv != 0 && conv != 1) || (rnn != 0 && rnn != 1) || before_first_tensor != 1)
      throw std::invalid_argument("CUDA precision setting requires explicit before_first_tensor=true and Boolean options");
    std::lock_guard<std::mutex> guard(fp32_settings_mutex);
    tf32_require_supported();
    if (fp32_tensor_creation_started)
      throw std::runtime_error("CUDA precision startup window closed: this plugin has begun creating tensors");
    if (tf32_nvidia_at_load == 1)
      throw std::runtime_error("NVIDIA_TF32_OVERRIDE=1 has no confirmed enable semantics here; unset it before launch");
    if (tf32_nvidia_at_load == 0 && (matmul || conv || rnn))
      throw std::runtime_error("NVIDIA_TF32_OVERRIDE=0 blocks requested TF32; no precision setting changed");
    if (tf32_torch_at_load == 1 && !matmul)
      throw std::runtime_error("TORCH_ALLOW_TF32_CUBLAS_OVERRIDE=1 conflicts with IEEE matmul; no precision setting changed");
    if (!at::globalContext().hasCuDNN())
      throw std::runtime_error("cuDNN precision settings cannot be confirmed: cuDNN is unavailable");
#if TORCH_VERSION_MAJOR == 2 && TORCH_VERSION_MINOR == 11
    auto &context = at::globalContext();
    // Do not call the deprecated allowTF32 or global matmul precision APIs:
    // mixing them with per-op settings is explicitly unsupported by PyTorch.
    try {
      context.setFloat32Precision(at::Float32Backend::CUDA, at::Float32Op::MATMUL,
        matmul ? at::Float32Precision::TF32 : at::Float32Precision::IEEE);
      context.setFloat32Precision(at::Float32Backend::CUDA, at::Float32Op::CONV,
        conv ? at::Float32Precision::TF32 : at::Float32Precision::IEEE);
      context.setFloat32Precision(at::Float32Backend::CUDA, at::Float32Op::RNN,
        rnn ? at::Float32Precision::TF32 : at::Float32Precision::IEEE);
      int32_t actual[7];
      tf32_snapshot(actual);
      if (actual[0] != (matmul ? 2 : 1) || actual[1] != (conv ? 2 : 1) || actual[2] != (rnn ? 2 : 1))
        throw std::runtime_error("per-operation readback mismatch");
      std::memcpy(out, actual, sizeof(actual));
    } catch (const std::exception &error) {
      // Even an unexpected partial setter failure must not reopen configuration.
      fp32_tensor_creation_started = true;
      throw std::runtime_error(std::string("CUDA precision mutation/readback failed; exit this process before any tensor work: ") + error.what());
    } catch (...) {
      fp32_tensor_creation_started = true;
      throw std::runtime_error("CUDA precision mutation/readback failed; exit this process before any tensor work");
    }
#endif
  }, err, cap);
}
