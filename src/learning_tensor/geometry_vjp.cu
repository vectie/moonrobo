#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDAStream.h>
#include <c10/cuda/CUDAException.h>
#include <cmath>

// Explicit contraction matches the CUDA ATen cross expression. All other
// arithmetic is compiled with --fmad=false, precise division/sqrt and no FTZ.
template<typename T> __device__ T cross_component(T a,T b,T c,T d);
template<> __device__ float cross_component(float a,float b,float c,float d) {return __fmaf_rn(a,b,-__fmul_rn(c,d));}
template<> __device__ double cross_component(double a,double b,double c,double d) {return __fma_rn(a,b,-__dmul_rn(c,d));}
template<typename T> __global__ void cross_vjp(const T *a,const T *b,const T *g,T *ga,T *gb,
    int64_t n,int64_t ar,int64_t ac,int64_t br,int64_t bc,int64_t gr,int64_t gc) {
  for(int64_t r=blockIdx.x*blockDim.x+threadIdx.x;r<n;r+=int64_t(blockDim.x)*gridDim.x) {
    for(int c=0;c<3;++c) {int i=(c+1)%3,j=(c+2)%3;
      ga[r*3+c]=cross_component(b[r*br+i*bc],g[r*gr+j*gc],b[r*br+j*bc],g[r*gr+i*gc]);
      gb[r*3+c]=cross_component(g[r*gr+i*gc],a[r*ar+j*ac],g[r*gr+j*gc],a[r*ar+i*ac]);
    }
  }
}
std::vector<at::Tensor> mr_cross_vjp_cuda(const at::Tensor& a,const at::Tensor& b,const at::Tensor& g) {
  c10::cuda::CUDAGuard guard(a.device());auto n=a.size(0);
  auto ga=at::empty({n,3},a.options()),gb=at::empty({n,3},b.options());
  auto blocks=std::min<int64_t>((n+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(a.scalar_type(),"cross_joint_vjp",[&]{cross_vjp<scalar_t><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(a.data_ptr<scalar_t>(),b.data_ptr<scalar_t>(),g.data_ptr<scalar_t>(),ga.data_ptr<scalar_t>(),gb.data_ptr<scalar_t>(),n,a.stride(0),a.stride(1),b.stride(0),b.stride(1),g.stride(0),g.stride(1));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return {ga,gb};
}
template<typename T> __global__ void coeff_vjp(const T *t2,const T *theta,const T *sine,const T *cosine,const T *g,T *out,
    int64_t n,int64_t xr,int64_t tr,int64_t sr,int64_t cr,int64_t gr,int64_t gc) {
  for(int64_t r=blockIdx.x*blockDim.x+threadIdx.x;r<n;r+=int64_t(blockDim.x)*gridDim.x) {
    T x=t2[r*xr],t=theta[r*tr],s=sine[r*sr],c=cosine[r*cr],ga=g[r*gr],gb=g[r*gr+gc];
    bool small=x<T(1e-8);T al=small?T(0):ga,bl=small?T(0):gb,d=x+T(1e-12);
    T td=((bl/d)*T(-1))*(-s);
    td=td+(-al)*((s/t)/t);
    td=td+(al/t)*c;
    T direct=(-bl)*(((c*T(-1)+T(1))/d)/d);
    direct=direct+(small?gb:T(0))*T(-1.0/24.0);
    direct=direct+(small?ga:T(0))*T(-1.0/6.0);
    out[r]=direct+td/(t*T(2));
  }
}
at::Tensor mr_so3_coeff_vjp_cuda(const at::Tensor& x,const at::Tensor& t,const at::Tensor& s,const at::Tensor& c,const at::Tensor& g) {
  c10::cuda::CUDAGuard guard(x.device());auto n=x.size(0);auto out=at::empty({n,1},x.options());
  auto blocks=std::min<int64_t>((n+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(x.scalar_type(),"so3_coefficient_vjp",[&]{coeff_vjp<scalar_t><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(x.data_ptr<scalar_t>(),t.data_ptr<scalar_t>(),s.data_ptr<scalar_t>(),c.data_ptr<scalar_t>(),g.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,x.stride(0),t.stride(0),s.stride(0),c.stride(0),g.stride(0),g.stride(1));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return out;
}
// Same rounded operations and branch as the old ATen forward. Trigonometry
// and sqrt remain in ATen so this candidate does not change their algorithms.
template<typename T> __global__ void coeff_forward(const T *x,const T *t,const T *s,const T *c,T *out,
    int64_t n,int64_t xr,int64_t tr,int64_t sr,int64_t cr) {
  for(int64_t r=blockIdx.x*blockDim.x+threadIdx.x;r<n;r+=int64_t(blockDim.x)*gridDim.x) {
    T v=x[r*xr],theta=t[r*tr];bool small=v<(v*T(0)+T(1e-8));
    out[r*2]=small?v*T(-1.0/6.0)+T(1):s[r*sr]/theta;
    out[r*2+1]=small?v*T(-1.0/24.0)+T(.5):(c[r*cr]*T(-1)+T(1))/(v+T(1e-12));
  }
}
at::Tensor mr_so3_coeff_forward_cuda(const at::Tensor& x,const at::Tensor& t,const at::Tensor& s,const at::Tensor& c) {
  c10::cuda::CUDAGuard guard(x.device());auto n=x.size(0);auto out=at::empty({n,2},x.options());
  auto blocks=std::min<int64_t>((n+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(x.scalar_type(),"so3_coefficient_forward",[&]{coeff_forward<scalar_t><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(x.data_ptr<scalar_t>(),t.data_ptr<scalar_t>(),s.data_ptr<scalar_t>(),c.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,x.stride(0),t.stride(0),s.stride(0),c.stride(0));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return out;
}

// Same scalar dtype, operation order and libdevice functions as ATen's unary
// kernels. No combined sincos intrinsic, fast math, contraction or reassociation.
template<typename T> __global__ void coeff_full_forward(const T *x,T *t,T *s,T *c,T *out,int64_t n,int64_t xr) {
  for(int64_t r=blockIdx.x*blockDim.x+threadIdx.x;r<n;r+=int64_t(blockDim.x)*gridDim.x) {
    T v=x[r*xr],d=v+T(1e-12),theta=std::sqrt(d);
    T sine=std::sin(theta),cosine=std::cos(theta);
    bool small=v<(v*T(0)+T(1e-8));
    t[r]=theta;s[r]=sine;c[r]=cosine;
    out[r*2]=small?v*T(-1.0/6.0)+T(1):sine/theta;
    out[r*2+1]=small?v*T(-1.0/24.0)+T(.5):(cosine*T(-1)+T(1))/d;
  }
}
std::vector<at::Tensor> mr_so3_coeff_full_forward_cuda(const at::Tensor& x) {
  c10::cuda::CUDAGuard guard(x.device());auto n=x.size(0);
  auto t=at::empty({n,1},x.options()),s=at::empty_like(t),c=at::empty_like(t),out=at::empty({n,2},x.options());
  auto blocks=std::min<int64_t>((n+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(x.scalar_type(),"so3_coefficient_full_forward",[&]{coeff_full_forward<scalar_t><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(x.data_ptr<scalar_t>(),t.data_ptr<scalar_t>(),s.data_ptr<scalar_t>(),c.data_ptr<scalar_t>(),out.data_ptr<scalar_t>(),n,x.stride(0));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return {t,s,c,out};
}
