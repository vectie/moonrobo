// Optional original-SMC Adam route. Mirrors noncapturable Float32 Adam:
// Python's single-tensor CPU path and foreach CUDA path. The C++
// optimizer state remains authoritative for checkpoint/audit compatibility.
extern "C" int mr_adam_step_smc_v1(void* pointer,double max_norm,double max_value,char* err,int cap) {
  return status([&] {
    auto& a=adam(pointer);
    if(!std::isfinite(max_norm)||max_norm<=0||!std::isfinite(max_value)||max_value<0)
      throw std::invalid_argument("SMC Adam requires positive finite norm clipping");
    if(a.optimizer->param_groups().size()!=1)
      throw std::invalid_argument("SMC Adam requires one parameter group");
    auto& group=a.optimizer->param_groups()[0];
    auto& options=static_cast<torch::optim::AdamOptions&>(group.options());
    if(options.amsgrad()||options.weight_decay()!=0)
      throw std::invalid_argument("SMC Adam requires no AMSGrad or weight decay");
    std::vector<torch::Tensor> gradients;
    for(const auto& p:a.parameters) {
      if((!p.is_cuda()&&!p.device().is_cpu())||p.scalar_type()!=torch::kFloat32||!p.grad().defined()||
          p.grad().is_sparse()||p.grad().sizes()!=p.sizes()||p.grad().scalar_type()!=p.scalar_type())
        throw std::invalid_argument("SMC Adam requires dense CPU/CUDA float32 gradients");
      if(p.device()!=a.parameters.front().device())
        throw std::invalid_argument("SMC Adam requires one device per optimizer");
      gradients.push_back(p.grad());
    }
    // Reject before mutating gradients, parameters, moments or step counters.
    // Python clip_grad_norm_ selects foreach on dense CUDA tensors. Retain
    // that reduction, too: scalar norm kernels can round differently even
    // when the following foreach Adam operations are identical.
    const auto total=torch::stack(at::_foreach_norm(gradients,2.0)).norm(2.0);
    if(!std::isfinite(total.item<double>()))
      throw std::invalid_argument("nonfinite SMC Adam norm; no parameters updated");
    torch::NoGradGuard guard;
    const auto coefficient=torch::clamp(max_norm/(total+1e-6),std::nullopt,1.0);
    at::_foreach_mul_(gradients,coefficient);
    if(max_value>0) {
      at::_foreach_clamp_min_(gradients,-max_value);
      at::_foreach_clamp_max_(gradients,max_value);
    }
    const auto beta1=std::get<0>(options.betas()), beta2=std::get<1>(options.betas());
    std::vector<torch::Tensor> means,variances;
    std::vector<at::Scalar> corrections,step_sizes;
    auto& states=a.optimizer->state();
    for(const auto& p:a.parameters) {
      const auto key=p.unsafeGetTensorImpl();
      if(states.find(key)==states.end()) {
        auto state=std::make_unique<torch::optim::AdamParamState>();
        state->step(0);
        state->exp_avg(torch::zeros_like(p,torch::MemoryFormat::Preserve));
        state->exp_avg_sq(torch::zeros_like(p,torch::MemoryFormat::Preserve));
        states[key]=std::move(state);
      }
      auto& state=static_cast<torch::optim::AdamParamState&>(*states.at(key));
      state.step(state.step()+1);
      if(p.device().is_cpu()) {
        state.exp_avg().lerp_(p.grad(),1-beta1);
        state.exp_avg_sq().mul_(beta2).addcmul_(p.grad(),p.grad(),1-beta2);
        const auto correction1=1-std::pow(beta1,state.step());
        const auto correction2=std::sqrt(1-std::pow(beta2,state.step()));
        const auto denominator=(state.exp_avg_sq().sqrt()/correction2).add_(options.eps());
        p.addcdiv_(state.exp_avg(),denominator,-options.lr()/correction1);
        continue;
      }
      means.push_back(state.exp_avg());variances.push_back(state.exp_avg_sq());
      corrections.emplace_back(std::sqrt(1-std::pow(beta2,state.step())));
      step_sizes.emplace_back(-options.lr()/(1-std::pow(beta1,state.step())));
    }
    if(means.empty()) return;
    at::_foreach_lerp_(means,gradients,1-beta1);
    at::_foreach_mul_(variances,beta2);
    at::_foreach_addcmul_(variances,gradients,gradients,1-beta2);
    auto denominators=at::_foreach_sqrt(variances);
    at::_foreach_div_(denominators,corrections);
    at::_foreach_add_(denominators,options.eps());
    at::_foreach_addcdiv_(a.parameters,means,denominators,step_sizes);
  },err,cap);
}
