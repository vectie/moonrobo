// Optional fixed-shape AOTAutograd/AOTInductor execution. No Python runtime.
// Each graph's parameters are explicit inputs, never compiled constants.
#ifdef MR_ENABLE_AOTI
#include <torch/csrc/inductor/aoti_runner/model_container_runner_cuda.h>
#include <c10/cuda/CUDAGuard.h>
#include <ATen/cuda/CUDAContext.h>
#include <fstream>

namespace {
struct AotiInputSpec {
  std::vector<int64_t> sizes, strides;
  int dtype;
  void check(const torch::Tensor& t, int device) const {
    if (!t.defined() || !t.is_cuda() || t.get_device()!=device ||
        t.scalar_type()!=static_cast<c10::ScalarType>(dtype) ||
        t.sizes().vec()!=sizes || t.strides().vec()!=strides) {
      std::ostringstream detail;
      detail << "compiled block shape/stride/dtype/device mismatch: expected sizes=" << sizes
             << " strides=" << strides << " dtype=" << dtype << " cuda=" << device;
      if(t.defined()) detail << "; actual sizes=" << t.sizes() << " strides="
             << t.strides() << " dtype=" << t.scalar_type() << " device=" << t.device();
      throw std::invalid_argument(detail.str());
    }
  }
};
struct AotiPlan : torch::CustomClassHolder {
  std::unique_ptr<torch::inductor::AOTIModelContainerRunnerCuda> fw, bw;
  std::vector<AotiInputSpec> inputs, backward_inputs;
  std::vector<int> gradient_indices;
  int outputs, device;
  bool inference_only=false;
  std::mutex mutex;
  AotiPlan(const char* directory, int device_) : device(device_) {
    if (!directory || device<0) throw std::invalid_argument("compiled block path/device");
    const std::string root(directory);
    std::ifstream in(root+"/native.spec");
    std::string magic, version;
    int major,minor,ni,nb;
    if (!(in>>magic>>version>>major>>minor>>ni>>nb>>outputs) ||
        (magic!="MR_AOTI_V1" && magic!="MR_AOTI_V2" && magic!="MR_AOTI_V3" && magic!="MR_AOTI_V4") || version!=TORCH_VERSION || ni<1 || ni>128 ||
        nb<0 || nb>2048 || outputs<1 || outputs>16 ||
        (magic=="MR_AOTI_V3" ? nb!=0 : (magic=="MR_AOTI_V4" && nb==0 ? false : nb<outputs)))
      throw std::invalid_argument("compiled block manifest/version/count");
    inference_only=magic=="MR_AOTI_V3" || (magic=="MR_AOTI_V4" && nb==0);
    if(magic=="MR_AOTI_V1") {for(int i=0;i<ni;++i)gradient_indices.push_back(i);}
    else {
      int ng;if(!(in>>ng)||ng<0||ng>ni||(inference_only ? ng!=0 : ng<1))throw std::invalid_argument("compiled gradient count");
      for(int i=0;i<ng;++i){int index;if(!(in>>index)||index<0||index>=ni||(!gradient_indices.empty()&&index<=gradient_indices.back()))throw std::invalid_argument("compiled gradient index");gradient_indices.push_back(index);}
    }
    // Legacy manifests retain their exact TF32 requirement. V4 explicitly
    // declares the FP32 arithmetic used by the separately validated package.
    std::string precision="tf32";
    if(magic=="MR_AOTI_V4" && (!(in>>precision) || (precision!="ieee" && precision!="tf32")))
      throw std::invalid_argument("compiled block precision contract");
    c10::cuda::CUDAGuard guard(device);
    auto* properties=at::cuda::getCurrentDeviceProperties();
    if (properties->major!=major || properties->minor!=minor)
      throw std::invalid_argument("compiled block CUDA architecture mismatch");
    if(at::globalContext().float32Precision(at::Float32Backend::CUDA,
          at::Float32Op::MATMUL)!=(precision=="ieee" ? at::Float32Precision::IEEE : at::Float32Precision::TF32))
      throw std::invalid_argument("compiled package FP32 arithmetic differs from its precision contract");
    auto read=[&](int n,std::vector<AotiInputSpec>& specs) {
      for (int i=0;i<n;++i) {
        AotiInputSpec spec;int rank;
        if (!(in>>rank>>spec.dtype) || rank<0 || rank>8 ||
            (spec.dtype!=static_cast<int>(torch::kFloat32) && spec.dtype!=static_cast<int>(torch::kBFloat16) &&
             spec.dtype!=static_cast<int>(torch::kInt64) && spec.dtype!=static_cast<int>(torch::kBool)))
          throw std::invalid_argument("compiled block tensor spec");
        spec.sizes.resize(rank);spec.strides.resize(rank);
        for (auto& d:spec.sizes) if (!(in>>d) || d<1 || d>16777216) throw std::invalid_argument("compiled block size");
        for (auto& d:spec.strides) if (!(in>>d) || d<0 || d>16777216) throw std::invalid_argument("compiled block stride");
        specs.push_back(std::move(spec));
      }
    };
    read(ni,inputs);read(nb,backward_inputs);
    std::string tail;if(in>>tail) throw std::invalid_argument("compiled block trailing manifest data");
    const auto dev="cuda:"+std::to_string(device);
    fw=std::make_unique<torch::inductor::AOTIModelContainerRunnerCuda>(root+"/forward.so",1,dev,root);
    if(!inference_only)bw=std::make_unique<torch::inductor::AOTIModelContainerRunnerCuda>(root+"/backward.so",1,dev,root);
  }
  ~AotiPlan() override {
    // Unloading generated cubins must wait for outstanding work, including a
    // caller using another CUDA stream. This is plan teardown only, never a
    // per-forward/backward synchronization or part of the measured loop.
    try {c10::cuda::CUDAGuard guard(device); (void)cudaDeviceSynchronize();}catch(...){}
  }
};
using AotiOwner=c10::intrusive_ptr<AotiPlan>;
torch::autograd::variable_list aoti_inference(AotiOwner plan,const std::vector<torch::Tensor>& xs) {
  if(!plan->inference_only || xs.size()!=plan->inputs.size())throw std::invalid_argument("compiled inference input count");
  for(size_t i=0;i<xs.size();++i) {
    plan->inputs[i].check(xs[i],plan->device);
    if(xs[i].requires_grad())throw std::invalid_argument("inference-only package refuses differentiable inputs");
  }
  c10::cuda::CUDAGuard guard(plan->device);
  torch::NoGradGuard no_grad;
  std::lock_guard<std::mutex> lock(plan->mutex);
  auto result=plan->fw->run_with_cuda_stream(xs,at::cuda::getCurrentCUDAStream(plan->device));
  if(result.size()!=static_cast<size_t>(plan->outputs))throw std::runtime_error("compiled inference output count");
  return result;
}
class AotiNode : public torch::autograd::Function<AotiNode> {
 public:
  static torch::autograd::variable_list forward(torch::autograd::AutogradContext* ctx,AotiOwner plan,at::TensorList xs) {
    if(plan->inference_only || xs.size()!=plan->inputs.size()) throw std::invalid_argument("compiled block input count/mode");
    for(size_t i=0;i<xs.size();++i) {
      try {plan->inputs[i].check(xs[i],plan->device);}
      catch(const std::exception& e){throw std::invalid_argument("forward input "+std::to_string(i)+": "+e.what());}
      if(xs[i].requires_grad() && std::find(plan->gradient_indices.begin(),plan->gradient_indices.end(),i)==plan->gradient_indices.end())
        throw std::invalid_argument("compiled package has no VJP for a differentiable input");
    }
    c10::cuda::CUDAGuard guard(plan->device);
    std::lock_guard<std::mutex> lock(plan->mutex);
    auto ys=plan->fw->run_with_cuda_stream(xs.vec(),at::cuda::getCurrentCUDAStream(plan->device));
    if(ys.size()!=plan->backward_inputs.size()) throw std::runtime_error("compiled block saved tensor count");
    // AOTAutograd layout: [user output, saved tensors]; backward consumes the
    // saved tensors followed by the output cotangent. Retain original inputs
    // too: SavedVariable then enforces normal autograd mutation/version checks.
    std::vector<torch::Tensor> saved(ys.begin()+plan->outputs,ys.end());
    saved.insert(saved.end(),xs.begin(),xs.end());
    ctx->save_for_backward(saved);
    ctx->saved_data["plan"]=c10::IValue::make_capsule(plan);
#if defined(MR_AOTI_ADJOINT_DIAGNOSTICS)
    // Diagnostic builds only. Observe the actual engine-joined cotangents,
    // never substitute derivatives or keep GPU tensors beyond their lifetime.
    if (std::getenv("MOONROBO_AOTI_ADJOINTS") && plan->outputs==8) {
      if(xs.size()<8 || xs[7].scalar_type()!=torch::kInt64 || xs[7].sizes()!=torch::IntArrayRef({4096}))
        throw std::invalid_argument("actor adjoint frame contract");
      auto frame=xs[7][0].item<int64_t>();
      if(frame<0 || frame>=32*4096 || frame%4096)throw std::invalid_argument("actor adjoint step");
      ctx->saved_data["adjoint_step"]=frame/4096;
    }
#endif
    ys.resize(plan->outputs);return ys;
  }
  static torch::autograd::variable_list backward(torch::autograd::AutogradContext* ctx,torch::autograd::variable_list grads) {
    if(torch::GradMode::is_enabled()) throw std::invalid_argument("compiled block supports first-order gradients only");
    auto capsule=ctx->saved_data.at("plan").toCapsule();
    auto* plan=static_cast<AotiPlan*>(capsule.get());
    auto saved=ctx->get_saved_variables();
    saved.resize(plan->backward_inputs.size()-plan->outputs);
    if(grads.size()!=static_cast<size_t>(plan->outputs))throw std::runtime_error("compiled cotangent count");
#if defined(MR_AOTI_ADJOINT_DIAGNOSTICS)
    if(ctx->saved_data.count("adjoint_step")) {
      const char* root=std::getenv("MOONROBO_AOTI_ADJOINTS");
      if(!root || std::string(root)!="/pair")throw std::invalid_argument("adjoint output must be guarded /pair");
      const int64_t widths[]={3,9,3,3,29,29,29,990};
      for(size_t i=0;i<grads.size();++i) {
        auto &g=grads[i];
        if(!g.defined() || g.scalar_type()!=torch::kFloat32 || g.numel()!=4096*widths[i])
          throw std::invalid_argument("bounded FP32 actor cotangent required");
        auto cpu=g.detach().cpu().contiguous();
        const auto path=std::string(root)+"/aoti-adjoint-"+std::to_string(ctx->saved_data.at("adjoint_step").toInt())+"-"+std::to_string(i)+".f32";
        if(std::ifstream(path).good())throw std::invalid_argument("fresh adjoint file required");
        std::ofstream file(path,std::ios::binary|std::ios::out);
        file.write(reinterpret_cast<const char*>(cpu.data_ptr<float>()),cpu.numel()*sizeof(float));
        if(!file.good())throw std::runtime_error("adjoint snapshot write failed");
      }
    }
#endif
    for(auto& g:grads)saved.push_back(g.contiguous());
    for(size_t i=0;i<saved.size();++i) {
      // Forward and VJP are separately compiled. Inductor may pad internal
      // forward outputs; restore the VJP's declared layout without changing
      // values. External arguments remain strict, and already matching saved
      // tensors incur no allocation/copy. Never reinterpret padded storage.
      const auto& spec=plan->backward_inputs[i];
      if(saved[i].defined() && saved[i].is_cuda() && saved[i].get_device()==plan->device &&
         saved[i].scalar_type()==static_cast<c10::ScalarType>(spec.dtype) &&
         saved[i].sizes().vec()==spec.sizes && saved[i].strides().vec()!=spec.strides) {
        auto laid_out=torch::empty_strided(spec.sizes,spec.strides,saved[i].options());
        laid_out.copy_(saved[i]);saved[i]=std::move(laid_out);
      }
      try {plan->backward_inputs[i].check(saved[i],plan->device);}
      catch(const std::exception& e){throw std::invalid_argument("backward input "+std::to_string(i)+": "+e.what());}
    }
    c10::cuda::CUDAGuard guard(plan->device);
    std::lock_guard<std::mutex> lock(plan->mutex);
    auto result=plan->bw->run_with_cuda_stream(saved,at::cuda::getCurrentCUDAStream(plan->device));
    if(result.size()!=plan->gradient_indices.size()) throw std::runtime_error("compiled block gradient count");
#if defined(MR_AOTI_ADJOINT_DIAGNOSTICS)
    if(std::getenv("MOONROBO_AOTI_ADJOINTS")&&plan->outputs==2&&result.size()==8) {
      for(size_t i=0;i<result.size();++i) {
        if(result[i].size(0)!=32*4096)throw std::invalid_argument("reward diagnostic rows");
        actor_diagnostic_tensor("reward-gradient-"+std::to_string(plan->gradient_indices[i]),result[i].narrow(0,31*4096,4096));
      }
      for(size_t i=0;i<grads.size();++i)actor_diagnostic_tensor("reward-upstream-"+std::to_string(i),grads[i]);
    }
#endif
    // One non-tensor argument (the owner), then TensorList is flattened by
    // LibTorch's ExtractVariables. Parameter gradients stay in FP32.
    torch::autograd::variable_list full(plan->inputs.size()+1);
    for(size_t i=0;i<result.size();++i)full[1+plan->gradient_indices[i]]=result[i];
    return full;
  }
};
}
extern "C" void* mr_compiled_block_load_v1(const char* path,int device,char* err,int cap) {
  try {return new AotiOwner(c10::make_intrusive<AotiPlan>(path,device));}
  catch(const std::exception& e){error(err,cap,e.what());return nullptr;}
}
extern "C" void mr_compiled_block_destroy_v1(void* p) {delete static_cast<AotiOwner*>(p);}
extern "C" void* mr_compiled_block_run_v1(void* p,void** xs,int n,char* err,int cap) {
  return tensor([&]{
    if(!p || !xs || n<1 || n>128) throw std::invalid_argument("compiled block handles");
    std::vector<torch::Tensor> inputs;inputs.reserve(n);
    for(int i=0;i<n;++i) inputs.push_back(unbox(xs[i]));
    if((*static_cast<AotiOwner*>(p))->outputs!=1)throw std::invalid_argument("multi-output block requires forward_many");
    if((*static_cast<AotiOwner*>(p))->inference_only)return aoti_inference(*static_cast<AotiOwner*>(p),inputs)[0];
    return AotiNode::apply(*static_cast<AotiOwner*>(p),at::TensorList(inputs))[0];
  },err,cap);
}
extern "C" void* mr_compiled_block_run_many_v1(void* p,void** xs,int n,char* err,int cap) {
  try {
    if(!p||!xs||n<1||n>128)throw std::invalid_argument("compiled block handles");
    std::vector<torch::Tensor> inputs;for(int i=0;i<n;++i)inputs.push_back(unbox(xs[i]));
    if((*static_cast<AotiOwner*>(p))->inference_only)return new torch::autograd::variable_list(aoti_inference(*static_cast<AotiOwner*>(p),inputs));
    return new torch::autograd::variable_list(AotiNode::apply(*static_cast<AotiOwner*>(p),at::TensorList(inputs)));
  }catch(const std::exception& e){error(err,cap,e.what());return nullptr;}
}
extern "C" void mr_compiled_outputs_destroy_v1(void* p){delete static_cast<torch::autograd::variable_list*>(p);}
extern "C" int mr_compiled_outputs_count_v1(void* p){return p?static_cast<torch::autograd::variable_list*>(p)->size():0;}
extern "C" void* mr_compiled_outputs_get_v1(void* p,int i,char* err,int cap){
  return tensor([&]{if(!p||i<0)throw std::invalid_argument("compiled output index");return static_cast<torch::autograd::variable_list*>(p)->at(i);},err,cap);
}
#endif
