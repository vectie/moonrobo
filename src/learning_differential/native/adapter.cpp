// Explicit, opt-in LibTorch oracle. No Python or simulator runtime is linked.
#include "oracle.hpp"
#include <torch/version.h>
#include <ATen/Parallel.h>
#include <cmath>
#include <climits>
#include <stdexcept>
#include <vector>
namespace {
struct Context {moonrobo_diff::Tensors input,output;std::vector<std::string> names;std::string failure;};
const at::Tensor& output(void*h,int i){auto&c=*static_cast<Context*>(h);if(i<0||i>=int(c.names.size()))throw std::out_of_range("oracle output index");return c.output.at(c.names[i]);}
}
extern "C" int moonrobo_diff_api_version(){return 1;}
extern "C" const char* moonrobo_diff_torch_version(){return TORCH_VERSION;}
extern "C" void* moonrobo_diff_create(){try{return new Context;}catch(...){return nullptr;}}
extern "C" void moonrobo_diff_destroy(void*h){try{delete static_cast<Context*>(h);}catch(...){}}
extern "C" void moonrobo_diff_clear(void*h){auto&c=*static_cast<Context*>(h);c.input.clear();c.output.clear();c.names.clear();c.failure.clear();}
extern "C" const char* moonrobo_diff_failure(void*h){return static_cast<Context*>(h)->failure.c_str();}
extern "C" int moonrobo_diff_put(void*h,const char*name,const char*dtype,const int64_t*shape,int rank,const double*values,int64_t count){
 auto&c=*static_cast<Context*>(h);try{
  if(rank<0||rank>16||count<0||count>INT_MAX)throw std::invalid_argument("bounded oracle input dimensions");
  std::vector<int64_t> dims(shape,shape+rank);int64_t size=1;for(auto d:dims){if(d<0||d>INT_MAX||size>INT_MAX/(d?d:1))throw std::invalid_argument("oracle tensor shape overflow");size*=d;}
  if(size!=count)throw std::invalid_argument("oracle tensor count mismatch");
  auto tensor=at::empty(dims,at::TensorOptions().dtype(at::kDouble));if(count)std::copy(values,values+count,tensor.data_ptr<double>());
  std::string type(dtype);at::ScalarType scalar;
  if(type=="<f8")scalar=at::kDouble;else if(type=="<f4")scalar=at::kFloat;else if(type=="<i8")scalar=at::kLong;else if(type=="<i4")scalar=at::kInt;else if(type=="|u1")scalar=at::kByte;else if(type=="|b1")scalar=at::kBool;else throw std::invalid_argument("unsupported oracle input dtype");
  if(!at::isfinite(tensor).all().item<bool>())throw std::invalid_argument("oracle input must be finite");
  c.input[name]=tensor.to(scalar);return 0;
 }catch(const std::exception&e){c.failure=e.what();return -1;}
}
extern "C" int moonrobo_diff_evaluate(void*h,const char*operation){auto&c=*static_cast<Context*>(h);try{
 at::set_num_threads(1);c.output.clear();c.names.clear();c.failure.clear();std::string op(operation);
 if(op=="network"||op=="world_update"||op=="policy_update")moonrobo_diff::learning_oracle(op,c.input,c.output);else moonrobo_diff::mathematical_oracle(op,c.input,c.output);
 for(auto&entry:c.output){auto&v=entry.second;if(v.device().type()!=at::kCPU||v.numel()>INT_MAX)throw std::runtime_error("oracle returned non-CPU or oversized output");if(!at::isfinite(v).all().item<bool>())throw std::runtime_error("oracle returned nonfinite output "+entry.first);v=v.detach().contiguous();c.names.push_back(entry.first);}return 0;
 }catch(const std::exception&e){c.failure=e.what();return -1;}}
extern "C" int moonrobo_diff_output_count(void*h){return int(static_cast<Context*>(h)->names.size());}
extern "C" const char* moonrobo_diff_output_name(void*h,int i){return static_cast<Context*>(h)->names.at(i).c_str();}
extern "C" const char* moonrobo_diff_output_dtype(void*h,int i){switch(output(h,i).scalar_type()){case at::kDouble:return "<f8";case at::kFloat:return "<f4";case at::kLong:return "<i8";case at::kInt:return "<i4";case at::kBool:return "|b1";case at::kByte:return "|u1";default:return "unsupported";}}
extern "C" int moonrobo_diff_output_rank(void*h,int i){return output(h,i).dim();}
extern "C" int64_t moonrobo_diff_output_dim(void*h,int i,int j){return output(h,i).size(j);}
extern "C" int64_t moonrobo_diff_output_size(void*h,int i){return output(h,i).numel();}
extern "C" double moonrobo_diff_output_value(void*h,int i,int64_t j){return output(h,i).reshape({-1}).index({j}).item<double>();}
