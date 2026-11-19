#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDAStream.h>
#include <c10/cuda/CUDAException.h>

// All arithmetic here is compiled without FMA, fast math, or FTZ. Matrix
// products and reductions stay in ATen, with their original shapes and order.
struct TailStrides { int64_t row, i, j; };
static TailStrides strides(const at::Tensor& x) {return {x.stride(0),x.stride(1),x.stride(2)};}
__device__ int64_t at_index(int64_t row,int q,TailStrides s) {return row*s.row+(q/3)*s.i+(q%3)*s.j;}
template<typename T,bool Backward>
__global__ void tail_rows(const T *k,const T *kk,const T *a,const T *b,const T *g,
    T *o,T *o1,T *o2,T *o3,int64_t n,TailStrides ks,TailStrides kks,
    int64_t as,int64_t bs,TailStrides gs) {
  for(int64_t t=blockIdx.x*blockDim.x+threadIdx.x;t<n*9;t+=int64_t(blockDim.x)*gridDim.x) {
    const int64_t row=t/9;const int q=t%9;
    const T kv=k[at_index(row,q,ks)],kkv=kk[at_index(row,q,kks)],av=a[row*as],bv=b[row*bs];
    if constexpr(Backward) {
      const T gv=g[at_index(row,q,gs)];
      o[t]=gv*av;o1[t]=gv*bv;o2[t]=gv*kv;o3[t]=gv*kkv;
    } else {
      const T eye=(q==0||q==4||q==8)?T(1):T(0);
      o[t]=(eye+kv*av)+kkv*bv;
    }
  }
}
at::Tensor mr_so3_tail_cuda(const at::Tensor& k,const at::Tensor& kk,const at::Tensor& a,const at::Tensor& b) {
  c10::cuda::CUDAGuard guard(k.device());const auto n=k.size(0);
  auto o=at::empty({n,3,3},k.options());const auto blocks=std::min<int64_t>((n*9+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(k.scalar_type(),"so3_tail_forward",[&]{tail_rows<scalar_t,false><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(k.data_ptr<scalar_t>(),kk.data_ptr<scalar_t>(),a.data_ptr<scalar_t>(),b.data_ptr<scalar_t>(),nullptr,o.data_ptr<scalar_t>(),nullptr,nullptr,nullptr,n,strides(k),strides(kk),a.stride(0),b.stride(0),{});});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return o;
}
std::vector<at::Tensor> mr_so3_tail_backward_cuda(const at::Tensor& k,const at::Tensor& kk,const at::Tensor& a,const at::Tensor& b,const at::Tensor& g) {
  c10::cuda::CUDAGuard guard(k.device());const auto n=k.size(0);
  std::vector<at::Tensor> o;for(int i=0;i<4;++i)o.push_back(at::empty({n,3,3},k.options()));
  const auto blocks=std::min<int64_t>((n*9+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(k.scalar_type(),"so3_tail_backward",[&]{tail_rows<scalar_t,true><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(k.data_ptr<scalar_t>(),kk.data_ptr<scalar_t>(),a.data_ptr<scalar_t>(),b.data_ptr<scalar_t>(),g.data_ptr<scalar_t>(),o[0].data_ptr<scalar_t>(),o[1].data_ptr<scalar_t>(),o[2].data_ptr<scalar_t>(),o[3].data_ptr<scalar_t>(),n,strides(k),strides(kk),a.stride(0),b.stride(0),strides(g));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return o;
}
template<typename T>
__global__ void cross_rows(const T *a,const T *b,T *o,int64_t n,int64_t ar,int64_t ac,int64_t br,int64_t bc) {
  for(int64_t t=blockIdx.x*blockDim.x+threadIdx.x;t<n*3;t+=int64_t(blockDim.x)*gridDim.x) {
    const int64_t r=t/3;const int c=t%3,i=(c+1)%3,j=(c+2)%3;
    o[t]=a[r*ar+i*ac]*b[r*br+j*bc]-a[r*ar+j*ac]*b[r*br+i*bc];
  }
}
at::Tensor mr_cross_forward_cuda(const at::Tensor& a,const at::Tensor& b) {
  c10::cuda::CUDAGuard guard(a.device());const auto n=a.size(0);auto o=at::empty({n,3},a.options());
  const auto blocks=std::min<int64_t>((n*3+255)/256,4096);
  AT_DISPATCH_FLOATING_TYPES(a.scalar_type(),"cross_preserve_fused_forward",[&]{cross_rows<scalar_t><<<blocks,256,0,c10::cuda::getCurrentCUDAStream()>>>(a.data_ptr<scalar_t>(),b.data_ptr<scalar_t>(),o.data_ptr<scalar_t>(),n,a.stride(0),a.stride(1),b.stride(0),b.stride(1));});
  C10_CUDA_KERNEL_LAUNCH_CHECK();return o;
}
