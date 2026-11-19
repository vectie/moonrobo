// Optional ABI-2 extension; included by adapter.cpp after tensor/unbox helpers.
// ATen dispatch owns the backward implementation, including affine gradients.
extern "C" void *mr_tensor_layer_norm_v1(void *input, void *weight, void *bias,
                                         double eps, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(input);
    auto &w = unbox(weight);
    auto &b = unbox(bias);
    if (!std::isfinite(eps) || eps <= 0.0)
      throw std::invalid_argument("LayerNorm epsilon must be positive and finite");
    if (x.dim() < 1 || x.size(-1) < 1 || w.dim() != 1 || b.dim() != 1 ||
        w.size(0) != x.size(-1) || b.size(0) != x.size(-1))
      throw std::invalid_argument("LayerNorm requires matching final dimension and affine vectors");
    if ((!x.device().is_cpu() && !x.device().is_cuda()) ||
        x.device() != w.device() || x.device() != b.device())
      throw std::invalid_argument("LayerNorm requires one CPU or CUDA device");
    if ((x.scalar_type() != torch::kFloat32 && x.scalar_type() != torch::kFloat64 &&
         x.scalar_type() != torch::kBFloat16) ||
        x.scalar_type() != w.scalar_type() || x.scalar_type() != b.scalar_type())
      throw std::invalid_argument("LayerNorm requires matching supported floating dtypes");
    // Match nn.LayerNorm -> functional.layer_norm -> torch.layer_norm, including
    // the process-wide backend policy. Do not reimplement the variance or VJP:
    // ATen owns the fused forward and both input/affine backward paths.
    return torch::layer_norm(x, {x.size(-1)}, w, b, eps,
                             at::globalContext().userEnabledCuDNN());
  }, err, cap);
}

// One FFI submission, the SAME ATen operations and autograd graph as the
// expanded MoonBit baseline. This is deliberately not torch::layer_norm: the
// latter failed the near-constant FP32 gate. Keep the multiply-by-one used by
// Tensor::affine, both reductions, and divide/sqrt order unchanged.
extern "C" void *mr_tensor_layer_norm_submitted_v1(void *input, void *weight,
    void *bias, double eps, char *err, int cap) {
  return tensor([&] {
    auto &x=unbox(input); auto &w=unbox(weight); auto &b=unbox(bias);
    if (!std::isfinite(eps)||eps<=0.0||x.dim()<1||x.size(-1)<1||
        w.dim()!=1||b.dim()!=1||w.size(0)!=x.size(-1)||b.size(0)!=x.size(-1))
      throw std::invalid_argument("submitted LayerNorm shape/epsilon mismatch");
    if ((!x.device().is_cpu()&&!x.device().is_cuda())||x.device()!=w.device()||x.device()!=b.device()||
        (x.scalar_type()!=torch::kFloat32&&x.scalar_type()!=torch::kFloat64&&x.scalar_type()!=torch::kBFloat16)||
        x.scalar_type()!=w.scalar_type()||x.scalar_type()!=b.scalar_type())
      throw std::invalid_argument("submitted LayerNorm device/dtype mismatch");
    auto centered=x-x.mean(-1,true);
    return centered/torch::sqrt(centered.square().mean(-1,true)*1.0+eps)*w+b;
  },err,cap);
}

extern "C" void *mr_tensor_cross_submitted_v1(void *left, void *right, char *err, int cap) {
  return tensor([&] {
    auto &a=unbox(left);auto &b=unbox(right);
    if(a.dim()!=2||b.dim()!=2||a.size(1)!=3||b.size(1)!=3||a.size(0)!=b.size(0)||
       a.device()!=b.device()||a.scalar_type()!=b.scalar_type())
      throw std::invalid_argument("submitted cross requires matching [B,3] tensors");
    // Match MoonBit's left-to-right node creation as well as its formula.
    // C++ does not specify both operand evaluation orders for overloaded '-'.
    // Separate statements preserve the backward graph's sequence numbers.
    auto component = [&](int ai, int bi, int aj, int bj) {
      auto left_a = a.narrow(1, ai, 1);
      auto left_b = b.narrow(1, bi, 1);
      auto left_product = left_a * left_b;
      auto right_a = a.narrow(1, aj, 1);
      auto right_b = b.narrow(1, bj, 1);
      auto right_product = right_a * right_b;
      return left_product - right_product;
    };
    auto x = component(1, 2, 2, 1);
    auto y = component(2, 0, 0, 2);
    auto z = component(0, 1, 1, 0);
    return torch::cat({x, y, z}, 1);
  },err,cap);
}
