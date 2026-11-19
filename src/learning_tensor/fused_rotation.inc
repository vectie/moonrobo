// Separate entrypoints retain the original compact ATen implementation.
#ifdef MR_ENABLE_GEOMETRY_FUSION
torch::Tensor mr_axis_cuda(const torch::Tensor&,const torch::Tensor&,const torch::Tensor&,int,double,bool);
torch::Tensor mr_skew_cuda(const torch::Tensor&,bool);
#endif
class FusedCoordinateRotation : public torch::autograd::Function<FusedCoordinateRotation> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor angle,int64_t axis,double sign) {
    if(angle.is_cpu()) return CompactCoordinateRotation::forward(ctx,angle,axis,sign);
#ifdef MR_ENABLE_GEOMETRY_FUSION
    auto c=angle.cos(),s=angle.sin();ctx->save_for_backward({c,s});
    ctx->saved_data["axis"]=axis;ctx->saved_data["sign"]=sign;
    return mr_axis_cuda(c,s,torch::Tensor(),axis,sign,false);
#else
    throw std::invalid_argument("fused rotation CUDA extension unavailable");
#endif
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list grads) {
    if(torch::GradMode::is_enabled())throw std::invalid_argument("fused rotation supports first-order gradients only");
#ifdef MR_ENABLE_GEOMETRY_FUSION
    auto cs=ctx->get_saved_variables();if(cs[0].is_cuda())return {mr_axis_cuda(cs[0],cs[1],grads[0],ctx->saved_data["axis"].toInt(),ctx->saved_data["sign"].toDouble(),true),torch::Tensor(),torch::Tensor()};
#endif
    return CompactCoordinateRotation::backward(ctx,grads);
  }
};
class FusedSkew : public torch::autograd::Function<FusedSkew> {
 public:
  static torch::Tensor forward(torch::autograd::AutogradContext *ctx,torch::Tensor v) {
    if(v.is_cpu())return CompactSkew::forward(ctx,v);
#ifdef MR_ENABLE_GEOMETRY_FUSION
    return mr_skew_cuda(v,false);
#else
    throw std::invalid_argument("fused rotation CUDA extension unavailable");
#endif
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext *ctx,torch::autograd::variable_list grads) {
    if(torch::GradMode::is_enabled())throw std::invalid_argument("fused skew supports first-order gradients only");
#ifdef MR_ENABLE_GEOMETRY_FUSION
    if(grads[0].is_cuda())return {mr_skew_cuda(grads[0],true)};
#endif
    return CompactSkew::backward(ctx,grads);
  }
};
extern "C" void *mr_tensor_fused_axis_v1(void *input,int axis,double sign,char *err,int cap) {
  return tensor([&]{auto &a=unbox(input);compact_rotation_input(a,1);
    if(axis<0||axis>2||(sign!=1.0&&sign!=-1.0))throw std::invalid_argument("exact signed coordinate axis required");
    return FusedCoordinateRotation::apply(a,int64_t(axis),sign);},err,cap);
}
extern "C" void *mr_tensor_fused_skew_v1(void *input,char *err,int cap) {
  return tensor([&]{auto &a=unbox(input);compact_rotation_input(a,3);return FusedSkew::apply(a);},err,cap);
}
