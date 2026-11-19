// SMC projected heading, with the original epsilon and forward arithmetic.
// A single autograd node removes slice/cat/zero bookkeeping. CUDA fuses only
// these row-local scalar operations; it does not approximate sqrt or division.
#include <torch/csrc/autograd/custom_function.h>
#ifdef MR_ENABLE_GEOMETRY_FUSION
torch::Tensor mr_heading_cuda(const torch::Tensor&, const torch::Tensor&, bool);
#endif
class CompactHeading : public torch::autograd::Function<CompactHeading> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx, torch::Tensor r) {
    ctx->save_for_backward({r});
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(r.is_cuda()) return mr_heading_cuda(r,torch::Tensor(),false);
#endif
    if(r.is_cuda()) throw std::invalid_argument("compact heading CUDA extension unavailable");
    auto x=r.select(1,0).narrow(1,0,1), y=r.select(1,1).narrow(1,0,1);
    auto n=torch::sqrt((x.square()+y.square())*1.0+1e-9);
    auto c=x/n, s=y/n, z=c*0.0+0.0;
    return torch::cat({c,s*-1.0+0.0,z,s,c,z,z,z,z*0.0+1.0},1).reshape({-1,3,3});
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,
                                                torch::autograd::variable_list grads) {
    if(torch::GradMode::is_enabled()) throw std::invalid_argument("compact heading supports first-order gradients only");
    auto r=ctx->get_saved_variables()[0], g=grads[0];
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(r.is_cuda()) return {mr_heading_cuda(r,g,true)};
#endif
    auto x=r.select(1,0).narrow(1,0,1), y=r.select(1,1).narrow(1,0,1);
    auto n=torch::sqrt((x.square()+y.square())*1.0+1e-9);
    auto gc=g.select(1,0).narrow(1,0,1)+g.select(1,1).narrow(1,1,1);
    auto gs=g.select(1,1).narrow(1,0,1)+g.select(1,0).narrow(1,1,1)*-1.0;
    auto gn=(-gs*((y/n)/n))+(-gc*((x/n)/n));
    auto ds=gn/(n*2.0)*1.0;
    auto out=torch::zeros(r.sizes(),r.options());
    out.select(1,0).narrow(1,0,1).copy_(ds*2.0*x+gc/n);
    out.select(1,1).narrow(1,0,1).copy_(ds*2.0*y+gs/n);
    return {out};
  }
};
extern "C" void *mr_tensor_compact_heading_v1(void *input,char *err,int cap) {
  return tensor([&]{auto &r=unbox(input);
    if(r.dim()!=3||r.size(0)<1||r.size(0)>262144||r.size(1)!=3||r.size(2)!=3||
       (!r.is_cpu()&&!r.is_cuda())||(r.scalar_type()!=torch::kFloat32&&r.scalar_type()!=torch::kFloat64))
      throw std::invalid_argument("compact heading requires bounded FP32/64 [B,3,3]");
    return CompactHeading::apply(r);},err,cap);
}
