#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDAStream.h>
#include <c10/cuda/CUDAException.h>

// Compiled without FMA, fast math, approximate division/sqrt or FTZ.
// Strides are explicit: state matrices and incoming gradients can be views.
template<typename T, bool Backward>
__global__ void heading_rows(const T *r,const T *g,T *out,int64_t b,
    int64_t r0,int64_t r1,int64_t r2,int64_t g0,int64_t g1,int64_t g2) {
  for(int64_t i=blockIdx.x*blockDim.x+threadIdx.x;i<b;i+=int64_t(blockDim.x)*gridDim.x) {
    const T x=r[i*r0], y=r[i*r0+r1];
    const T n=::sqrt((x*x+y*y)*T(1)+T(1e-9));
    T *o=out+i*9;
    if constexpr(!Backward) {
      const T c=x/n, s=y/n, z=c*T(0)+T(0);
      o[0]=c;o[1]=s*T(-1)+T(0);o[2]=z;o[3]=s;o[4]=c;
      o[5]=z;o[6]=z;o[7]=z;o[8]=z*T(0)+T(1);
    } else {
      const T gc=g[i*g0]+g[i*g0+g1+g2];
      const T gs=g[i*g0+g1]+g[i*g0+g2]*T(-1);
      const T gn=(-gs*((y/n)/n))+(-gc*((x/n)/n));
      const T ds=gn/(n*T(2))*T(1);
      for(int j=0;j<9;++j)o[j]=T(0);
      o[0]=ds*T(2)*x+gc/n; o[3]=ds*T(2)*y+gs/n;
    }
  }
}
at::Tensor mr_heading_cuda(const at::Tensor& r,const at::Tensor& g,bool backward) {
  c10::cuda::CUDAGuard guard(r.device());
  auto out=at::empty(r.sizes(),r.options());
  const auto rows=r.size(0), blocks=std::min<int64_t>((rows+255)/256,1024);
  AT_DISPATCH_FLOATING_TYPES(r.scalar_type(),"compact_heading",[&]{
    if(backward) heading_rows<scalar_t,true><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(
      r.data_ptr<scalar_t>(),g.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),rows,
      r.stride(0),r.stride(1),r.stride(2),g.stride(0),g.stride(1),g.stride(2));
    else heading_rows<scalar_t,false><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(
      r.data_ptr<scalar_t>(),nullptr,out.data_ptr<scalar_t>(),rows,
      r.stride(0),r.stride(1),r.stride(2),0,0,0);
  });
  C10_CUDA_KERNEL_LAUNCH_CHECK();return out;
}
