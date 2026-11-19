// Independently gated first-order VJPs. The coefficient forward deliberately
// retains the original ATen operations (including trig and branch thresholds).
#ifdef MR_ENABLE_GEOMETRY_FUSION
std::vector<torch::Tensor> mr_cross_vjp_cuda(const torch::Tensor&,const torch::Tensor&,const torch::Tensor&);
torch::Tensor mr_so3_coeff_vjp_cuda(const torch::Tensor&,const torch::Tensor&,const torch::Tensor&,const torch::Tensor&,const torch::Tensor&);
torch::Tensor mr_so3_coeff_forward_cuda(const torch::Tensor&,const torch::Tensor&,const torch::Tensor&,const torch::Tensor&);
std::vector<torch::Tensor> mr_so3_coeff_full_forward_cuda(const torch::Tensor&);
#endif
class FusedCrossVjp : public torch::autograd::Function<FusedCrossVjp> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor a,torch::Tensor b) {
    return FusedCrossForward::forward(ctx,a,b);
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list gs) {
    if(torch::GradMode::is_enabled()) throw std::invalid_argument("fused cross VJP supports first-order gradients only");
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(gs[0].is_cuda()) {auto s=ctx->get_saved_variables();return mr_cross_vjp_cuda(s[0],s[1],gs[0]);}
#endif
    return CrossPreserveForward::backward(ctx,gs);
  }
};
class FusedSo3Coefficients : public torch::autograd::Function<FusedSo3Coefficients> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor t2) {
    auto d=t2+1e-12,t=d.sqrt(),s=t.sin(),c=t.cos();
    auto small=t2<(t2*0.0+1e-8);
    auto a=torch::where(small,t2*(-1.0/6.0)+1.0,s/t);
    auto b=torch::where(small,t2*(-1.0/24.0)+0.5,(c*(-1.0)+1.0)/d);
    ctx->save_for_backward({t2,t,s,c});
    return torch::cat({a,b},1);
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list gs) {
    if(torch::GradMode::is_enabled()) throw std::invalid_argument("SO3 coefficients support first-order gradients only");
    auto v=ctx->get_saved_variables();auto t2=v[0],t=v[1],s=v[2],c=v[3],g=gs[0];
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(g.is_cuda()) return {mr_so3_coeff_vjp_cuda(t2,t,s,c,g)};
#endif
    if(g.is_cuda()) throw std::invalid_argument("SO3 coefficient CUDA extension unavailable");
    auto small=t2<(t2*0.0+1e-8),z=torch::zeros_like(t2);
    auto ga=g.narrow(1,0,1),gb=g.narrow(1,1,1);
    auto al=torch::where(small,z,ga),bl=torch::where(small,z,gb);
    auto d=t2+1e-12;
    auto td=((bl/d)*(-1.0))*(-s);
    td=td+(-al)*((s/t)/t);
    td=td+(al/t)*c;
    auto direct=(-bl)*(((c*(-1.0)+1.0)/d)/d);
    direct=direct+torch::where(small,gb,z)*(-1.0/24.0);
    direct=direct+torch::where(small,ga,z)*(-1.0/6.0);
    return {direct+td/(t*2.0)};
  }
};
// Preserve the accepted VJP and ATen transcendental functions. Only the
// coefficient assembly is fused; the original entrypoint remains unchanged.
class So3CoefficientForwardNode : public torch::autograd::Function<So3CoefficientForwardNode> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor t2) {
    if(t2.is_cpu()) return FusedSo3Coefficients::forward(ctx,t2);
#ifdef MR_ENABLE_GEOMETRY_FUSION
    auto t=(t2+1e-12).sqrt(),s=t.sin(),c=t.cos();
    ctx->save_for_backward({t2,t,s,c});
    return mr_so3_coeff_forward_cuda(t2,t,s,c);
#else
    throw std::invalid_argument("SO3 coefficient forward CUDA extension unavailable");
#endif
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list gs) {
    return FusedSo3Coefficients::backward(ctx,gs);
  }
};
extern "C" void *mr_tensor_fused_cross_vjp_v1(void *ap,void *bp,char *err,int cap) {
  return tensor([&]{auto &a=unbox(ap),&b=unbox(bp);compact_rotation_input(a,3);compact_rotation_input(b,3);
    geometry_tail_match(a,b);return FusedCrossVjp::apply(a,b);},err,cap);
}
extern "C" void *mr_tensor_so3_coefficients_v1(void *p,char *err,int cap) {
  return tensor([&]{auto &x=unbox(p);compact_rotation_input(x,1);return FusedSo3Coefficients::apply(x);},err,cap);
}
extern "C" void *mr_tensor_so3_coefficient_forward_v1(void *p,char *err,int cap) {
  return tensor([&]{auto &x=unbox(p);compact_rotation_input(x,1);return So3CoefficientForwardNode::apply(x);},err,cap);
}

class So3CoefficientFullForwardNode : public torch::autograd::Function<So3CoefficientFullForwardNode> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor t2) {
    if(t2.is_cpu()) return FusedSo3Coefficients::forward(ctx,t2);
#ifdef MR_ENABLE_GEOMETRY_FUSION
    auto outputs=mr_so3_coeff_full_forward_cuda(t2);
    ctx->save_for_backward({t2,outputs[0],outputs[1],outputs[2]});return outputs[3];
#else
    throw std::invalid_argument("SO3 coefficient full forward CUDA extension unavailable");
#endif
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list gs) {
    return FusedSo3Coefficients::backward(ctx,gs);
  }
};
extern "C" void *mr_tensor_so3_coefficient_full_forward_v1(void *p,char *err,int cap) {
  return tensor([&]{auto &x=unbox(p);compact_rotation_input(x,1);return So3CoefficientFullForwardNode::apply(x);},err,cap);
}
