// Pointwise tail only: the original ATen mean/center/square/mean reductions
// remain outside this kernel. No fast math, approximate reciprocal or FMA.
#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <c10/cuda/CUDAGuard.h>
#include <c10/cuda/CUDAStream.h>
#include <c10/cuda/CUDAException.h>
#include <vector>

template<typename T>
__global__ void mr_ln_tail_forward(const T* c, const T* v, const T* w,
    const T* b, T* y, int64_t n, int64_t d, T eps) {
  for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
       i += int64_t(blockDim.x) * gridDim.x) {
    T denominator = ::sqrt(v[i / d] * T(1) + eps);
    T normalized = c[i] / denominator;
    T affine = normalized * w[i % d] + b[i % d];
    // SiLU stays in its original ATen kernel (including ATen backward).
    y[i] = affine;
  }
}

template<typename T>
__global__ void mr_ln_tail_backward(const T* c, const T* v, const T* w,
    const T* b, const T* grad, T* dc, T* dd, T* dw, T* db,
    int64_t n, int64_t d, T eps) {
  for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
       i += int64_t(blockDim.x) * gridDim.x) {
    T denominator = ::sqrt(v[i / d] * T(1) + eps);
    T normalized = c[i] / denominator;
    T ga = grad[i];
    T gn = ga * w[i % d];
    dc[i] = gn / denominator;
    // Match DivBackward's -grad*((self/other)/other), including both divides.
    dd[i] = -gn * (normalized / denominator);
    if (dw) dw[i] = ga * normalized;
    if (db) db[i] = ga;
  }
}

at::Tensor mr_ln_silu_tail_cuda_forward(const at::Tensor& c,
    const at::Tensor& v, const at::Tensor& w, const at::Tensor& b, double eps) {
  c10::cuda::CUDAGuard guard(c.device());
  auto out = at::empty_like(c);
  const auto n = c.numel(), d = c.size(-1);
  const auto blocks = std::min<int64_t>((n + 255) / 256, 4096);
  AT_DISPATCH_FLOATING_TYPES(c.scalar_type(), "mr_ln_silu_tail_forward", [&] {
    mr_ln_tail_forward<scalar_t><<<blocks, 256, 0, c10::cuda::getCurrentCUDAStream()>>>(
        c.data_ptr<scalar_t>(), v.data_ptr<scalar_t>(), w.data_ptr<scalar_t>(),
        b.data_ptr<scalar_t>(), out.data_ptr<scalar_t>(), n, d, scalar_t(eps));
  });
  C10_CUDA_KERNEL_LAUNCH_CHECK();
  return out;
}

std::vector<at::Tensor> mr_ln_silu_tail_cuda_backward(const at::Tensor& c,
    const at::Tensor& v, const at::Tensor& w, const at::Tensor& b,
    const at::Tensor& grad, double eps, bool need_w, bool need_b) {
  c10::cuda::CUDAGuard guard(c.device());
  auto dc = at::empty_like(c), dd = at::empty_like(c);
  auto dw = need_w ? at::empty_like(c) : at::Tensor();
  auto db = need_b ? at::empty_like(c) : at::Tensor();
  const auto n = c.numel(), d = c.size(-1);
  const auto blocks = std::min<int64_t>((n + 255) / 256, 4096);
  AT_DISPATCH_FLOATING_TYPES(c.scalar_type(), "mr_ln_silu_tail_backward", [&] {
    mr_ln_tail_backward<scalar_t><<<blocks, 256, 0, c10::cuda::getCurrentCUDAStream()>>>(
        c.data_ptr<scalar_t>(), v.data_ptr<scalar_t>(), w.data_ptr<scalar_t>(),
        b.data_ptr<scalar_t>(), grad.data_ptr<scalar_t>(), dc.data_ptr<scalar_t>(),
        dd.data_ptr<scalar_t>(), need_w ? dw.data_ptr<scalar_t>() : nullptr,
        need_b ? db.data_ptr<scalar_t>() : nullptr,
        n, d, scalar_t(eps));
  });
  C10_CUDA_KERNEL_LAUNCH_CHECK();
  return {dc, dd, dw, db};
}
