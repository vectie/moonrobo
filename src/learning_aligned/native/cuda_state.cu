// Real CUDA buffers and kernels for the aligned articulation state boundary.
// This owns no physics solver and is never advertised as Newton/PhysX stepping.
#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(_WIN32)
#define MR_EXPORT __declspec(dllexport)
#else
#define MR_EXPORT __attribute__((visibility("default")))
#endif
namespace {
thread_local std::string last_error;
void check(cudaError_t e){if(e!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(e));}
struct State {
  int device=0,n=0;cudaStream_t stream=nullptr;
  float *pose=nullptr,*velocity=nullptr,*q=nullptr,*qd=nullptr,*targets=nullptr,*xi=nullptr,*origins=nullptr,*default_q=nullptr,*alpha=nullptr;
  ~State(){if(cudaSetDevice(device)==cudaSuccess){for(float* p:{pose,velocity,q,qd,targets,xi,origins,default_q,alpha})if(p)cudaFree(p);if(stream)cudaStreamDestroy(stream);}}
};
State& require_state(void* p){if(!p)throw std::runtime_error("null CUDA device-state handle");return *static_cast<State*>(p);}
void allocate(float*& p,size_t n){check(cudaMalloc(reinterpret_cast<void**>(&p),n*sizeof(float)));check(cudaMemset(p,0,n*sizeof(float)));}
__global__ void reset_kernel(int count,int worlds,const int* ids,const float* flat,const float* contexts,const float* origins,float* pose,float* velocity,float* q,float* qd,float* targets,float* xi) {
  int item=blockIdx.x*blockDim.x+threadIdx.x;if(item>=count)return;
  int id=ids[item];if(id<0||id>=worlds)return;
  const float* state=flat+71*item;
  for(int k=0;k<3;++k){pose[7*id+k]=state[k]+origins[3*id+k];velocity[6*id+k]=state[7+k];velocity[6*id+3+k]=state[10+k];}
  // Aligned wxyz -> Isaac Lab 3 xyzw; root velocities remain world-frame.
  pose[7*id+3]=state[4];pose[7*id+4]=state[5];pose[7*id+5]=state[6];pose[7*id+6]=state[3];
  for(int k=0;k<29;++k){q[29*id+k]=state[13+k];qd[29*id+k]=state[42+k];targets[29*id+k]=state[13+k];}
  for(int k=0;k<33;++k)xi[33*id+k]=contexts[33*item+k];
}
__global__ void target_kernel(int count,const float* actions,const float* defaults,const float* alpha,const float* xi,float* targets) {
  int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=count*29)return;int j=i%29,env=i/29;
  // Raw evaluation actions are intentionally not clipped to collection's +/-20.
  targets[i]=defaults[j]+xi[33*env+1+j]+alpha[j]*actions[i];
}
__global__ void gather_kernel(int count,const float* pose,const float* velocity,const float* q,const float* qd,const float* origins,float* flat) {
  int id=blockIdx.x*blockDim.x+threadIdx.x;if(id>=count)return;float* s=flat+71*id;
  for(int k=0;k<3;++k){s[k]=pose[7*id+k]-origins[3*id+k];s[7+k]=velocity[6*id+k];s[10+k]=velocity[6*id+3+k];}
  s[3]=pose[7*id+6];s[4]=pose[7*id+3];s[5]=pose[7*id+4];s[6]=pose[7*id+5];
  for(int k=0;k<29;++k){s[13+k]=q[29*id+k];s[42+k]=qd[29*id+k];}
}
template<class F> int operation(F&& f){last_error.clear();try{f();return 1;}catch(const std::exception& e){last_error=e.what();return 0;}}
void finite_array(const float* values,size_t n){if(!values)throw std::runtime_error("null CUDA upload input");for(size_t i=0;i<n;++i)if(!std::isfinite(values[i]))throw std::runtime_error("nonfinite CUDA state/control input");}
}
extern "C" MR_EXPORT const char* mr_aligned_cuda_error(){return last_error.c_str();}
extern "C" MR_EXPORT void* mr_aligned_cuda_create(int device,int n,const float* defaults,const float* alpha,const float* origins) {
  State* state=nullptr;
  if(!operation([&]{if(n<=0||n>std::numeric_limits<int>::max()/71)throw std::runtime_error("invalid GPU world count");finite_array(defaults,29);finite_array(alpha,29);finite_array(origins,size_t(n)*3);
    check(cudaSetDevice(device));state=new State;state->device=device;state->n=n;check(cudaStreamCreateWithFlags(&state->stream,cudaStreamNonBlocking));
    allocate(state->pose,size_t(n)*7);allocate(state->velocity,size_t(n)*6);allocate(state->q,size_t(n)*29);allocate(state->qd,size_t(n)*29);allocate(state->targets,size_t(n)*29);allocate(state->xi,size_t(n)*33);allocate(state->origins,size_t(n)*3);allocate(state->default_q,29);allocate(state->alpha,29);
    check(cudaMemcpyAsync(state->default_q,defaults,29*sizeof(float),cudaMemcpyHostToDevice,state->stream));check(cudaMemcpyAsync(state->alpha,alpha,29*sizeof(float),cudaMemcpyHostToDevice,state->stream));check(cudaMemcpyAsync(state->origins,origins,size_t(n)*3*sizeof(float),cudaMemcpyHostToDevice,state->stream));check(cudaStreamSynchronize(state->stream));})) {delete state;return nullptr;}
  return state;
}
extern "C" MR_EXPORT void mr_aligned_cuda_destroy(void* p){delete static_cast<State*>(p);}
extern "C" MR_EXPORT int mr_aligned_cuda_reset(void* p,int count,const int* ids,const float* flat,const float* contexts) {
  return operation([&]{auto& s=require_state(p);check(cudaSetDevice(s.device));if(count<0||count>s.n||!ids)throw std::runtime_error("invalid reset indices");if(!count)return;
    std::vector<bool> seen(s.n,false);for(int i=0;i<count;++i){if(ids[i]<0||ids[i]>=s.n||seen[ids[i]])throw std::runtime_error("reset indices must be distinct and in range");seen[ids[i]]=true;}
    finite_array(flat,size_t(count)*71);finite_array(contexts,size_t(count)*33);
    int* gpu_ids=nullptr;float *gpu_flat=nullptr,*gpu_xi=nullptr;
    try {check(cudaMalloc(reinterpret_cast<void**>(&gpu_ids),size_t(count)*sizeof(int)));allocate(gpu_flat,size_t(count)*71);allocate(gpu_xi,size_t(count)*33);
      check(cudaMemcpyAsync(gpu_ids,ids,size_t(count)*sizeof(int),cudaMemcpyHostToDevice,s.stream));check(cudaMemcpyAsync(gpu_flat,flat,size_t(count)*71*sizeof(float),cudaMemcpyHostToDevice,s.stream));check(cudaMemcpyAsync(gpu_xi,contexts,size_t(count)*33*sizeof(float),cudaMemcpyHostToDevice,s.stream));
      reset_kernel<<<(count+127)/128,128,0,s.stream>>>(count,s.n,gpu_ids,gpu_flat,gpu_xi,s.origins,s.pose,s.velocity,s.q,s.qd,s.targets,s.xi);check(cudaGetLastError());check(cudaStreamSynchronize(s.stream));
    } catch(...){if(gpu_ids)cudaFree(gpu_ids);if(gpu_flat)cudaFree(gpu_flat);if(gpu_xi)cudaFree(gpu_xi);throw;}
    cudaFree(gpu_ids);cudaFree(gpu_flat);cudaFree(gpu_xi);
  });
}
extern "C" MR_EXPORT int mr_aligned_cuda_targets(void* p,const float* host_actions) {
  return operation([&]{auto& s=require_state(p);check(cudaSetDevice(s.device));finite_array(host_actions,size_t(s.n)*29);float* actions=nullptr;allocate(actions,size_t(s.n)*29);
    try {check(cudaMemcpyAsync(actions,host_actions,size_t(s.n)*29*sizeof(float),cudaMemcpyHostToDevice,s.stream));target_kernel<<<(s.n*29+255)/256,256,0,s.stream>>>(s.n,actions,s.default_q,s.alpha,s.xi,s.targets);check(cudaGetLastError());check(cudaStreamSynchronize(s.stream));}catch(...){cudaFree(actions);throw;}cudaFree(actions);
  });
}
extern "C" MR_EXPORT int mr_aligned_cuda_gather(void* p,float* output) {
  return operation([&]{auto& s=require_state(p);check(cudaSetDevice(s.device));if(!output)throw std::runtime_error("null state destination");float* flat=nullptr;allocate(flat,size_t(s.n)*71);
    try {gather_kernel<<<(s.n+127)/128,128,0,s.stream>>>(s.n,s.pose,s.velocity,s.q,s.qd,s.origins,flat);check(cudaGetLastError());check(cudaMemcpyAsync(output,flat,size_t(s.n)*71*sizeof(float),cudaMemcpyDeviceToHost,s.stream));check(cudaStreamSynchronize(s.stream));}catch(...){cudaFree(flat);throw;}cudaFree(flat);
  });
}
// Device arrays can be adopted only by a matching genuine solver; no such
// Newton C++ adoption API is asserted. This is an explicitly typed data boundary.
extern "C" MR_EXPORT float* mr_aligned_cuda_buffer(void* p,int kind) {
  if(!p)return nullptr;auto& s=*static_cast<State*>(p);switch(kind){case 0:return s.pose;case 1:return s.velocity;case 2:return s.q;case 3:return s.qd;case 4:return s.targets;case 5:return s.xi;case 6:return s.origins;default:return nullptr;}
}
extern "C" MR_EXPORT cudaStream_t mr_aligned_cuda_stream(void* p){return p?static_cast<State*>(p)->stream:nullptr;}
