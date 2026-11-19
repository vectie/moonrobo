#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDAStream.h>
#include <c10/cuda/CUDAException.h>

// Keep ATen's sin/cos and their saved values. Only the row-local assembly/VJP
// are fused. Compile without FMA, fast math or flush-to-zero.
template<typename T, bool Backward>
__global__ void axis_rows(const T *c,const T *s,const T *g,T *o,int64_t n,
    int64_t cs,int64_t ss,int64_t g0,int64_t g1,int64_t g2,int axis,T sign) {
  for(int64_t b=blockIdx.x*blockDim.x+threadIdx.x;b<n;b+=int64_t(blockDim.x)*gridDim.x) {
    const T cv=c[b*cs],sv=s[b*ss]; const int i=(axis+1)%3,j=(axis+2)%3;
    if constexpr(Backward) {
      const T dc=g[b*g0+i*g1+i*g2]+g[b*g0+j*g1+j*g2];
      const T ds=(g[b*g0+j*g1+i*g2]-g[b*g0+i*g1+j*g2])*sign;
      o[b]=dc*(-sv)+ds*cv;
    } else {
      const T k=cv*T(-1)+T(1),z=k*T(0)+T(0),d=z+cv;
      T *r=o+b*9; for(int q=0;q<9;++q)r[q]=z;
      r[0]=d;r[4]=d;r[8]=d;r[axis*3+axis]=(k*T(1)+T(0))+cv;
      const T v=sv*sign+T(0);r[j*3+i]=z+v;r[i*3+j]=z-v;
    }
  }
}
at::Tensor mr_axis_cuda(const at::Tensor& c,const at::Tensor& s,const at::Tensor& g,int axis,double sign,bool backward) {
  c10::cuda::CUDAGuard guard(c.device()); const auto n=c.size(0);
  auto out=at::empty(backward?std::vector<int64_t>{n,1}:std::vector<int64_t>{n,3,3},c.options());
  auto blocks=std::min<int64_t>((n+255)/256,1024);
  AT_DISPATCH_FLOATING_TYPES(c.scalar_type(),"fused_axis",[&]{
    if(backward) axis_rows<scalar_t,true><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(c.data_ptr<scalar_t>(),s.data_ptr<scalar_t>(),g.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,c.stride(0),s.stride(0),g.stride(0),g.stride(1),g.stride(2),axis,scalar_t(sign));
    else axis_rows<scalar_t,false><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(c.data_ptr<scalar_t>(),s.data_ptr<scalar_t>(),nullptr,out.data_ptr<scalar_t>(),n,c.stride(0),s.stride(0),0,0,0,axis,scalar_t(sign));
  }); C10_CUDA_KERNEL_LAUNCH_CHECK();return out;
}

template<typename T,bool Backward>
__global__ void skew_rows(const T *v,T *o,int64_t n,int64_t s0,int64_t s1,int64_t s2) {
  for(int64_t b=blockIdx.x*blockDim.x+threadIdx.x;b<n;b+=int64_t(blockDim.x)*gridDim.x) {
    const T *p=v+b*s0;
    if constexpr(Backward) {
      o[b*3]=p[2*s1+s2]-p[s1+2*s2];
      o[b*3+1]=p[2*s2]-p[2*s1];
      o[b*3+2]=p[s1]-p[s2];
    } else {
      const T x=p[0],y=p[s1],z=p[2*s1],zero=x*T(0)+T(0);T *r=o+b*9;
      r[0]=zero;r[1]=z*T(-1)+T(0);r[2]=y;r[3]=z;r[4]=zero;
      r[5]=x*T(-1)+T(0);r[6]=y*T(-1)+T(0);r[7]=x;r[8]=zero;
    }
  }
}
at::Tensor mr_skew_cuda(const at::Tensor& v,bool backward) {
  c10::cuda::CUDAGuard guard(v.device());const auto n=v.size(0);
  auto out=at::empty(backward?std::vector<int64_t>{n,3}:std::vector<int64_t>{n,3,3},v.options());
  auto blocks=std::min<int64_t>((n+255)/256,1024);
  AT_DISPATCH_FLOATING_TYPES(v.scalar_type(),"fused_skew",[&]{
    if(backward)skew_rows<scalar_t,true><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(v.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,v.stride(0),v.stride(1),v.stride(2));
    else skew_rows<scalar_t,false><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(v.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,v.stride(0),v.stride(1),0);
  });C10_CUDA_KERNEL_LAUNCH_CHECK();return out;
}
