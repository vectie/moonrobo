// Bounded structural specialization of SMC rotations.py. Preserve the existing
// finite-input forward arithmetic; use exact analytic VJPs instead of building
// a graph of scalar zero multiplications, cats and slice-backward scatters.
#include <torch/csrc/autograd/custom_function.h>
class CompactCoordinateRotation : public torch::autograd::Function<CompactCoordinateRotation> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,
                              torch::Tensor angle, int64_t axis, double sign) {
    auto c=angle.cos(), s=angle.sin();
    ctx->save_for_backward({c,s});
    ctx->saved_data["axis"]=axis; ctx->saved_data["sign"]=sign;
    auto k=c * -1.0 + 1.0;
    auto zero=k * 0.0 + 0.0;
    auto diagonal=zero+c;
    auto fixed=(k * 1.0 + 0.0)+c;
    auto ss=s * sign + 0.0;
    auto positive=zero+ss, negative=zero-ss;
    std::vector<torch::Tensor> r(9,zero);
    r[0]=diagonal; r[4]=diagonal; r[8]=diagonal;
    r[axis*3+axis]=fixed;
    const int i=(axis+1)%3, j=(axis+2)%3;
    r[j*3+i]=positive; r[i*3+j]=negative;
    return torch::cat(r,1).reshape({-1,3,3});
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,
                                                torch::autograd::variable_list grads) {
    auto cs=ctx->get_saved_variables(); auto g=grads[0];
    const int axis=ctx->saved_data["axis"].toInt();
    const int i=(axis+1)%3, j=(axis+2)%3;
    auto entry=[&](int a,int b){return g.select(1,a).narrow(1,b,1);};
    auto dc=entry(i,i)+entry(j,j);
    auto ds=(entry(j,i)-entry(i,j))*ctx->saved_data["sign"].toDouble();
    return {dc * -cs[1] + ds * cs[0],torch::Tensor(),torch::Tensor()};
  }
};
class CompactSkew : public torch::autograd::Function<CompactSkew> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *,torch::Tensor v) {
    auto x=v.narrow(1,0,1), y=v.narrow(1,1,1), z=v.narrow(1,2,1);
    auto zero=x*0.0+0.0;
    return torch::cat({zero,z*-1.0+0.0,y,z,zero,x*-1.0+0.0,y*-1.0+0.0,x,zero},1).reshape({-1,3,3});
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *,
                                                torch::autograd::variable_list grads) {
    auto g=grads[0];
    auto e=[&](int a,int b){return g.select(1,a).narrow(1,b,1);};
    return {torch::cat({e(2,1)-e(1,2),e(0,2)-e(2,0),e(1,0)-e(0,1)},1)};
  }
};
static void compact_rotation_input(const torch::Tensor &a,int columns) {
  if(a.dim()!=2||a.size(0)<1||a.size(0)>262144||a.size(1)!=columns||
     (!a.device().is_cpu()&&!a.device().is_cuda())||
     (a.scalar_type()!=torch::kFloat32&&a.scalar_type()!=torch::kFloat64))
    throw std::invalid_argument("compact rotation requires bounded FP32/FP64 CPU/CUDA rows");
}
extern "C" void *mr_tensor_compact_axis_v1(void *input,int axis,double sign,char *err,int cap) {
  return tensor([&]{auto &a=unbox(input);compact_rotation_input(a,1);
    if(axis<0||axis>2||(sign!=1.0&&sign!=-1.0)) throw std::invalid_argument("exact signed coordinate axis required");
    return CompactCoordinateRotation::apply(a,int64_t(axis),sign);},err,cap);
}
extern "C" void *mr_tensor_compact_skew_v1(void *input,char *err,int cap) {
  return tensor([&]{auto &a=unbox(input);compact_rotation_input(a,3);return CompactSkew::apply(a);},err,cap);
}
