#include <torch/csrc/autograd/custom_function.h>
// SMC kinematics.py uses torch.cross(..., dim=-1). Delegate its forward and
// VJP to ATen rather than generating slice/mul/sub/cat autograd nodes.
extern "C" void *mr_tensor_native_cross_v1(void *left, void *right, char *err, int cap) {
  return tensor([&] {
    auto &a=unbox(left), &b=unbox(right);
    if (a.dim()!=2 || a.size(0)<1 || a.size(0)>262144 || a.size(1)!=3 ||
        a.sizes()!=b.sizes() || a.device()!=b.device() || a.scalar_type()!=b.scalar_type() ||
        (!a.device().is_cpu()&&!a.device().is_cuda()) ||
        (a.scalar_type()!=torch::kFloat32&&a.scalar_type()!=torch::kFloat64))
      throw std::invalid_argument("native cross requires matching FP32/FP64 [1..262144,3] tensors");
    return torch::cross(a,b,-1);
  },err,cap);
}

// Preserve the reference's separate multiply/subtract forward rounding, while
// using the exact cross-product VJP instead of twelve slice backward nodes.
// This is a separately gated candidate, not a straight-through estimator.
class CrossPreserveForward : public torch::autograd::Function<CrossPreserveForward> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,
                              torch::Tensor a, torch::Tensor b) {
    ctx->save_for_backward({a,b});
    auto col=[](const torch::Tensor& x,int i){return x.narrow(1,i,1);};
    return torch::cat({
      col(a,1)*col(b,2)-col(a,2)*col(b,1),
      col(a,2)*col(b,0)-col(a,0)*col(b,2),
      col(a,0)*col(b,1)-col(a,1)*col(b,0)},1);
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,
                                                torch::autograd::variable_list grads) {
    auto saved=ctx->get_saved_variables();
    return {torch::cross(saved[1],grads[0],-1),torch::cross(grads[0],saved[0],-1)};
  }
};
extern "C" void *mr_tensor_cross_preserve_forward_v1(void *left, void *right, char *err, int cap) {
  return tensor([&] {
    auto &a=unbox(left), &b=unbox(right);
    if (a.dim()!=2 || a.size(0)<1 || a.size(0)>262144 || a.size(1)!=3 ||
        a.sizes()!=b.sizes() || a.device()!=b.device() || a.scalar_type()!=b.scalar_type() ||
        (!a.device().is_cpu()&&!a.device().is_cuda()) ||
        (a.scalar_type()!=torch::kFloat32&&a.scalar_type()!=torch::kFloat64))
      throw std::invalid_argument("cross VJP requires matching FP32/FP64 [1..262144,3] tensors");
    return CrossPreserveForward::apply(a,b);
  },err,cap);
}
