// Optional ABI-2 operations transcribed from SMC's original ATen expressions.
// No custom backward, detached learning inputs, or changed precision policy.
// MIT: Copyright (c) 2026 ETH Zurich, Chong Zhang. See SMC_LICENSE.
namespace {
void smc_float(const torch::Tensor &x) {
  if ((!x.device().is_cpu() && !x.device().is_cuda()) ||
      (x.scalar_type()!=torch::kFloat32 && x.scalar_type()!=torch::kFloat64))
    throw std::invalid_argument("SMC algebra requires CPU/CUDA FP32 or FP64");
}
torch::Tensor smc_normalize(const torch::Tensor &x) {
  return x / at::linalg_vector_norm(x, 2, {-1}, true).clamp_min(1e-12);
}
}
extern "C" void *mr_tensor_smc_exp_v1(void *input, char *err, int cap) {
  return tensor([&] {
    auto &v=unbox(input); smc_float(v);
    if(v.dim()!=2||v.size(0)<1||v.size(0)>131072||v.size(1)!=3)
      throw std::invalid_argument("SMC exponential requires [1..131072,3]");
    auto theta2=(v*v).sum(-1,true);
    auto theta=torch::sqrt(theta2+1e-12);
    auto small=theta2<1e-8;
    auto a=torch::where(small,1-theta2/6,torch::sin(theta)/theta);
    auto b=torch::where(small,0.5-theta2/24,(1-torch::cos(theta))/(theta2+1e-12));
    auto parts=v.unbind(-1);
    auto x=parts[0],y=parts[1],z=parts[2],o=torch::zeros_like(x);
    auto k=torch::stack({o,-z,y,z,o,-x,-y,x,o},-1).reshape({v.size(0),3,3});
    auto eye=torch::eye(3,v.options().requires_grad(false)).expand_as(k);
    return eye+a.unsqueeze(-1)*k+b.unsqueeze(-1)*torch::matmul(k,k);
  },err,cap);
}
extern "C" void *mr_tensor_smc_heading_v1(void *input, char *err, int cap) {
  return tensor([&] {
    auto &r=unbox(input); smc_float(r);
    if(r.dim()!=3||r.size(0)<1||r.size(0)>131072||r.size(1)!=3||r.size(2)!=3)
      throw std::invalid_argument("SMC heading requires [1..131072,3,3]");
    auto fx=r.select(-2,0).select(-1,0),fy=r.select(-2,1).select(-1,0);
    auto n=torch::sqrt(fx*fx+fy*fy+1e-9);
    auto c=fx/n,s=fy/n,o=torch::zeros_like(c),one=torch::ones_like(c);
    return torch::stack({c,-s,o,s,c,o,o,o,one},-1).reshape({r.size(0),3,3});
  },err,cap);
}
extern "C" void *mr_tensor_smc_rotvec_v1(void *input, char *err, int cap) {
  return tensor([&] {
    auto &m=unbox(input); smc_float(m);
    if (m.dim()!=3 || m.size(0)<1 || m.size(0)>131072 || m.size(1)!=3 || m.size(2)!=3)
      throw std::invalid_argument("SMC rotation vector requires [1..131072,3,3]");
    auto at=[&](int i,int j){return m.select(1,i).select(1,j);};
    auto m00=at(0,0),m01=at(0,1),m02=at(0,2),m10=at(1,0),m11=at(1,1),m12=at(1,2),m20=at(2,0),m21=at(2,1),m22=at(2,2);
    auto qw=torch::sqrt((1+m00+m11+m22).clamp_min(1e-10))/2;
    auto qx=torch::sqrt((1+m00-m11-m22).clamp_min(1e-10))/2;
    auto qy=torch::sqrt((1-m00+m11-m22).clamp_min(1e-10))/2;
    auto qz=torch::sqrt((1-m00-m11+m22).clamp_min(1e-10))/2;
    auto candidates=torch::stack({
      torch::stack({qw,(m21-m12)/(4*qw),(m02-m20)/(4*qw),(m10-m01)/(4*qw)},-1),
      torch::stack({(m21-m12)/(4*qx),qx,(m01+m10)/(4*qx),(m02+m20)/(4*qx)},-1),
      torch::stack({(m02-m20)/(4*qy),(m01+m10)/(4*qy),qy,(m12+m21)/(4*qy)},-1),
      torch::stack({(m10-m01)/(4*qz),(m02+m20)/(4*qz),(m12+m21)/(4*qz),qz},-1)},-2);
    auto index=torch::stack({qw,qx,qy,qz},-1).argmax(-1);
    auto q=smc_normalize(candidates.gather(-2,index.view({-1,1,1}).expand({m.size(0),1,4})).squeeze(-2));
    q=q*torch::where(q.narrow(-1,0,1)<0,-1.0,1.0);
    // quat_to_rotvec repeats the canonical sign selection in SMC.
    q=q*torch::where(q.narrow(-1,0,1)<0,-1.0,1.0);
    auto v=q.narrow(-1,1,3),w=q.narrow(-1,0,1);
    auto n=at::linalg_vector_norm(v,2,{-1},true);
    auto half=torch::atan2(n,w);
    auto scale=torch::where(n<1e-6,2.0/w.clamp_min(1e-6),2*half/(n+1e-12));
    return v*scale;
  },err,cap);
}
extern "C" void *mr_tensor_stable_heading_v1(void *input, char *err, int cap) {
  return tensor([&] {
    auto &r=unbox(input); smc_float(r);
    if(r.dim()!=3||r.size(0)<1||r.size(0)>131072||r.size(1)!=3||r.size(2)!=3)
      throw std::invalid_argument("stable heading requires [1..131072,3,3]");
    auto fx=r.select(-2,0).select(-1,0),fy=r.select(-2,1).select(-1,0);
    auto vertical=fx.square()+fy.square()<1e-12;
    fx=torch::where(vertical,r.select(-2,1).select(-1,1),fx);
    fy=torch::where(vertical,-r.select(-2,0).select(-1,1),fy);
    auto n=torch::sqrt(fx*fx+fy*fy).clamp_min(1e-12);
    auto c=fx/n,s=fy/n,o=torch::zeros_like(c),one=torch::ones_like(c);
    return torch::stack({c,-s,o,s,c,o,o,o,one},-1).reshape({r.size(0),3,3});
  },err,cap);
}
extern "C" void *mr_tensor_smc_xi_v1(void *input, char *err, int cap) {
  return tensor([&] {
    auto &x=unbox(input); smc_float(x);
    if (x.dim()!=2 || x.size(0)<1 || x.size(0)>131072 || x.size(1)!=33)
      throw std::invalid_argument("SMC xi requires [1..131072,33]");
    return torch::cat({(x.narrow(1,0,1)-0.75)/0.45,x.narrow(1,1,29)/0.01,x.narrow(1,30,3)/0.05},1);
  },err,cap);
}
extern "C" void *mr_tensor_smc_return_v1(void *rewards, void *failures, void *tail,
                                         double gamma, char *err, int cap) {
  return tensor([&] {
    auto &r=unbox(rewards),&d=unbox(failures),&v=unbox(tail); smc_float(r);
    if (r.dim()!=2 || r.size(0)<1 || r.size(0)>64 || r.size(1)<1 || r.numel()>262144 ||
        r.sizes()!=d.sizes() || v.dim()!=1 || v.size(0)!=r.size(1) ||
        r.device()!=d.device() || r.device()!=v.device() ||
        r.scalar_type()!=d.scalar_type() || r.scalar_type()!=v.scalar_type() ||
        !std::isfinite(gamma) || gamma<0 || gamma>1)
      throw std::invalid_argument("SMC return shape/device/dtype/gamma mismatch");
    auto h=r.size(0),b=r.size(1);
    auto alive=torch::cumprod(1-d,0);
    auto ct=torch::cat({torch::ones({1,b},r.options().requires_grad(false)),alive.narrow(0,0,h-1)},0);
    auto disc=torch::pow(gamma,torch::arange(h,r.options().dtype(torch::kFloat32).requires_grad(false))).unsqueeze(-1);
    auto j=(disc*ct*r).sum(0);
    auto c=alive.select(0,h-1);
    j=j+std::pow(gamma,static_cast<double>(h))*c*v;
    return torch::stack({j,(ct*r).detach().sum(0),c},0);
  },err,cap);
}
