// Independently transcribed equations from pinned ../smc/supermimic.
// Its original yaw epsilon, quaternion branches and acos floor are intentional.
// Source attribution/license are recorded in README.md and SMC_LICENSE.
#include "oracle.hpp"
#include <ATen/CPUGeneratorImpl.h>
#include <torch/csrc/autograd/autograd.h>
#include <cmath>
#include <stdexcept>
#include <vector>
namespace moonrobo_diff { namespace {
using at::Tensor;using at::indexing::Slice;
Tensor get(const Tensors&x,const std::string&key){auto i=x.find(key);if(i==x.end())throw std::invalid_argument("missing independent oracle input "+key);return i->second;}
Tensor vec(Tensor R,Tensor v){return at::matmul(R,v.unsqueeze(-1)).squeeze(-1);}
Tensor normalize(Tensor x){return x/at::linalg_vector_norm(x,2,{-1},true).clamp_min(1e-12);}
// Avoid vector operator overload assumptions in shape construction.
std::vector<int64_t> matrix_shape(Tensor x,int trailing){auto s=x.sizes().vec();for(int i=0;i<trailing;++i)s.pop_back();s.push_back(3);s.push_back(3);return s;}
Tensor skew_matrix(Tensor x){auto a=x.unbind(-1);auto z=at::zeros_like(a[0]);return at::stack({z,-a[2],a[1],a[2],z,-a[0],-a[1],a[0],z},-1).reshape(matrix_shape(x,1));}
Tensor so3exp(Tensor x){auto s=(x*x).sum(-1,true),t=at::sqrt(s+1e-12);auto a=at::where(s<1e-8,1-s/6,at::sin(t)/t);auto b=at::where(s<1e-8,.5-s/24,(1-at::cos(t))/(s+1e-12));auto k=skew_matrix(x);return at::eye(3,x.options()).expand_as(k)+a.unsqueeze(-1)*k+b.unsqueeze(-1)*at::matmul(k,k);}
Tensor quat(Tensor m){
 auto e=[&](int i,int j){return m.index({at::indexing::Ellipsis,i,j});};auto a=e(0,0),b=e(1,1),c=e(2,2);
 auto qw=at::sqrt((1+a+b+c).clamp_min(1e-10))/2,qx=at::sqrt((1+a-b-c).clamp_min(1e-10))/2,qy=at::sqrt((1-a+b-c).clamp_min(1e-10))/2,qz=at::sqrt((1-a-b+c).clamp_min(1e-10))/2;
 auto candidates=at::stack({at::stack({qw,(e(2,1)-e(1,2))/(4*qw),(e(0,2)-e(2,0))/(4*qw),(e(1,0)-e(0,1))/(4*qw)},-1),at::stack({(e(2,1)-e(1,2))/(4*qx),qx,(e(0,1)+e(1,0))/(4*qx),(e(0,2)+e(2,0))/(4*qx)},-1),at::stack({(e(0,2)-e(2,0))/(4*qy),(e(0,1)+e(1,0))/(4*qy),qy,(e(1,2)+e(2,1))/(4*qy)},-1),at::stack({(e(1,0)-e(0,1))/(4*qz),(e(0,2)+e(2,0))/(4*qz),(e(1,2)+e(2,1))/(4*qz),qz},-1)},-2);
 auto index=at::stack({qw,qx,qy,qz},-1).argmax(-1);auto shape=index.sizes().vec();shape.push_back(1);shape.push_back(4);auto q=at::gather(candidates,-2,index.unsqueeze(-1).unsqueeze(-1).expand(shape)).squeeze(-2);q=normalize(q);return q*at::where(q.index({at::indexing::Ellipsis,Slice(0,1)})<0,-1.,1.);
}
Tensor rotation(Tensor q){q=normalize(q);auto a=q.unbind(-1);auto w=a[0],x=a[1],y=a[2],z=a[3];return at::stack({1-2*(y*y+z*z),2*(x*y-w*z),2*(x*z+w*y),2*(x*y+w*z),1-2*(x*x+z*z),2*(y*z-w*x),2*(x*z-w*y),2*(y*z+w*x),1-2*(x*x+y*y)},-1).reshape(matrix_shape(q,1));}
Tensor so3log(Tensor r){auto q=quat(r);auto v=q.index({at::indexing::Ellipsis,Slice(1,4)}),w=q.index({at::indexing::Ellipsis,Slice(0,1)});auto s=at::linalg_vector_norm(v,2,{-1},true);auto scale=at::where(s<1e-6,2/w.clamp_min(1e-6),2*at::atan2(s,w)/(s+1e-12));return v*scale;}
Tensor yaw(Tensor R){auto x=R.index({at::indexing::Ellipsis,0,0}),y=R.index({at::indexing::Ellipsis,1,0});auto n=at::sqrt(x*x+y*y+1e-9);auto c=x/n,s=y/n,z=at::zeros_like(x),o=at::ones_like(x);return at::stack({c,-s,z,s,c,z,z,z,o},-1).reshape(matrix_shape(R,2));}
Tensor six(Tensor R){auto x=R.index({at::indexing::Ellipsis,Slice(),Slice(0,2)});auto s=R.sizes().vec();s.pop_back();s.back()=6;return x.reshape(s);}
Tensor angle(Tensor a,Tensor b){return at::acos(((a*b).sum({-1,-2})-1).div(2).clamp(-1+1e-6,1-1e-6)).square();}
Tensor axis_rotation(Tensor axis,Tensor a){auto x=axis.index({0}),y=axis.index({1}),z=axis.index({2});auto c=at::cos(a),s=at::sin(a),k=1-c;return at::stack({c+x*x*k,x*y*k-z*s,x*z*k+y*s,y*x*k+z*s,c+y*y*k,y*z*k-x*s,z*x*k-y*s,z*y*k+x*s,c+z*z*k},-1).reshape(matrix_shape(a.unsqueeze(-1),1));}
struct State {Tensor p,R,v,w,q,qd;};
State state(const Tensors&x,const std::string&prefix){return {get(x,prefix+"p"),get(x,prefix+"R"),get(x,prefix+"v"),get(x,prefix+"w"),get(x,prefix+"q"),get(x,prefix+"qd")};}
struct Bodies {Tensor p,R,v,w;};
Bodies fk(const Tensors&x,State s){auto parent=get(x,"kin.parent").to(at::kLong),joint=get(x,"kin.joint").to(at::kLong),axes=get(x,"kin.axis"),offp=get(x,"kin.offset_p"),offR=get(x,"kin.offset_R");std::vector<Tensor>P,R,V,W;int64_t n=parent.numel();
 for(int64_t i=0;i<n;++i){auto par=parent[i].item<int64_t>();if(par<0){P.push_back(s.p);R.push_back(s.R);V.push_back(s.v);W.push_back(s.w);continue;}auto j=joint[i].item<int64_t>();if(j<0||par>=i)throw std::invalid_argument("upstream FK requires parent-first moving-joint tree");auto p=P[par]+vec(R[par],offp[i]);auto r=at::matmul(R[par],offR[i]);auto ri=at::matmul(r,axis_rotation(axes[i],s.q.index({at::indexing::Ellipsis,j})));auto wi=W[par]+vec(r,axes[i])*s.qd.index({at::indexing::Ellipsis,Slice(j,j+1)});auto vi=V[par]+at::cross(W[par],p-P[par],-1);P.push_back(p);R.push_back(ri);V.push_back(vi);W.push_back(wi);}
 auto tracked=get(x,"kin.tracked").to(at::kLong);return {at::stack(P,-2).index_select(-2,tracked),at::stack(R,-3).index_select(-3,tracked),at::stack(V,-2).index_select(-2,tracked),at::stack(W,-2).index_select(-2,tracked)};
}
Tensor inv(State s){auto rt=s.R.transpose(-1,-2);return at::cat({s.p.index({at::indexing::Ellipsis,Slice(2,3)}),six(at::matmul(yaw(s.R).transpose(-1,-2),s.R)),vec(rt,s.v),vec(rt,s.w),s.q,s.qd},-1);}
void heads(const Tensors&x,Tensors&out){
 auto ref=state(x,"reference.");auto s=state(x,"inputs.state.");auto p=s.p.clone().set_requires_grad(true),rvec=get(x,"inputs.rotation_vector").clone().set_requires_grad(true),q=s.q.clone().set_requires_grad(true);s.p=p;s.q=q;s.R=at::matmul(so3exp(rvec),ref.R);
 auto previous=get(x,"inputs.previous"),action=get(x,"inputs.action"),xi=get(x,"inputs.xi"),dq=get(x,"inputs.default_q");auto rt=s.R.transpose(-1,-2);auto obs=at::cat({s.q-dq-xi.index({at::indexing::Ellipsis,Slice(1,30)}),s.qd,vec(rt,s.w),-s.R.index({at::indexing::Ellipsis,2,Slice()}),previous,six(at::matmul(rt,ref.R))},-1);
 out["observation"]=obs;auto noise_options=obs.options().dtype(at::kFloat);auto widths=at::cat({at::full({29},.01,noise_options),at::full({29},.5,noise_options),at::full({3},.2,noise_options),at::full({3},.05,noise_options),at::zeros({29},noise_options),at::full({6},.05,noise_options)});
 out["noisy_observation"]=obs+(2*get(x,"inputs.observation_uniform")-1)*widths;
 auto ez=(ref.p.index({at::indexing::Ellipsis,2})-s.p.index({at::indexing::Ellipsis,2})).abs(),et=(ref.R.index({at::indexing::Ellipsis,2,2})-s.R.index({at::indexing::Ellipsis,2,2})).abs();out["termination"]=(ez>.25)|(et>.8);out["soft_termination"]=1-(1-at::sigmoid((ez-.25)/.02))*(1-at::sigmoid((et-.8)/.04));
 auto b=fk(x,s);Bodies rb{get(x,"reference.body_p"),get(x,"reference.body_R"),get(x,"reference.body_v"),get(x,"reference.body_w")};auto dR=yaw(at::matmul(s.R,ref.R.transpose(-1,-2)));auto anchor=at::cat({s.p.index({at::indexing::Ellipsis,Slice(0,2)}),ref.p.index({at::indexing::Ellipsis,Slice(2,3)})},-1);auto bp=anchor.unsqueeze(-2)+vec(dR.unsqueeze(-3),rb.p-ref.p.unsqueeze(-2)),bR=at::matmul(dR.unsqueeze(-3),rb.R);
 auto ep=(bp-b.p).square().sum(-1).mean(-1),eo=angle(bR,b.R).mean(-1),el=(rb.v-b.v).square().sum(-1).mean(-1),ea=(rb.w-b.w).square().sum(-1).mean(-1),erp=(ref.p-s.p).square().sum(-1),ero=angle(ref.R,s.R);
 auto track=at::exp(-ep/.09)+at::exp(-eo/.16)+at::exp(-el)+at::exp(-ea/(3.14*3.14))+.5*at::exp(-erp/.09)+.5*at::exp(-ero/.16);auto rate=(action-previous).square().sum(-1);auto lo=get(x,"kin.q_lo"),hi=get(x,"kin.q_hi"),mid=(lo+hi)/2,half=(hi-lo)*.45;auto limit=(at::relu(s.q-mid-half)+at::relu(mid-half-s.q)).sum(-1);auto reward=(track-.1*rate-2*limit)*.02;
 out["reward"]=reward;out["term.track"]=track*.02;out["term.e_body_pos"]=ep;out["term.e_body_ori"]=eo;out["term.e_root_pos"]=erp;out["term.action_rate"]=rate;out["term.joint_limit"]=limit;
 auto ht=yaw(s.R).transpose(-1,-2);auto eb=vec(ht.unsqueeze(-3),bp-b.p).flatten(-2);out["critic_features"]=at::cat({inv(s),ref.q-s.q,eb,vec(ht,ref.p-s.p),six(at::matmul(rt,ref.R)),xi},-1);
 auto gradients=torch::autograd::grad({reward.sum()},{p,rvec,q});out["gradient.p"]=gradients[0];out["gradient.rotation_vector"]=gradients[1];out["gradient.q"]=gradients[2];
}
void rng_replay(const Tensors&x,Tensors&out){auto generator=at::detail::createCPUGenerator(0);generator.set_state(get(x,"rng.before").to(at::kByte));auto calls=get(x,"rng.calls").to(at::kLong);if(calls.dim()!=2||calls.size(1)!=3||calls.size(0)>128)throw std::invalid_argument("bounded RNG call transcript shape required");for(int64_t i=0;i<calls.size(0);++i){auto kind=calls[i][0].item<int64_t>(),count=calls[i][1].item<int64_t>(),high=calls[i][2].item<int64_t>();if(count<0||count>10000000||high<0)throw std::invalid_argument("RNG call shape out of bounds");Tensor draw;if(kind==0)draw=at::randint(high,{count},generator,at::TensorOptions().dtype(at::kLong));else if(kind==1||kind==4)draw=at::rand({count},generator,at::TensorOptions().dtype(kind==4?at::kDouble:at::kFloat));else if(kind==2)draw=at::randperm(count,generator,at::TensorOptions().dtype(at::kLong));else if(kind==3)draw=at::multinomial(get(x,"rng.weights."+std::to_string(i)),count,true,generator);else throw std::invalid_argument("unknown explicit upstream RNG call kind");out["rng.draw."+std::to_string(i)]=draw;}out["rng.after"]=generator.get_state();}
Tensor derivative(Tensor x){auto g=at::zeros_like(x);auto n=x.size(0);g.index_put_({Slice(1,n-1)},(x.index({Slice(2,n)})-x.index({Slice(0,n-2)}))/.04);g.index_put_({0},(x[1]-x[0])/.02);g.index_put_({n-1},(x[n-1]-x[n-2])/.02);return g;}
void motion_oracle(const Tensors&x,Tensors&out){
 auto raw=get(x,"motion.raw").to(at::kFloat);auto fps=get(x,"config.source_fps").item<double>();auto source=raw.size(0);if(source<2||raw.size(1)!=36||fps<=0)throw std::invalid_argument("motion oracle needs finite T>=2 x36 source at positive fps");
 int64_t n=static_cast<int64_t>(std::floor(((source-1)/fps)/.02))+1;auto times=at::arange(n,raw.options())*.02*fps;auto index=times.floor().to(at::kLong).clamp_max(source-2);auto a=(times-index.to(at::kFloat)).clamp(0,1).unsqueeze(-1);auto interpolate=[&](Tensor v){return v.index_select(0,index)*(1-a)+v.index_select(0,index+1)*a;};
 auto p=interpolate(raw.index({Slice(),Slice(0,3)})),q=interpolate(raw.index({Slice(),Slice(7,36)}));auto xyzw=raw.index({Slice(),Slice(3,7)}),wxyz=at::cat({xyzw.index({Slice(),Slice(3,4)}),xyzw.index({Slice(),Slice(0,3)})},-1);auto qa=wxyz.index_select(0,index),qb=wxyz.index_select(0,index+1),dot=(qa*qb).sum(-1,true);qb=at::where(dot<0,-qb,qb);dot=dot.abs().clamp_max(1);auto theta=at::acos(dot),s=at::sin(theta);auto w0=at::where(s<1e-6,1-a,at::sin((1-a)*theta)/(s+1e-12)),w1=at::where(s<1e-6,a,at::sin(a*theta)/(s+1e-12));auto R=rotation(normalize(w0*qa+w1*qb));auto v=derivative(p),qd=derivative(q),w=at::zeros_like(p);w.index_put_({Slice(1,n-1)},so3log(at::matmul(R.index({Slice(2,n)}),R.index({Slice(0,n-2)}).transpose(-1,-2)))/.04);w.index_put_({0},so3log(at::matmul(R[1],R[0].transpose(-1,-2)))/.02);w.index_put_({n-1},so3log(at::matmul(R[n-1],R[n-2].transpose(-1,-2)))/.02);
 auto vl=vec(R.transpose(-1,-2),v),wl=vec(R.transpose(-1,-2),w);auto frames=at::arange(n,at::TensorOptions().dtype(at::kLong));auto future=(frames.unsqueeze(-1)+at::arange(1,11,frames.options())).clamp_max(n-1);auto Ht=yaw(R).transpose(-1,-2).unsqueeze(1);auto fp=p.index({future});auto fr=R.index({future});auto goal=at::cat({vec(Ht,fp-p.unsqueeze(1)),six(at::matmul(Ht,fr)),vl.index({future}),wl.index({future}),q.index({future}),qd.index({future})*.1},-1).reshape({n,730});
 out["clip_len"]=at::tensor({n},frames.options());out["clip_start"]=at::zeros({1},frames.options());out["clip_end"]=at::tensor({n-1},frames.options());out["clip_id"]=at::zeros({n},frames.options());out["root_p"]=p;out["root_R"]=R;out["root_v"]=v;out["root_w"]=w;out["q"]=q;out["qd"]=qd;out["root_v_local"]=vl;out["root_w_local"]=wl;out["root_gz"]=R.index({Slice(),2,2});out["future_frames"]=future;out["goals"]=goal;
}
void sampling_oracle(const Tensors&x,Tensors&out){
 auto G=get(x,"sampler.bin_G").to(at::kFloat),average=get(x,"sampler.bin_w_avg").to(at::kFloat);auto soft=at::softmax(-25.*G/get(x,"config.G_max").item<double>(),0);average=average*.999;average=average+.001*soft;auto probabilities=.5/G.numel()+.4*soft+.1*average/average.sum();auto generator=at::detail::createCPUGenerator(0);generator.set_state(get(x,"rng.before").to(at::kByte));auto n=get(x,"config.sample_count").item<int64_t>();auto bins=at::multinomial(probabilities,n,true,generator);auto start=get(x,"sampler.bin_start").to(at::kLong).index({bins}),end=at::minimum(start+50,get(x,"sampler.bin_clip_end").to(at::kLong).index({bins}));auto uniform=at::rand({n},generator,at::TensorOptions().dtype(at::kFloat));out["sampled_frames"]=start+(uniform*(end-start).to(at::kFloat)).to(at::kLong);out["sampled_bins"]=bins;out["bin_w_avg"]=average;
 auto indices=get(x,"sampler.update_bins").to(at::kLong),values=get(x,"sampler.update_returns").to(at::kFloat);G.index_put_({indices},.8*G.index({indices})+.2*values);out["bin_G"]=G;out["rng.after"]=generator.get_state();
}
} // namespace
void mathematical_oracle(const std::string&operation,const Tensors&x,Tensors&out){
 if(operation=="observation_modes"){auto s=state(x,"inputs.state."),ref=state(x,"reference.");auto rt=s.R.transpose(-1,-2);auto xi=get(x,"inputs.xi");auto obs=at::cat({s.q-get(x,"inputs.default_q")-xi.index({at::indexing::Ellipsis,Slice(1,30)}),s.qd,vec(rt,s.w),-s.R.index({at::indexing::Ellipsis,2,Slice()}),get(x,"inputs.previous"),six(at::matmul(rt,ref.R))},-1);out["paper"]=obs.index({Slice(),Slice(0,93)});out["smc"]=obs;out["observable"]=obs;out["dimensions"]=at::tensor({93,99,102},at::TensorOptions().dtype(at::kLong));return;}
 if(operation=="mdp_heads"){heads(x,out);return;}
 if(operation=="fk"){auto b=fk(x,state(x,"inputs.state."));out["body_p"]=b.p;out["body_R"]=b.R;out["body_v"]=b.v;out["body_w"]=b.w;return;}
 if(operation=="quaternion"){auto v=get(x,"inputs.vectors").clone().set_requires_grad(true);auto q=quat(so3exp(v));out["quaternion"]=q;auto g=torch::autograd::grad({(q*get(x,"inputs.quaternion_weights")).sum()},{v})[0];out["pullback"]=g;out["finite"]=at::isfinite(g).all();return;}
 if(operation=="rotation_fixes"){auto theta=at::full({},1e-5,at::TensorOptions().dtype(at::kDouble)).set_requires_grad(true);auto v=at::stack({theta,theta*0,theta*0});auto R=so3exp(v),eye=at::eye(3,R.options()),old=angle(R,eye),corrected=so3log(R).square().sum();out["candidate_angle_sq"]=corrected;out["candidate_gradient"]=torch::autograd::grad({corrected},{theta},{},true)[0];out["upstream_angle_sq"]=old;out["upstream_gradient"]=torch::autograd::grad({old},{theta})[0];auto vertical=at::tensor({0.,0.,1.,0.,1.,0.,-1.,0.,0.},R.options()).reshape({3,3});out["candidate_vertical_yaw"]=eye;out["upstream_vertical_determinant"]=at::linalg_det(yaw(vertical));return;}
 if(operation=="rng"){rng_replay(x,out);return;}
 if(operation=="motion"){motion_oracle(x,out);return;}
 if(operation=="reset_sampling"){sampling_oracle(x,out);return;}
 throw std::invalid_argument("unknown independent mathematical oracle operation: "+operation);
}
} // namespace moonrobo_diff
