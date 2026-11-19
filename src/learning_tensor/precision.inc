// Optional ABI-2 precision operations; FP32 master tensors and Adam state stay
// untouched. Autocast dispatch is scoped to one Linear, never geometry/rewards.
#include <ATen/autocast_mode.h>
// Match nn.Linear/F.linear in FP32/FP64, including fused bias and dispatch.
// matmul(x, w.T) + b can select a different GEMM at actor microbatch widths.
extern "C" void *mr_tensor_linear_v1(void *input, void *weight, void *bias,
                                      char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(input); auto &w = unbox(weight); auto &b = unbox(bias);
    if (x.dim() < 1 || w.dim() != 2 || b.dim() != 1 || x.size(-1) != w.size(1) ||
        b.size(0) != w.size(0) || w.size(0) < 1 || w.size(1) < 1)
      throw std::invalid_argument("Linear requires input[...,in], weight[out,in], bias[out]");
    if ((!x.device().is_cpu() && !x.device().is_cuda()) ||
        x.device() != w.device() || x.device() != b.device() ||
        (x.scalar_type() != torch::kFloat32 && x.scalar_type() != torch::kFloat64) ||
        x.scalar_type() != w.scalar_type() || x.scalar_type() != b.scalar_type())
      throw std::invalid_argument("Linear requires matching FP32/FP64 tensors on one CPU/CUDA device");
    return torch::linear(x, w, b);
  }, err, cap);
}
namespace {
struct ScopedBf16Linear {
  at::DeviceType device;
  bool enabled, cache;
  at::ScalarType dtype;
  explicit ScopedBf16Linear(at::DeviceType d)
      : device(d), enabled(at::autocast::is_autocast_enabled(d)),
        cache(at::autocast::is_autocast_cache_enabled()),
        dtype(at::autocast::get_autocast_dtype(d)) {
    // Each layer is visited once per MLP call. Avoid cached FP32-weight casts
    // surviving Adam updates or being captured as stale CUDA graph constants.
    at::autocast::set_autocast_cache_enabled(false);
    at::autocast::set_autocast_dtype(device, at::kBFloat16);
    at::autocast::set_autocast_enabled(device, true);
  }
  ~ScopedBf16Linear() {
    at::autocast::set_autocast_enabled(device, enabled);
    at::autocast::set_autocast_dtype(device, dtype);
    at::autocast::set_autocast_cache_enabled(cache);
  }
};
}
extern "C" void *mr_tensor_cast_float_v1(void *input, int target_dtype, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(input);
    if ((target_dtype < 0 || target_dtype > 2) || !x.is_floating_point() ||
        (!x.device().is_cpu() && !x.device().is_cuda()))
      throw std::invalid_argument("floating cast requires floating CPU/CUDA tensor and Float64/Float32/BFloat16 target");
    // Differentiable to(dtype), never detach: BPTT reaches FP32 inputs/weights.
    return x.to(dtype(target_dtype));
  }, err, cap);
}
extern "C" void *mr_tensor_linear_bf16_v1(void *input, void *weight, void *bias,
                                          char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(input); auto &w = unbox(weight); auto &b = unbox(bias);
    if (x.dim() < 1 || w.dim() != 2 || b.dim() != 1 || x.size(-1) != w.size(1) ||
        b.size(0) != w.size(0) || w.size(0) < 1 || w.size(1) < 1)
      throw std::invalid_argument("BF16 Linear requires input[...,in], weight[out,in], bias[out]");
    if ((!x.device().is_cpu() && !x.device().is_cuda()) ||
        x.device() != w.device() || x.device() != b.device())
      throw std::invalid_argument("BF16 Linear requires one CPU/CUDA device");
    if ((x.scalar_type() != torch::kFloat32 && x.scalar_type() != torch::kBFloat16) ||
        w.scalar_type() != torch::kFloat32 || b.scalar_type() != torch::kFloat32)
      throw std::invalid_argument("BF16 Linear requires FP32 master weight/bias and FP32/BF16 input");
    ScopedBf16Linear autocast(x.device().type());
    // Linear includes bias before the BF16 output rounding, like nn.Linear.
    auto result = torch::linear(x, w, b);
    if (result.scalar_type() != torch::kBFloat16)
      throw std::runtime_error("BF16 Linear dispatch did not return BF16; refusing silent FP32 fallback");
    return result;
  }, err, cap);
}
