// Independent opt-in kernels. Keep ATen trigonometry, bmm, reductions and cross
// VJPs: only row-local pointwise work is fused, without contraction/reassociation.
#ifdef MR_ENABLE_GEOMETRY_FUSION
torch::Tensor mr_so3_tail_cuda(const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, const torch::Tensor&);
std::vector<torch::Tensor> mr_so3_tail_backward_cuda(const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, const torch::Tensor&);
torch::Tensor mr_cross_forward_cuda(const torch::Tensor&, const torch::Tensor&);
#endif
class FusedSo3Tail : public torch::autograd::Function<FusedSo3Tail> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,
      torch::Tensor k, torch::Tensor kk, torch::Tensor a, torch::Tensor b) {
    ctx->save_for_backward({k,kk,a,b});
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(k.is_cuda()) return mr_so3_tail_cuda(k,kk,a,b);
#endif
    if(k.is_cuda()) throw std::invalid_argument("SO3 tail CUDA extension unavailable");
    return (torch::eye(3,k.options()).unsqueeze(0)+k*a.reshape({-1,1,1}))+
      kk*b.reshape({-1,1,1});
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,
      torch::autograd::variable_list grads) {
    if(torch::GradMode::is_enabled()) throw std::invalid_argument("SO3 tail supports first-order gradients only");
    auto s=ctx->get_saved_variables(); auto g=grads[0];
    std::vector<torch::Tensor> p;
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(g.is_cuda()) p=mr_so3_tail_backward_cuda(s[0],s[1],s[2],s[3],g);
#endif
    if(p.empty()) p={g*s[2].reshape({-1,1,1}),g*s[3].reshape({-1,1,1}),g*s[0],g*s[1]};
    // Same sum_to_size dimensions as the original broadcasted ATen multiply.
    return {p[0],p[1],p[2].sum({1,2},true).reshape({-1,1}),
      p[3].sum({1,2},true).reshape({-1,1})};
  }
};
class FusedCrossForward : public torch::autograd::Function<FusedCrossForward> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor a,torch::Tensor b) {
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(a.is_cuda()) {ctx->save_for_backward({a,b});return mr_cross_forward_cuda(a,b);}
#endif
    if(a.is_cuda()) throw std::invalid_argument("fused cross CUDA extension unavailable");
    return CrossPreserveForward::forward(ctx,a,b);
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list grads) {
    return CrossPreserveForward::backward(ctx,grads);
  }
};
static void geometry_tail_match(const torch::Tensor& a,const torch::Tensor& b) {
  if(a.device()!=b.device()||a.scalar_type()!=b.scalar_type()||a.size(0)!=b.size(0))
    throw std::invalid_argument("geometry tail shape/device/dtype mismatch");
}
extern "C" void *mr_tensor_so3_tail_v1(void *kp,void *kkp,void *ap,void *bp,char *err,int cap) {
  return tensor([&]{auto &k=unbox(kp),&kk=unbox(kkp),&a=unbox(ap),&b=unbox(bp);
    compact_rotation_input(a,1);compact_rotation_input(b,1);
    geometry_tail_match(a,b);geometry_tail_match(a,k);geometry_tail_match(a,kk);
    if(k.dim()!=3||k.size(1)!=3||k.size(2)!=3||kk.sizes()!=k.sizes())
      throw std::invalid_argument("SO3 tail requires [B,3,3] K/K2 and [B,1] a/b");
    return FusedSo3Tail::apply(k,kk,a,b);},err,cap);
}
extern "C" void *mr_tensor_fused_cross_forward_v1(void *ap,void *bp,char *err,int cap) {
  return tensor([&]{auto &a=unbox(ap),&b=unbox(bp);compact_rotation_input(a,3);compact_rotation_input(b,3);
    geometry_tail_match(a,b);return FusedCrossForward::apply(a,b);},err,cap);
}
