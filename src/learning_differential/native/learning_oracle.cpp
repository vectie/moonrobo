/*
 * Independent ATen/LibTorch translation of ../smc/supermimic/networks.py,
 * rotations.py, mdp.py (invariant_features/normalize_xi), and the wm_update /
 * policy_update function bodies in train.py. The cheap FixtureMDP equations
 * are from providers/motion_learning/aligned/test_aligned_learning.py, not the
 * production physics MDP. No MoonBit SUT implementation is called here.
 *
 * Upstream SuperMimic sources are distributed under the MIT License:
 * Copyright (c) 2026 ETH Zurich, Chong Zhang
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Native Float64 conformance is executed separately from sealed upstream
 * Float32 qualification. See ../README.md for precision and evidence boundaries.
 */
#include "oracle.hpp"
#include <ATen/TensorIndexing.h>
#include <torch/autograd.h>
#include <torch/nn/utils/clip_grad.h>
#include <torch/optim/adam.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <set>
#include <stdexcept>
#include <utility>
#include <vector>

namespace moonrobo_diff {
namespace {
using at::Tensor;
using at::indexing::Ellipsis;
using at::indexing::Slice;
using State = std::array<Tensor,6>;
// An explicit Float64 conformance profile, separate from the preserved SMC
// profile. Scope restoration prevents failed evaluations leaking precision.
thread_local bool native64_profile = false;
struct PrecisionScope {
  bool previous;
  explicit PrecisionScope(bool enabled):previous(native64_profile){native64_profile=enabled;}
  ~PrecisionScope(){native64_profile=previous;}
};

const Tensor& require(const Tensors& input,const std::string& key) {
  auto found=input.find(key);
  if(found==input.end()) throw std::invalid_argument("learning oracle missing tensor: "+key);
  return found->second;
}
double config(const Tensors& input,const std::string& key) {
  const auto& value=require(input,"config."+key);
  if(value.numel()!=1) throw std::invalid_argument("configuration must be scalar: "+key);
  return value.item<double>();
}
int64_t integer_config(const Tensors& input,const std::string& key) {
  const double value=config(input,key);
  if(!std::isfinite(value)||std::floor(value)!=value||value < -9223372036854775808.0||value >= 9223372036854775808.0)
    throw std::invalid_argument("configuration must fit signed int64: "+key);
  return static_cast<int64_t>(value);
}
std::vector<int64_t> leading_shape(const Tensor& value,int removed,int appended) {
  auto shape=value.sizes().vec();
  shape.resize(shape.size()-removed);
  shape.push_back(appended);
  return shape;
}
Tensor apply_matrix(const Tensor& matrix,const Tensor& value) {
  return at::matmul(matrix,value.unsqueeze(-1)).squeeze(-1);
}
Tensor transpose(const Tensor& matrix) { return matrix.transpose(-1,-2); }
Tensor normalize_last(const Tensor& value) {
  return value/at::linalg_vector_norm(value,2,{-1},true).clamp_min(1e-12);
}
Tensor quaternion_matrix(const Tensor& input) {
  const auto q=normalize_last(input);const auto pieces=q.unbind(-1);
  const auto& w=pieces[0];const auto& x=pieces[1];const auto& y=pieces[2];const auto& z=pieces[3];
  auto shape=q.sizes().vec();shape.pop_back();shape.push_back(3);shape.push_back(3);
  return at::stack({1-2*(y*y+z*z),2*(x*y-w*z),2*(x*z+w*y),
                    2*(x*y+w*z),1-2*(x*x+z*z),2*(y*z-w*x),
                    2*(x*z-w*y),2*(y*z+w*x),1-2*(x*x+y*y)},-1).reshape(shape);
}
Tensor skew(const Tensor& value) {
  auto pieces=value.unbind(-1);auto x=pieces[0],y=pieces[1],z=pieces[2],o=at::zeros_like(x);
  auto shape=value.sizes().vec();shape.pop_back();shape.push_back(3);shape.push_back(3);
  return at::stack({o,-z,y,z,o,-x,-y,x,o},-1).reshape(shape);
}
Tensor so3_exp(const Tensor& value) {
  auto theta2=(value*value).sum(-1,true),theta=at::sqrt(theta2+1e-12),small=theta2<1e-8;
  auto a=at::where(small,1-theta2/6,at::sin(theta)/theta);
  auto b=at::where(small,0.5-theta2/24,(1-at::cos(theta))/(theta2+1e-12));
  auto K=skew(value),eye=at::eye(3,value.options()).expand(K.sizes());
  return eye+a.unsqueeze(-1)*K+b.unsqueeze(-1)*at::matmul(K,K);
}
Tensor matrix_quaternion(const Tensor& m) {
  auto m00=m.index({Ellipsis,0,0}),m01=m.index({Ellipsis,0,1}),m02=m.index({Ellipsis,0,2});
  auto m10=m.index({Ellipsis,1,0}),m11=m.index({Ellipsis,1,1}),m12=m.index({Ellipsis,1,2});
  auto m20=m.index({Ellipsis,2,0}),m21=m.index({Ellipsis,2,1}),m22=m.index({Ellipsis,2,2});
  auto qw=at::sqrt((1+m00+m11+m22).clamp_min(1e-10))/2;
  auto qx=at::sqrt((1+m00-m11-m22).clamp_min(1e-10))/2;
  auto qy=at::sqrt((1-m00+m11-m22).clamp_min(1e-10))/2;
  auto qz=at::sqrt((1-m00-m11+m22).clamp_min(1e-10))/2;
  auto candidates=at::stack({
    at::stack({qw,(m21-m12)/(4*qw),(m02-m20)/(4*qw),(m10-m01)/(4*qw)},-1),
    at::stack({(m21-m12)/(4*qx),qx,(m01+m10)/(4*qx),(m02+m20)/(4*qx)},-1),
    at::stack({(m02-m20)/(4*qy),(m01+m10)/(4*qy),qy,(m12+m21)/(4*qy)},-1),
    at::stack({(m10-m01)/(4*qz),(m02+m20)/(4*qz),(m12+m21)/(4*qz),qz},-1)},-2);
  auto idx=at::stack({qw,qx,qy,qz},-1).argmax(-1);
  auto shape=idx.sizes().vec();shape.push_back(1);shape.push_back(4);
  auto q=normalize_last(candidates.gather(-2,idx.unsqueeze(-1).unsqueeze(-1).expand(shape)).squeeze(-2));
  return q*at::where(q.index({Ellipsis,Slice(0,1)})<0,-1.0,1.0);
}
Tensor so3_log(const Tensor& rotation) {
  auto q=matrix_quaternion(rotation);
  q=q*at::where(q.index({Ellipsis,Slice(0,1)})<0,-1.0,1.0);
  auto v=q.index({Ellipsis,Slice(1,4)}),w=q.index({Ellipsis,Slice(0,1)});
  auto sin_half=at::linalg_vector_norm(v,2,{-1},true),half=at::atan2(sin_half,w);
  auto scale=at::where(sin_half<1e-6,2.0/w.clamp_min(1e-6),2*half/(sin_half+1e-12));
  return v*scale;
}
Tensor heading(const Tensor& rotation,bool fixture_corrected=false) {
  auto fx=rotation.index({Ellipsis,0,0}),fy=rotation.index({Ellipsis,1,0});
  Tensor n;
  if(fixture_corrected || native64_profile) {
    auto vertical=fx.square()+fy.square()<1e-12;
    fx=at::where(vertical,rotation.index({Ellipsis,1,1}),fx);
    fy=at::where(vertical,-rotation.index({Ellipsis,0,1}),fy);
    n=at::sqrt(fx*fx+fy*fy).clamp_min(1e-12);
  } else {
    // The actual upstream yaw_mat includes this regularization. Do not silently
    // substitute the candidate's proper-SO(3) correction in world-model paths.
    n=at::sqrt(fx*fx+fy*fy+1e-9);
  }
  auto c=fx/n,s=fy/n,o=at::zeros_like(c),one=at::ones_like(c);
  auto shape=rotation.sizes().vec();shape.resize(shape.size()-2);shape.push_back(3);shape.push_back(3);
  return at::stack({c,-s,o,s,c,o,o,o,one},-1).reshape(shape);
}
Tensor rotation6(const Tensor& rotation) {
  return rotation.index({Ellipsis,Slice(),Slice(0,2)}).reshape(leading_shape(rotation,2,6));
}
State unflatten(const Tensor& s) {
  TORCH_CHECK(s.size(-1)==71,"SMC flattened state must contain 71 values");
  return {s.index({Ellipsis,Slice(0,3)}),quaternion_matrix(s.index({Ellipsis,Slice(3,7)})),
          s.index({Ellipsis,Slice(7,10)}),s.index({Ellipsis,Slice(10,13)}),
          s.index({Ellipsis,Slice(13,42)}),s.index({Ellipsis,Slice(42,71)})};
}
Tensor invariant(const State& s,bool fixture_corrected=false) {
  auto Rt=transpose(s[1]),Ht=transpose(heading(s[1],fixture_corrected));
  return at::cat({s[0].index({Ellipsis,Slice(2,3)}),rotation6(at::matmul(Ht,s[1])),
                  apply_matrix(Rt,s[2]),apply_matrix(Rt,s[3]),s[4],s[5]},-1);
}
Tensor normalized_xi(const Tensor& xi) {
  return at::cat({(xi.index({Ellipsis,Slice(0,1)})-0.75)/0.45,
                   xi.index({Ellipsis,Slice(1,30)})/0.01,
                   xi.index({Ellipsis,Slice(30,33)})/0.05},-1);
}

// Original named_parameters ordering is hierarchical numeric module order,
// then weight before bias. std::map lexical ordering is deliberately not used.
struct Model {
  std::string name;
  Tensors tensors;
  std::vector<std::string> names;
  std::vector<Tensor> parameters;
  Model(const Tensors& input,std::string which,bool gradients):name(std::move(which)) {
    const auto prefix="weights."+name+".";
    for(const auto& item:input) if(item.first.rfind(prefix,0)==0)
      tensors.emplace(item.first.substr(prefix.size()),item.second.detach().clone());
    if(tensors.empty()) throw std::invalid_argument("missing model weights: "+name);
    const std::vector<std::string> groups=name=="pi"?std::vector<std::string>{"enc","dec"}:std::vector<std::string>{"net"};
    for(const auto& group:groups) {
      std::set<int> modules;
      for(const auto& item:tensors) if(item.first.rfind(group+".",0)==0) {
        const auto end=item.first.find('.',group.size()+1);
        if(end!=std::string::npos) modules.insert(std::stoi(item.first.substr(group.size()+1,end-group.size()-1)));
      }
      for(int module:modules) for(const auto& suffix:{"weight","bias"}) {
        auto key=group+"."+std::to_string(module)+"."+suffix;
        auto found=tensors.find(key);
        if(found==tensors.end()) throw std::invalid_argument("missing model parameter: "+name+"."+key);
        found->second.set_requires_grad(gradients);
        names.push_back(key);parameters.push_back(found->second);
      }
    }
  }
  Tensor& at(const std::string& key) {
    auto found=tensors.find(key);if(found==tensors.end()) throw std::invalid_argument("missing model tensor: "+name+"."+key);
    return found->second;
  }
  void gradients(bool enabled) { for(auto& p:parameters) p.set_requires_grad(enabled); }
};
Tensor normalize(Model& model,const std::string& prefix,const Tensor& x,double eps=1e-2) {
  return (x-model.at(prefix+".mean"))/at::sqrt(model.at(prefix+".var")+eps*eps);
}
void update_norm(Model& model,const std::string& prefix,const Tensor& input,double max_count=2e8) {
  at::NoGradGuard no_grad;
  auto& mean=model.at(prefix+".mean");auto& variance=model.at(prefix+".var");auto& count=model.at(prefix+".count");
  if(count.item<double>()>=max_count) return;
  // This .float() is required even for double fixtures, exactly as RunningNorm.
  auto x=input.reshape({-1,input.size(-1)}).to(native64_profile?at::kDouble:at::kFloat);
  const auto n=x.size(0);auto m=x.mean(0),v=x.var(0,false),total=count+n,delta=m-mean;
  mean.add_(delta*n/total);
  variance=(variance*count+v*n+delta.square()*count*n/total)/total;
  count=total;
}
Tensor mlp(Model& model,const std::string& prefix,Tensor x,bool silu,bool layer_norm) {
  std::vector<int> linear;
  for(const auto& key:model.names) if(key.rfind(prefix+".",0)==0&&key.size()>=7&&key.compare(key.size()-7,7,".weight")==0&&model.at(key).dim()==2) {
    auto end=key.find('.',prefix.size()+1);linear.push_back(std::stoi(key.substr(prefix.size()+1,end-prefix.size()-1)));
  }
  for(size_t i=0;i<linear.size();++i) {
    const auto module=prefix+"."+std::to_string(linear[i]);
    x=at::linear(x,model.at(module+".weight"),model.at(module+".bias"));
    if(i+1<linear.size()) {
      if(layer_norm) {
        const auto ln=prefix+"."+std::to_string(linear[i]+1);
        x=at::layer_norm(x,{x.size(-1)},model.at(ln+".weight"),model.at(ln+".bias"),1e-5,true);
      }
      x=silu?at::silu(x):at::elu(x,1.0,1.0,1.0);
    }
  }
  return x;
}
State world(Model& model,const State& s,const Tensor& action,const Tensor& xi_n) {
  auto inputs=at::cat({invariant(s),action,xi_n},-1);
  auto y=mlp(model,"net",normalize(model,"in_norm",inputs),true,true);
  auto d=y*at::sqrt(model.at("out_norm.var")+1e-8)+model.at("out_norm.mean");
  auto pieces=d.split_with_sizes({3,3,3,3,29,29},-1);
  return {s[0]+apply_matrix(heading(s[1]),pieces[0]),at::matmul(s[1],so3_exp(pieces[1])),
          s[2]+apply_matrix(s[1],pieces[2]),s[3]+apply_matrix(s[1],pieces[3]),s[4]+pieces[4],s[5]+pieces[5]};
}
Tensor state_error(const State& predicted,const State& truth) {
  auto Rt=transpose(truth[1]);
  return at::cat({apply_matrix(transpose(heading(truth[1])),predicted[0]-truth[0]),
                  so3_log(at::matmul(Rt,predicted[1])),apply_matrix(Rt,predicted[2]-truth[2]),
                  apply_matrix(Rt,predicted[3]-truth[3]),predicted[4]-truth[4],predicted[5]-truth[5]},-1);
}
Tensor policy(Model& model,const Tensor& history,const Tensor& goal) {
  auto z=at::tanh(mlp(model,"enc",normalize(model,"goal_norm",goal),false,false));
  auto obs=normalize(model,"obs_norm",history).flatten(-2);
  return mlp(model,"dec",at::cat({z,obs},-1),false,false);
}
Tensor critic(Model& model,const Tensor& input) {
  return mlp(model,"net",normalize(model,"norm",input),false,false).squeeze(-1);
}
Tensor fixture_observation(const State& s,const Tensor& previous) {
  return at::cat({s[4],s[5],s[3],-s[1].index({Ellipsis,2,Slice()}),previous},-1);
}
Tensor fixture_critic(const State& s,const Tensor& goal) {
  // This is deliberately the original test FixtureMDP's local invariant, whose
  // proper yaw differs from upstream mdp.invariant_features. It is not a call
  // into the translated SUT and must not be used for world-model invariants.
  auto inv=invariant(s,true);
  auto zeros_shape=leading_shape(inv,1,113);
  return at::cat({inv,at::zeros(zeros_shape,inv.options().dtype(native64_profile?at::kDouble:at::kFloat)),goal},-1);
}

std::unique_ptr<torch::optim::Adam> optimizer(Model& model,const Tensors& input,double lr,double beta2) {
  auto options=torch::optim::AdamOptions(lr).betas(std::make_tuple(0.9,beta2)).eps(1e-8);
  auto opt=std::make_unique<torch::optim::Adam>(model.parameters,options);
  for(size_t i=0;i<model.names.size();++i) {
    const auto prefix="optimizer_before."+model.name+"."+model.names[i]+".";
    const auto step_key=prefix+"step";
    auto step=input.find(step_key);
    if(step==input.end()) throw std::invalid_argument("missing fixed Adam state: "+step_key);
    TORCH_CHECK(step->second.numel()==1,"Adam step must be scalar");
    const double step_value=step->second.item<double>();
    if(!std::isfinite(step_value)||step_value<0||step_value>=9223372036854775808.0||std::floor(step_value)!=step_value)
      throw std::invalid_argument("Adam step must be a finite nonnegative signed-int64 integer");
    auto state=std::make_unique<torch::optim::AdamParamState>();
    state->step(static_cast<int64_t>(step_value));
    state->exp_avg(require(input,prefix+"exp_avg").detach().clone());
    state->exp_avg_sq(require(input,prefix+"exp_avg_sq").detach().clone());
    TORCH_CHECK(state->exp_avg().sizes()==model.parameters[i].sizes()&&state->exp_avg_sq().sizes()==model.parameters[i].sizes(),"Adam moments shape mismatch");
    TORCH_CHECK(state->exp_avg().scalar_type()==model.parameters[i].scalar_type()&&state->exp_avg_sq().scalar_type()==model.parameters[i].scalar_type(),"Adam moments dtype mismatch");
    TORCH_CHECK(state->exp_avg().device()==model.parameters[i].device()&&state->exp_avg_sq().device()==model.parameters[i].device(),"Adam moments device mismatch");
    opt->state()[model.parameters[i].unsafeGetTensorImpl()]=std::move(state);
  }
  return opt;
}
void capture_gradients(Tensors& output,Model& model,const std::string& stage,const std::string& step="") {
  for(size_t i=0;i<model.names.size();++i) {
    const auto gradient=model.parameters[i].grad();
    TORCH_CHECK(gradient.defined(),"oracle expected a gradient for ",model.name,".",model.names[i]);
    output["grad."+stage+"."+model.name+"."+step+model.names[i]]=gradient.detach().clone();
  }
}
void capture_weights(Tensors& output,Model& model) {
  for(const auto& item:model.tensors) output["weights_after."+model.name+"."+item.first]=item.second.detach().clone();
}
void capture_optimizer(Tensors& output,Model& model,torch::optim::Adam& opt) {
  for(size_t i=0;i<model.names.size();++i) {
    const auto found=opt.state().find(model.parameters[i].unsafeGetTensorImpl());
    TORCH_CHECK(found!=opt.state().end(),"Adam state unexpectedly absent after update");
    const auto& state=dynamic_cast<const torch::optim::AdamParamState&>(*found->second);
    const auto prefix="optimizer_after."+model.name+"."+model.names[i]+".";
    output[prefix+"exp_avg"]=state.exp_avg().detach().clone();
    output[prefix+"exp_avg_sq"]=state.exp_avg_sq().detach().clone();
    output[prefix+"step"]=at::scalar_tensor(static_cast<double>(state.step()),at::TensorOptions().dtype(native64_profile?at::kDouble:at::kFloat));
  }
}
void capture_state(Tensors& output,const std::string& prefix,const State& state) {
  static const std::array<std::string,6> names={"p","R","v","w","q","qd"};
  for(size_t i=0;i<names.size();++i) output[prefix+names[i]]=state[i].detach().clone();
}
void network_operation(const Tensors& input,Tensors& output) {
  Model wm(input,"wm",false),pi(input,"pi",false),value(input,"critic",false);
  at::NoGradGuard no_grad;
  capture_state(output,"network.world.",world(wm,unflatten(require(input,"inputs.state")),require(input,"inputs.action"),require(input,"inputs.xi_normalized")));
  output["network.policy"]=policy(pi,require(input,"inputs.observation_history"),require(input,"inputs.goal")).detach().clone();
  output["network.critic"]=critic(value,require(input,"inputs.critic_features")).detach().clone();
}
void world_operation(const Tensors& input,Tensors& output) {
  Model wm(input,"wm",true);
  auto opt=optimizer(wm,input,config(input,"lr"),0.999);
  const auto& states=require(input,"inputs.windows.s");const auto& actions=require(input,"inputs.windows.a");
  const auto& xi=require(input,"inputs.windows.xi");const auto& targets=require(input,"inputs.windows.s1");
  const auto& mask=require(input,"inputs.windows.mask");const auto horizon=integer_config(input,"wm_window");
  TORCH_CHECK(horizon>0&&states.size(1)==horizon&&mask.size(1)==horizon,"world window shape/config mismatch");
  auto state=unflatten(states.select(1,0));std::array<std::vector<Tensor>,6> predicted;
  for(int64_t t=0;t<horizon;++t) {
    state=world(wm,state,actions.select(1,t),normalized_xi(xi.select(1,t)));
    for(size_t i=0;i<6;++i) predicted[i].push_back(state[i]);
  }
  State stacked;
  for(size_t i=0;i<6;++i) stacked[i]=at::stack(predicted[i],1);
  auto std=at::maximum(at::sqrt(wm.at("out_norm.var")+1e-8),require(input,"inputs.error_floor"));
  auto errors=(state_error(stacked,unflatten(targets))/std).square().mean(-1);
  auto loss=(errors*mask).sum()/targets.size(0);
  opt->zero_grad(true);loss.backward();capture_gradients(output,wm,"raw");
  torch::nn::utils::clip_grad_norm_(wm.parameters,1.0);capture_gradients(output,wm,"clipped");
  opt->step();
  output["metrics.wm_loss"]=(loss.detach()/horizon).clone();
  const auto lastmask=mask.select(1,horizon-1);
  output["metrics.wm_err8"]=(errors.select(1,horizon-1).detach()*lastmask).sum()/lastmask.sum().clamp_min(1);
  capture_weights(output,wm);capture_optimizer(output,wm,*opt);
}

void policy_operation(const Tensors& input,Tensors& output) {
  Model wm(input,"wm",false),pi(input,"pi",true),value(input,"critic",false);
  const auto horizon=integer_config(input,"horizon"),hist=integer_config(input,"hist"),frames=integer_config(input,"goal_frames");
  const auto epochs=integer_config(input,"critic_epochs"),minibatches=integer_config(input,"critic_minibatches");
  const double gamma=config(input,"gamma"),lam=config(input,"lam"),lr=config(input,"lr");
  const bool no_critic=config(input,"no_critic")!=0;
  TORCH_CHECK(horizon>0&&hist>0&&frames>0&&epochs>=0&&minibatches>0,"invalid policy fixture configuration");
  TORCH_CHECK(config(input,"observation_noise")==0,"FixtureMDP oracle requires explicit disabled observation noise");
  const auto& initial=require(input,"inputs.starts.s");const auto batch=initial.size(0);
  auto state=unflatten(initial),initial_state=state;
  auto previous=require(input,"inputs.starts.a_prev");auto f=require(input,"inputs.starts.f").clone();
  auto xi=require(input,"inputs.starts.xi"),xi_n=normalized_xi(xi);
  // FixtureMDP.obs deliberately does not use xi/f, but their shape and presence
  // are still part of the fixed replay fixture, not generated by this oracle.
  const auto& history_state=require(input,"inputs.history.s");
  const auto& history_previous=require(input,"inputs.history.a_prev");
  require(input,"inputs.history.xi");require(input,"inputs.history.f");
  TORCH_CHECK(history_state.size(0)==batch&&history_state.size(1)==hist,"history shape mismatch");
  Tensor history;
  {at::NoGradGuard no_grad;history=fixture_observation(unflatten(history_state),history_previous);}
  auto goal=at::full({batch,73*frames},0.01,initial.options().dtype(native64_profile?at::kDouble:at::kFloat));
  auto initial_goal=goal;
  std::array<std::vector<Tensor>,6> states;
  std::vector<Tensor> actions,previous_actions,frame_ids,goals;
  for(int64_t t=0;t<horizon;++t) {
    previous_actions.push_back(previous);
    auto action=policy(pi,history,goal);
    state=world(wm,state,action,xi_n);
    f=f+1;
    auto observation=fixture_observation(state,action);
    history=at::cat({history.index({Slice(),Slice(1,hist),Slice()}),observation.unsqueeze(1)},1);
    goal=at::full({batch,73*frames},0.01,initial.options().dtype(native64_profile?at::kDouble:at::kFloat));
    previous=action;
    for(size_t i=0;i<6;++i) states[i].push_back(state[i]);
    actions.push_back(action);frame_ids.push_back(f);goals.push_back(goal);
  }
  State all;
  for(size_t i=0;i<6;++i) all[i]=at::stack(states[i]).flatten(0,1);
  auto action=at::stack(actions).flatten(0,1),previous_action=at::stack(previous_actions).flatten(0,1);
  // Cheap differentiable FixtureMDP heads, not the production FK/reward MDP.
  auto reward=(0.1*at::exp(-all[4].square().mean(-1))-0.002*(action-previous_action).square().sum(-1)).view({horizon,batch});
  auto done=at::sigmoid((0.5-all[0].select(-1,2))/0.02).view({horizon,batch});
  auto alive=at::cumprod(1-done,0);
  // Original torch.ones and torch.arange explicitly have Float32 semantics,
  // even when the enclosing fixture tensors are double.
  auto before=at::cat({at::ones({1,batch},at::TensorOptions().dtype(at::kFloat).device(initial.device())),alive.index({Slice(0,horizon-1),Slice()})},0);
  auto discount=at::pow(gamma,at::arange(horizon,initial.options().dtype(native64_profile?at::kDouble:at::kFloat))).unsqueeze(-1);
  auto objective=(discount*before*reward).sum(0),continuation=alive.select(0,horizon-1);
  auto reward_sum=(before*reward).detach().sum(0);
  auto detached_reward=reward.detach(),detached_done=done.detach();
  if(!no_critic) objective=objective+std::pow(gamma,horizon)*continuation*critic(value,fixture_critic(state,goal));
  auto loss=-objective.mean();
  auto actor_opt=optimizer(pi,input,lr,0.95);actor_opt->zero_grad(true);loss.backward();
  capture_gradients(output,pi,"raw");
  const double gradnorm=torch::nn::utils::clip_grad_norm_(pi.parameters,1.0);
  torch::nn::utils::clip_grad_value_(pi.parameters,0.1);capture_gradients(output,pi,"clipped");
  if(std::isfinite(gradnorm)) actor_opt->step();
  wm.gradients(true);value.gradients(true);
  auto v_loss=at::zeros({},at::TensorOptions().dtype(at::kFloat));
  std::unique_ptr<torch::optim::Adam> critic_opt;
  if(!no_critic) {
    Tensor X,targets;
    {at::NoGradGuard no_grad;
      State extended;
      for(size_t i=0;i<6;++i) extended[i]=at::cat({initial_state[i].unsqueeze(0),at::stack(states[i]).detach()},0).flatten(0,1);
      auto allgoals=at::cat({initial_goal.unsqueeze(0),at::stack(goals)},0).flatten(0,1);
      X=fixture_critic(extended,allgoals).view({horizon+1,batch,-1});
    }
    update_norm(value,"norm",X);
    {at::NoGradGuard no_grad;
      auto values=critic(value,X),R=values.select(0,horizon);
      std::vector<Tensor> reverse;
      for(int64_t t=horizon-1;t>=0;--t) {
        R=detached_reward.select(0,t)+gamma*(1-detached_done.select(0,t))*((1-lam)*values.select(0,t+1)+lam*R);
        reverse.push_back(R);
      }
      std::reverse(reverse.begin(),reverse.end());targets=at::stack(reverse);
    }
    auto Xf=X.index({Slice(0,horizon),Slice(),Slice()}).reshape({-1,X.size(-1)}),Yf=targets.reshape({-1});
    const auto n=Xf.size(0),mb=n/minibatches;
    TORCH_CHECK(mb>0,"critic minibatch must not be empty");
    const auto& permutations=require(input,"inputs.critic_permutations");
    TORCH_CHECK(permutations.dim()==2&&permutations.size(0)==epochs&&permutations.size(1)==n&&permutations.scalar_type()==at::kLong,"critic permutations require exact i64 [epochs,H*B]");
    critic_opt=optimizer(value,input,lr,0.999);
    int64_t step=0;
    for(int64_t epoch=0;epoch<epochs;++epoch) {
      auto permutation=permutations.select(0,epoch);
      // Fixed permutations must each be a bijection, never oracle RNG draws.
      auto sorted=std::get<0>(permutation.sort());
      TORCH_CHECK(at::equal(sorted,at::arange(n,permutation.options())),"critic permutation must cover each row exactly once");
      for(int64_t i=0;i<minibatches;++i,++step) {
        auto indices=permutation.index({Slice(i*mb,(i+1)*mb)});
        v_loss=(critic(value,Xf.index_select(0,indices))-Yf.index_select(0,indices)).square().mean();
        critic_opt->zero_grad(true);v_loss.backward();
        const auto label="step"+std::to_string(step)+".";
        capture_gradients(output,value,"raw",label);
        torch::nn::utils::clip_grad_norm_(value.parameters,1.0);
        capture_gradients(output,value,"clipped",label);critic_opt->step();
      }
    }
  }
  output["metrics.pi_loss"]=loss.detach().clone();
  // v_loss intentionally retains the original last-minibatch meaning. The
  // original policy32 differential test does not compare it, so the strict
  // output schema has only its four asserted metrics; do not emit a new mean.
  (void)v_loss;
  output["metrics.imag_rew"]=(reward_sum/horizon/0.1).mean().detach().clone();
  output["metrics.pi_gradnorm"]=at::scalar_tensor(gradnorm,loss.options());
  output["metrics.imag_survival"]=continuation.mean().detach().clone();
  capture_weights(output,wm);capture_weights(output,pi);capture_weights(output,value);
  capture_optimizer(output,pi,*actor_opt);
  if(critic_opt) capture_optimizer(output,value,*critic_opt);
}
} // anonymous namespace

void learning_oracle(const std::string& operation,const Tensors& input,Tensors& output) {
  const bool native=operation.rfind("native64.learning.",0)==0;
  PrecisionScope precision(native);
  const auto op=native?operation.substr(18):operation;
  if(native) for(const auto& item:input) if(item.first.rfind("weights.",0)==0)
    TORCH_CHECK(item.second.scalar_type()==at::kDouble,"native64 requires actual Float64 weights");
  if(op=="network") network_operation(input,output);
  else if(op=="world_update") world_operation(input,output);
  else if(op=="policy_update") policy_operation(input,output);
  else throw std::invalid_argument("unknown independent learning operation: "+operation);
}
} // namespace moonrobo_diff
