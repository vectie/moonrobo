#ifdef MR_ENABLE_POINTWISE_FUSION
#include <torch/csrc/autograd/custom_function.h>
at::Tensor mr_ln_silu_tail_cuda_forward(const at::Tensor&, const at::Tensor&,
    const at::Tensor&, const at::Tensor&, double);
std::vector<at::Tensor> mr_ln_silu_tail_cuda_backward(const at::Tensor&,
    const at::Tensor&, const at::Tensor&, const at::Tensor&, const at::Tensor&, double, bool, bool);

namespace {
class LnSiluTail : public torch::autograd::Function<LnSiluTail> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext* ctx,
      torch::Tensor c, torch::Tensor v, torch::Tensor w, torch::Tensor b, double eps) {
    ctx->save_for_backward({c, v, w, b});
    ctx->saved_data["eps"] = eps;
    return mr_ln_silu_tail_cuda_forward(c, v, w, b, eps);
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grads) {
    if (torch::GradMode::is_enabled())
      throw std::invalid_argument("fused LN tail supports first-order training gradients only");
    const auto saved = ctx->get_saved_variables();
    const auto& c = saved[0]; const auto& v = saved[1];
    const auto& w = saved[2]; const auto& b = saved[3];
    const double eps = ctx->saved_data["eps"].toDouble();
    auto parts = mr_ln_silu_tail_cuda_backward(c, v, w, b, grads[0].contiguous(), eps, w.requires_grad(), b.requires_grad());
    // Keep ATen reduction order and sqrt backward outside the fused elementwise
    // kernel, including the original multiply-by-one affine derivative.
    auto denominator = torch::sqrt(v * 1.0 + eps);
    auto dv = parts[1].sum(-1, true) / (denominator * 2.0) * 1.0;
    std::vector<int64_t> leading;
    for (int64_t i = 0; i + 1 < c.dim(); ++i) leading.push_back(i);
    auto dw = !parts[2].defined() || leading.empty() ? parts[2] : parts[2].sum(leading);
    auto db = !parts[3].defined() || leading.empty() ? parts[3] : parts[3].sum(leading);
    return {parts[0], dv, dw, db, torch::Tensor()};
  }
};
}

extern "C" void* mr_tensor_ln_silu_tail_v1(void* centered, void* variance,
    void* weight, void* bias, double eps, char* err, int cap) {
  return tensor([&] {
    auto& c = unbox(centered); auto& v = unbox(variance);
    auto& w = unbox(weight); auto& b = unbox(bias);
    if (!std::isfinite(eps) || eps <= 0 || c.dim() < 2 || c.numel() <= 0 ||
        c.size(-1) <= 0 || c.size(-1) > 4096 || c.numel() > 16777216 ||
        v.dim() != c.dim() || v.size(-1) != 1 || w.dim() != 1 || b.dim() != 1 ||
        w.numel() != c.size(-1) || b.numel() != c.size(-1))
      throw std::invalid_argument("fused LN tail shape or workspace bound");
    for (int64_t i = 0; i + 1 < c.dim(); ++i)
      if (c.size(i) != v.size(i)) throw std::invalid_argument("fused LN tail variance shape");
    for (auto* t : {&v, &w, &b})
      if (t->device() != c.device() || t->scalar_type() != c.scalar_type() || !t->is_contiguous())
        throw std::invalid_argument("fused LN tail dtype/device/layout mismatch");
    if (!c.is_cuda() || !c.is_contiguous() ||
        (c.scalar_type() != torch::kFloat32 && c.scalar_type() != torch::kFloat64))
      throw std::invalid_argument("fused LN tail requires contiguous CUDA FP32/FP64");
    return torch::silu(LnSiluTail::apply(c, v, w, b, eps));
  }, err, cap);
}
#endif
