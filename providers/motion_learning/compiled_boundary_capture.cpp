// Numerical-only AOTI shim interception. Never preload for a timed run.
// Preserve the generated program and kernels; copy values only after each call.
#include <ATen/ATen.h>
#include <torch/library.h>
#include <dlfcn.h>
#include <sstream>
#include <vector>
#include <map>

namespace {
using Handle = void*;
using Matmul = int32_t (*)(Handle, Handle, Handle);
thread_local bool recording = false;
thread_local std::vector<at::Tensor> values;
thread_local std::vector<std::string> metadata;
thread_local int64_t bytes = 0;
thread_local bool intervening = false;
thread_local int64_t position = 0, replaced = 0;
thread_local std::map<int64_t, std::vector<int64_t>> padding;

Matmul original(const char* symbol) {
  // Resolve against the actual CUDA library, never RTLD_DEFAULT (ourselves).
  static void* library = dlopen("libtorch_cuda.so", RTLD_LAZY | RTLD_NOLOAD);
  TORCH_CHECK(library, "CUDA shim library must already be loaded");
  auto fn = reinterpret_cast<Matmul>(dlsym(library, symbol));
  TORCH_CHECK(fn, "missing original AOTI shim: ", symbol);
  return fn;
}
int32_t call(Matmul fn, Handle out, Handle a, Handle b) {
  if (!intervening) return fn(out, a, b);
  auto it = padding.find(position++);
  if (it == padding.end()) return fn(out, a, b);
  const auto& spec = it->second;
  const int64_t rank = spec.at(0);
  TORCH_CHECK((rank == 2 || rank == 3) && spec.size() == 1 + 6*rank, "padding spec");
  std::vector<at::Tensor> tmp;
  int64_t offset = 1;
  for (auto h : {a, b, out}) {
    const auto& t = *static_cast<at::Tensor*>(h);
    std::vector<int64_t> sizes(spec.begin()+offset, spec.begin()+offset+rank);
    offset += rank;
    std::vector<int64_t> strides(spec.begin()+offset, spec.begin()+offset+rank);
    offset += rank;
    TORCH_CHECK(t.dim() == rank, "padding rank");
    auto padded = at::empty_strided(sizes, strides, t.options());
    TORCH_CHECK(padded.numel() <= 4194304, "padding bound");
    if (tmp.size() < 2) {
      padded.zero_(); auto logical = padded;
      for (int64_t i=0;i<rank;++i) {
        TORCH_CHECK(sizes[i] >= t.size(i) && sizes[i] <= t.size(i)+7, "padding shape");
        logical = logical.narrow(i, 0, t.size(i));
      }
      logical.copy_(t);
    }
    tmp.push_back(std::move(padded));
  }
  auto code = fn(&tmp[2], &tmp[0], &tmp[1]);
  if (!code) {
    auto& dst = *static_cast<at::Tensor*>(out);
    auto logical = tmp[2];
    for (int64_t i=0;i<rank;++i) logical = logical.narrow(i,0,dst.size(i));
    dst.copy_(logical); ++replaced;
  }
  return code;
}
void configure(std::vector<std::vector<int64_t>> specs) {
  TORCH_CHECK(!recording && !intervening && specs.size() <= 64, "intervention state");
  padding.clear(); position = replaced = 0;
  for (auto& spec : specs) {
    TORCH_CHECK(!spec.empty() && spec[0]>=0 && spec[0]<512, "intervention index");
    auto index = spec[0]; spec.erase(spec.begin());
    TORCH_CHECK(padding.emplace(index, std::move(spec)).second, "duplicate index");
  }
  intervening = true;
}
std::tuple<int64_t,int64_t> finish() {
  intervening = false;
  TORCH_CHECK(replaced == static_cast<int64_t>(padding.size()), "incomplete intervention");
  padding.clear(); return {position,replaced};
}
void snapshot(const char* kind, Handle out, Handle a, Handle b) {
  if (!recording) return;
  TORCH_CHECK(metadata.size() < 512, "numerical capture call bound");
  std::ostringstream m;
  m << "{\"kind\":\"" << kind << "\",\"tensors\":[";
  int index = 0;
  for (auto h : {a, b, out}) {
    // AOTI's AtenTensorHandle is an opaque owning pointer to an at::Tensor.
    const auto& t = *static_cast<at::Tensor*>(h);
    TORCH_CHECK(t.defined() && t.is_cuda() && t.numel() <= 4194304,
                "invalid/big numerical capture tensor");
    bytes += t.numel() * t.element_size();
    TORCH_CHECK(bytes <= 3LL * 1024 * 1024 * 1024, "3 GiB capture bound");
    if (index++) m << ',';
    m << "{\"shape\":" << t.sizes() << ",\"stride\":" << t.strides()
      << ",\"dtype\":" << static_cast<int>(t.scalar_type()) << '}';
    values.push_back(t.detach().to(at::kCPU).contiguous());
  }
  m << "]}";
  metadata.push_back(m.str());
}
void begin() {
  TORCH_CHECK(!recording && values.empty(), "capture must be consumed first");
  bytes = 0; metadata.clear(); recording = true;
}
std::tuple<std::vector<at::Tensor>, std::string> take() {
  recording = false;
  std::ostringstream m; m << '[';
  for (size_t i = 0; i < metadata.size(); ++i) { if (i) m << ','; m << metadata[i]; }
  m << ']'; metadata.clear();
  std::vector<at::Tensor> result; result.swap(values);
  return {std::move(result), m.str()};
}
}

extern "C" int32_t aoti_torch_cuda_mm_out(Handle out, Handle a, Handle b) {
  static Matmul fn = original("aoti_torch_cuda_mm_out");
  auto code = call(fn, out, a, b);
  if (!code) snapshot("mm", out, a, b);
  return code;
}
extern "C" int32_t aoti_torch_cuda_bmm_out(Handle out, Handle a, Handle b) {
  static Matmul fn = original("aoti_torch_cuda_bmm_out");
  auto code = call(fn, out, a, b);
  if (!code) snapshot("bmm", out, a, b);
  return code;
}
TORCH_LIBRARY(moonrobo_boundary, m) {
  m.def("begin() -> ()", &begin);
  m.def("take() -> (Tensor[], str)", &take);
  m.def("configure(int[][] specs) -> ()", &configure);
  m.def("finish() -> (int, int)", &finish);
}
