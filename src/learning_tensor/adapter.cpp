// Explicitly loaded LibTorch plugin; no Python runtime or pybind dependency.
#include <torch/torch.h>
#if defined(MR_AOTI_ADJOINT_DIAGNOSTICS)
#include <fstream>
static void actor_diagnostic_tensor(const std::string& name,const torch::Tensor& value) {
  const char* root=std::getenv("MOONROBO_AOTI_ADJOINTS");
  if(!root)return;
  if(std::string(root)!="/pair"||value.scalar_type()!=torch::kFloat32||value.numel()>4096*1024)
    throw std::invalid_argument("bounded actor diagnostic tensor required");
  auto cpu=value.detach().cpu().contiguous();
  const auto path=std::string(root)+"/"+name+".f32";
  if(std::ifstream(path).good())throw std::invalid_argument("fresh actor diagnostic path required");
  std::ofstream file(path,std::ios::binary|std::ios::out);
  file.write(reinterpret_cast<const char*>(cpu.data_ptr<float>()),cpu.numel()*4);
  if(!file.good())throw std::runtime_error("actor diagnostic write failed");
}
#endif
#include <torch/version.h>
#include <ATen/ops/linalg_vector_norm.h>
#include <ATen/ops/_fused_adam.h>
#include <cstdio>
#include <cstdint>
#include <exception>
#include <limits>
#include <stdexcept>
#include <cstring>
#include <cmath>
#include <unordered_set>
#include <dlfcn.h>
#include <chrono>
#include <thread>
#include <climits>
#include <sstream>
#include <iomanip>
#include <locale>
#include <mutex>
#include <unordered_map>
#include <c10/core/impl/VirtualGuardImpl.h>

namespace {
// Shared across all Backend handles of this loaded plugin. This only gates the
// optional startup precision setter; it never changes math, RNG or sync policy.
std::mutex fp32_settings_mutex;
bool fp32_tensor_creation_started = false;
void seal_fp32_startup() {
  std::lock_guard<std::mutex> guard(fp32_settings_mutex);
  fp32_tensor_creation_started = true;
}
void error(char *dst, int capacity, const char *message) {
  if (dst && capacity > 0) std::snprintf(dst, capacity, "%s", message);
}
template <typename F> int status(F &&f, char *dst, int capacity) {
  try { f(); return 0; }
  catch (const std::exception &e) { error(dst, capacity, e.what()); return -1; }
  catch (...) { error(dst, capacity, "unknown LibTorch exception"); return -1; }
}
template <typename F> void *tensor(F &&f, char *dst, int capacity) {
  try { return new torch::Tensor(f()); }
  catch (const std::exception &e) { error(dst, capacity, e.what()); return nullptr; }
  catch (...) { error(dst, capacity, "unknown LibTorch exception"); return nullptr; }
}
torch::Tensor &unbox(void *p) {
  if (!p) throw std::invalid_argument("empty tensor handle");
  auto &value = *static_cast<torch::Tensor *>(p);
  if (!value.defined()) throw std::invalid_argument("undefined tensor (gradient may not exist)");
  return value;
}
torch::ScalarType dtype(int code) {
  switch (code) {
    case 0: return torch::kFloat64;
    case 1: return torch::kFloat32;
    case 2: return torch::kBFloat16;
    case 3: return torch::kInt64;
    case 4: return torch::kBool;
    default: throw std::invalid_argument("unknown tensor dtype");
  }
}
struct Adam {
  std::vector<torch::Tensor> parameters;
  std::unique_ptr<torch::optim::Adam> optimizer;
};
Adam &adam(void *p) {
  if (!p) throw std::invalid_argument("empty Adam handle");
  return *static_cast<Adam *>(p);
}
}
extern "C" int mr_tensor_abi() { return 2; }
extern "C" const char *mr_tensor_version() { return TORCH_VERSION; }
extern "C" int mr_tensor_device_count() { return static_cast<int>(torch::cuda::device_count()); }
extern "C" int64_t mr_tensor_cuda_free_bytes(int device, char *err, int cap) {
  try {
    if (device < 0 || device >= mr_tensor_device_count()) throw std::invalid_argument("invalid CUDA device for memory query");
    // Resolve the CUDA runtime already linked by this LibTorch, without CUDA
    // toolkit headers or accidentally loading a different runtime version.
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(&mr_tensor_cuda_free_bytes), &info))
      throw std::runtime_error("cannot locate tensor plugin for CUDA runtime query");
    void *module = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL);
    if (!module) throw std::runtime_error("cannot access tensor plugin dependencies");
    auto get_device = reinterpret_cast<int (*)(int *)>(dlsym(module, "cudaGetDevice"));
    auto set_device = reinterpret_cast<int (*)(int)>(dlsym(module, "cudaSetDevice"));
    auto memory_info = reinterpret_cast<int (*)(size_t *, size_t *)>(dlsym(module, "cudaMemGetInfo"));
    auto error_string = reinterpret_cast<const char *(*)(int)>(dlsym(module, "cudaGetErrorString"));
    dlclose(module);
    if (!get_device || !set_device || !memory_info || !error_string)
      throw std::runtime_error("LibTorch plugin dependencies do not expose CUDA runtime memory query");
    int prior = 0;
    auto check = [&](int code) { if (code != 0) throw std::runtime_error(error_string(code)); };
    check(get_device(&prior));
    check(set_device(device));
    size_t free_bytes = 0, total_bytes = 0;
    auto result = memory_info(&free_bytes, &total_bytes);
    auto restored = set_device(prior);
    check(result); check(restored);
    return static_cast<int64_t>(free_bytes);
  } catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" void *mr_tensor_create(const double *input, const int64_t *shape, int rank,
                                   int device, int requires_grad, int type, char *err, int cap) {
  return tensor([&] {
    if (rank < 0 || rank > 8 || device < -1 || device > std::numeric_limits<c10::DeviceIndex>::max()) throw std::invalid_argument("invalid tensor rank or device");
    int64_t count = 1;
    for (int i = 0; i < rank; ++i) {
      if (shape[i] < 0 || (shape[i] && count > INT32_MAX / shape[i]))
        throw std::invalid_argument("invalid or oversized tensor shape");
      count *= shape[i];
    }
    seal_fp32_startup();
    auto options = torch::TensorOptions().dtype(torch::kFloat64).device(torch::kCPU);
    auto cpu = torch::empty({count}, options);
    if (count && !input) throw std::invalid_argument("missing tensor values");
    auto *output = cpu.data_ptr<double>();
    for (int64_t i = 0; i < count; ++i) output[i] = input[i];
    auto result = cpu.reshape(std::vector<int64_t>(shape, shape + rank)).to(dtype(type));
    if (device >= 0) result = result.to(torch::Device(torch::kCUDA, device));
    if (requires_grad) result.set_requires_grad(true);
    return result;
  }, err, cap);
}
extern "C" void mr_tensor_destroy(void *p) { try { delete static_cast<torch::Tensor *>(p); } catch (...) {} }
extern "C" void *mr_tensor_binary(void *a, void *b, int op, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(a); auto &y = unbox(b);
    if (x.device() != y.device()) throw std::invalid_argument("tensor device mismatch");
    switch (op) {
      case 0: return x + y;
      case 1: return x - y;
      case 2: return x * y;
      case 3: return torch::matmul(x, y);
      case 4: return x / y;
      case 5: return torch::maximum(x, y);
      case 6: return torch::atan2(x, y);
      case 7: return x < y;
      case 8: return x > y;
      case 9: {
        torch::NoGradGuard guard;
        TORCH_CHECK(x.sizes() == y.sizes() && x.device() == y.device() &&
                    x.scalar_type() == y.scalar_type(), "incompatible tensor copy");
        return x.copy_(y);
      }
      default: throw std::invalid_argument("unknown binary operation");
    }
  }, err, cap);
}
extern "C" void *mr_tensor_unary(void *a, int op, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(a);
    switch (op) {
      case 0: return x.sum();
      case 1: return x.mean();
      case 2: return torch::tanh(x);
      case 3: return torch::relu(x);
      case 4: return torch::exp(x);
      case 5: return x.square();
      case 6:
        if (!x.grad().defined()) throw std::invalid_argument("gradient is undefined");
        return x.grad();
      case 7: return x.detach().clone();
      case 8: return x.transpose(-1, -2);
      case 9: return torch::sigmoid(x);
      case 10: return torch::silu(x);
      case 11: return torch::sqrt(x);
      case 12: return torch::log(x);
      case 13: return torch::elu(x);
      case 14: return x.detach();
      case 15: return torch::sin(x);
      case 16: return torch::cos(x);
      case 17: return torch::abs(x);
      case 18: return torch::acos(x);
      case 19: return at::gelu(x, "none");
      case 20: return at::softmax(x, 0);
      default: throw std::invalid_argument("unknown unary operation");
    }
  }, err, cap);
}
extern "C" int mr_tensor_backward(void *p, int retain_graph, char *err, int cap) {
  return status([&] { auto &x = unbox(p); if (x.numel() != 1) throw std::invalid_argument("backward requires scalar loss"); x.backward({}, retain_graph != 0); }, err, cap);
}
extern "C" int mr_tensor_zero_grad(void *p, char *err, int cap) {
  return status([&] { auto &x = unbox(p); if (x.grad().defined()) x.mutable_grad().zero_(); }, err, cap);
}
extern "C" int mr_tensor_rank(void *p, char *err, int cap) {
  try { return static_cast<int>(unbox(p).dim()); }
  catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" int64_t mr_tensor_dim(void *p, int axis, char *err, int cap) {
  try { auto &x = unbox(p); if (axis < 0 || axis >= x.dim()) throw std::invalid_argument("axis out of range"); return x.size(axis); }
  catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" int64_t mr_tensor_size(void *p, char *err, int cap) {
  try { return unbox(p).numel(); }
  catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" double mr_tensor_value(void *p, int64_t index, int gradient, char *err, int cap) {
  try {
    auto &x = unbox(p); auto y = gradient ? x.grad() : x;
    if (!y.defined()) throw std::invalid_argument("gradient is undefined");
    if (index < 0 || index >= y.numel()) throw std::invalid_argument("tensor index out of range");
    auto cpu = y.detach().to(torch::kCPU, torch::kFloat64).contiguous();
    return cpu.view({-1}).data_ptr<double>()[index];
  } catch (const std::exception &e) { error(err, cap, e.what()); return std::numeric_limits<double>::quiet_NaN(); }
}

// Bulk host transfer has one synchronization per tensor, never one per element.
extern "C" int mr_tensor_read(void *p, double *out, int64_t count, int gradient, char *err, int cap) {
  return status([&] {
    auto x = gradient ? unbox(p).grad() : unbox(p);
    if (!x.defined() || count != x.numel()) throw std::invalid_argument("invalid tensor read size or undefined gradient");
    auto cpu = x.detach().to(torch::kCPU, torch::kFloat64).contiguous();
    if (count) std::memcpy(out, cpu.data_ptr<double>(), count * sizeof(double));
  }, err, cap);
}
extern "C" int mr_tensor_metadata(void *p, int field, char *err, int cap) {
  try {
    auto &x = unbox(p);
    if (field == 0) return x.is_cuda() ? x.get_device() : -1;
    if (field == 1) {
      for (int i = 0; i <= 4; ++i) if (x.scalar_type() == dtype(i)) return i;
      throw std::invalid_argument("unsupported tensor dtype");
    }
    throw std::invalid_argument("unknown tensor metadata field");
  } catch (const std::exception &e) { error(err, cap, e.what()); return -2; }
}
extern "C" void *mr_tensor_shape_op(void *p, int op, const int64_t *args, int n, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(p);
    switch (op) {
      case 0: return x.reshape(std::vector<int64_t>(args, args + n));
      case 1: if (n == 3) return x.narrow(args[0], args[1], args[2]); break;
      case 2: if (n == 2) return x.transpose(args[0], args[1]); break;
      case 3: if (n == 2) return x.sum(args[0], args[1] != 0); break;
      case 4: if (n == 2) return x.mean(args[0], args[1] != 0); break;
      case 5: if (n == 2) return x.var(args[0], false, args[1] != 0); break;
      case 6: return x.new_zeros(at::IntArrayRef(args, n), x.options().requires_grad(false));
      case 7: if (n == 1) return torch::randperm(args[0], x.options().dtype(torch::kInt64).requires_grad(false)); break;
      case 9: if (n == 1) return at::multinomial(x, args[0], true); break;
      case 10: if (n == 1) return at::rand({args[0]}, x.options().requires_grad(false)); break;
      case 8: if (n == 3 && args[0] > 0 && args[1] > 0) {
        auto cpu = torch::TensorOptions().dtype(torch::kFloat32).device(torch::kCPU);
        at::Tensor p;
        if (args[2] == 0) {
          p = torch::empty({args[1], args[0]}, cpu);
          torch::nn::init::kaiming_uniform_(p, std::sqrt(5.0));
        } else if (args[2] == 1) {
          p = torch::empty({args[1]}, cpu);
          const double bound = 1.0 / std::sqrt(double(args[0]));
          p.uniform_(-bound, bound);
        } else {
          p = torch::full({args[1]}, args[2] == 2 ? 1.0 : 0.0, cpu);
        }
        return p.to(x.device()).set_requires_grad(true);
      } break;
    }
    throw std::invalid_argument("invalid tensor shape operation");
  }, err, cap);
}
extern "C" void *mr_tensor_scalar_op(void *p, int op, double a, double b, char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(p);
    if (op == 0) return x * a + b;
    if (op == 1 && a <= b) return x.clamp(a, b);
    throw std::invalid_argument("invalid tensor scalar operation");
  }, err, cap);
}
extern "C" void *mr_tensor_join(void **inputs, int n, int axis, int stack, char *err, int cap) {
  return tensor([&] {
    if (n < 1) throw std::invalid_argument("cannot join an empty tensor list");
    std::vector<torch::Tensor> values;
    for (int i = 0; i < n; ++i) values.push_back(unbox(inputs[i]));
    auto result=stack ? torch::stack(values, axis) : torch::cat(values, axis);
#if defined(MR_AOTI_ADJOINT_DIAGNOSTICS)
    if(std::getenv("MOONROBO_AOTI_ADJOINTS")&&n==2&&!stack&&result.requires_grad()&&
       result.sizes()==torch::IntArrayRef({4096,914})) {
      actor_diagnostic_tensor("tail-features",result);
      result.register_hook([](const torch::Tensor& g){actor_diagnostic_tensor("tail-features-vjp",g);return g;});
    }
#endif
    return result;
  }, err, cap);
}
extern "C" void *mr_tensor_index_select(void *p, void *indices, int axis, char *err, int cap) {
  return tensor([&] { return unbox(p).index_select(axis, unbox(indices)); }, err, cap);
}
extern "C" void *mr_tensor_pullback(void *output, void *input, void *cotangent, int retain_graph, char *err, int cap) {
  return tensor([&] {
    return torch::autograd::grad({unbox(output)}, {unbox(input)}, {unbox(cotangent)}, retain_graph != 0, false, false)[0];
  }, err, cap);
}
extern "C" void *mr_tensor_where(void *condition, void *yes, void *no, char *err, int cap) {
  return tensor([&] { return torch::where(unbox(condition), unbox(yes), unbox(no)); }, err, cap);
}
extern "C" void *mr_adam_create(void **inputs, int n, double lr, double beta1, double beta2, double eps, char *err, int cap) {
  try {
    if (n < 1 || !std::isfinite(lr) || !std::isfinite(eps) || lr <= 0 || eps <= 0 ||
        !(beta1 >= 0 && beta1 < 1) || !(beta2 >= 0 && beta2 < 1))
      throw std::invalid_argument("invalid Adam parameters or hyperparameters");
    auto result = std::make_unique<Adam>();
    std::unordered_set<void *> seen;
    for (int i = 0; i < n; ++i) {
      auto &p = unbox(inputs[i]);
      if (!p.is_leaf() || !p.requires_grad() || !p.is_floating_point() || !seen.insert(p.unsafeGetTensorImpl()).second)
        throw std::invalid_argument("Adam needs distinct floating-point leaf parameters requiring gradients");
      if (i && (p.device() != result->parameters[0].device() || p.scalar_type() != result->parameters[0].scalar_type()))
        throw std::invalid_argument("Adam parameter device/dtype mismatch");
      result->parameters.push_back(p);
    }
    result->optimizer = std::make_unique<torch::optim::Adam>(result->parameters, torch::optim::AdamOptions(lr).betas({beta1, beta2}).eps(eps));
    return result.release();
  } catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" void mr_adam_destroy(void *p) { delete static_cast<Adam *>(p); }
extern "C" int mr_adam_step(void *p, double max_norm, double max_value, char *err, int cap) {
  return status([&] {
    auto &a = adam(p);
    if (!std::isfinite(max_norm) || max_norm < 0 || !std::isfinite(max_value) || max_value < 0) throw std::invalid_argument("invalid gradient clipping limit");
    std::vector<torch::Tensor> finite;
    for (auto &parameter : a.parameters) {
      if (!parameter.grad().defined()) throw std::invalid_argument("missing Adam gradient; no parameters updated");
      finite.push_back(torch::isfinite(parameter.grad()).all());
    }
    if (!torch::stack(finite).all().item<bool>())
      throw std::invalid_argument("nonfinite Adam gradient; no parameters updated");
    if (max_norm > 0) torch::nn::utils::clip_grad_norm_(a.parameters, max_norm, 2, true);
    if (max_value > 0) torch::nn::utils::clip_grad_value_(a.parameters, max_value);
    a.optimizer->step();
  }, err, cap);
}
extern "C" int mr_adam_zero_grad(void *p, char *err, int cap) {
  return status([&] { adam(p).optimizer->zero_grad(); }, err, cap);
}

// Single dense interior Linear weight, following torch.optim.Muon 2.10.0
// with adjust_lr_fn="match_rms_adamw". Momentum stays in parameter dtype.
extern "C" int mr_muon_update_v1(void *parameter, void *momentum, double lr,
                                 char *err, int cap) {
  return status([&] {
    torch::NoGradGuard guard;
    auto &p = unbox(parameter);
    auto &buf = unbox(momentum);
    auto grad = p.grad();
    TORCH_CHECK(lr > 0 && std::isfinite(lr) && p.dim() == 2 && grad.defined() &&
                p.sizes() == buf.sizes() && p.device() == buf.device() &&
                p.scalar_type() == buf.scalar_type(), "invalid Muon matrix or buffer");
    buf.lerp_(grad, 1.0 - 0.95);
    auto x = grad.lerp(buf, 0.95).to(at::kBFloat16);
    bool transposed = p.size(0) > p.size(1);
    if (transposed) x = x.t();
    x.div_(x.norm().clamp_min(1e-7));
    for (int step = 0; step < 5; ++step) {
      auto gram = x.matmul(x.t());
      auto correction = at::addmm(gram, gram, gram, -4.775, 2.0315);
      x = at::addmm(x, correction, x, 3.4445);
    }
    if (transposed) x = x.t();
    double scale = 0.2 * std::sqrt(double(std::max(p.size(0), p.size(1))));
    p.mul_(1.0 - lr * 0.1).add_(x, -lr * scale);
  }, err, cap);
}
extern "C" int mr_adam_learning_rate(void *p, double lr, char *err, int cap) {
  return status([&] {
    if (!std::isfinite(lr) || lr <= 0) throw std::invalid_argument("invalid Adam learning rate");
    for (auto &group : adam(p).optimizer->param_groups()) static_cast<torch::optim::AdamOptions &>(group.options()).lr(lr);
  }, err, cap);
}
// Parameter ordering is the checkpoint contract. RNG/replay/normalizers belong
// to the enclosing learner checkpoint and are deliberately not claimed here.
extern "C" int mr_adam_checkpoint(void *p, const char *path, int load, char *err, int cap) {
  return status([&] {
    auto &a = adam(p);
    if (!path || !*path) throw std::invalid_argument("empty checkpoint path");
    if (!load) {
      torch::serialize::OutputArchive archive, optimizer;
      archive.write("count", c10::IValue(static_cast<int64_t>(a.parameters.size())));
      for (size_t i = 0; i < a.parameters.size(); ++i) archive.write("parameter_" + std::to_string(i), a.parameters[i]);
      a.optimizer->save(optimizer); archive.write("adam", optimizer);
      std::string pending = std::string(path) + ".partial";
      archive.save_to(pending);
      if (std::rename(pending.c_str(), path) != 0) throw std::runtime_error("checkpoint rename failed");
    } else {
      torch::serialize::InputArchive archive, optimizer;
      archive.load_from(path, a.parameters[0].device());
      c10::IValue count; archive.read("count", count);
      if (count.toInt() != static_cast<int64_t>(a.parameters.size())) throw std::invalid_argument("checkpoint parameter count mismatch");
      std::vector<torch::Tensor> restored(a.parameters.size());
      for (size_t i = 0; i < restored.size(); ++i) {
        archive.read("parameter_" + std::to_string(i), restored[i]);
        if (restored[i].sizes() != a.parameters[i].sizes() || restored[i].scalar_type() != a.parameters[i].scalar_type())
          throw std::invalid_argument("checkpoint parameter shape/dtype mismatch");
      }
      auto replacement = std::make_unique<torch::optim::Adam>(a.parameters);
      archive.read("adam", optimizer); replacement->load(optimizer);
      torch::NoGradGuard guard;
      for (size_t i = 0; i < restored.size(); ++i) a.parameters[i].copy_(restored[i]);
      a.optimizer = std::move(replacement);
      a.optimizer->zero_grad();
    }
  }, err, cap);
}

// Pointer IDs in Torch's archive representation are process-local. Expose
// semantic optimizer state in fixed parameter order for bounded external audits.
extern "C" int mr_adam_audit_metadata(void *p, char *output, int capacity, char *err, int cap) {
  return status([&] {
    auto &a = adam(p);
    if (!output || capacity < 1 || a.parameters.size() > 16384)
      throw std::invalid_argument("invalid or oversized optimizer audit metadata");
    std::unordered_map<void *, size_t> positions;
    for (size_t i = 0; i < a.parameters.size(); ++i)
      positions.emplace(a.parameters[i].unsafeGetTensorImpl(), i);
    for (const auto &entry : a.optimizer->state())
      if (!positions.count(entry.first)) throw std::runtime_error("optimizer state has an unrecognized parameter");
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "{\"parameter_count\":" << a.parameters.size() << ",\"states\":[";
    for (size_t i = 0; i < a.parameters.size(); ++i) {
      if (i) out << ',';
      auto found = a.optimizer->state().find(a.parameters[i].unsafeGetTensorImpl());
      if (found == a.optimizer->state().end()) out << "{\"present\":false,\"step\":\"0\"}";
      else {
        auto &state = static_cast<const torch::optim::AdamParamState &>(*found->second);
        out << "{\"present\":true,\"step\":\"" << state.step() << "\"}";
      }
    }
    out << "],\"groups\":[";
    size_t group_index = 0;
    for (const auto &group : a.optimizer->param_groups()) {
      if (group_index++) out << ',';
      const auto &options = static_cast<const torch::optim::AdamOptions &>(group.options());
      auto betas = options.betas();
      for (double v : {options.lr(), std::get<0>(betas), std::get<1>(betas), options.eps(), options.weight_decay()})
        if (!std::isfinite(v)) throw std::runtime_error("optimizer audit encountered nonfinite hyperparameter");
      out << "{\"indices\":[";
      size_t parameter_index = 0;
      for (const auto &parameter : group.params()) {
        if (parameter_index++) out << ',';
        auto position = positions.find(parameter.unsafeGetTensorImpl());
        if (position == positions.end()) throw std::runtime_error("optimizer group has an unrecognized parameter");
        out << position->second;
      }
      out << "],\"learning_rate\":" << options.lr()
          << ",\"beta1\":" << std::get<0>(betas) << ",\"beta2\":" << std::get<1>(betas)
          << ",\"eps\":" << options.eps() << ",\"weight_decay\":" << options.weight_decay()
          << ",\"amsgrad\":" << (options.amsgrad() ? "true" : "false") << '}';
    }
    out << "]}";
    const auto text = out.str();
    if (text.size() >= static_cast<size_t>(capacity)) throw std::runtime_error("optimizer audit metadata exceeds bound");
    std::memcpy(output, text.c_str(), text.size() + 1);
  }, err, cap);
}
extern "C" void *mr_adam_audit_tensor(void *p, int index, int kind, char *err, int cap) {
  return tensor([&] {
    auto &a = adam(p);
    if (index < 0 || static_cast<size_t>(index) >= a.parameters.size() || kind < 0 || kind > 3)
      throw std::invalid_argument("invalid optimizer audit parameter or tensor kind");
    auto &parameter = a.parameters[index];
    if (kind == 0) return parameter.detach();
    auto found = a.optimizer->state().find(parameter.unsafeGetTensorImpl());
    if (found == a.optimizer->state().end()) throw std::runtime_error("optimizer audit parameter has no state");
    auto &state = static_cast<const torch::optim::AdamParamState &>(*found->second);
    auto value = kind == 1 ? state.exp_avg() : kind == 2 ? state.exp_avg_sq() : state.max_exp_avg_sq();
    if (!value.defined()) throw std::runtime_error("optimizer audit moment is not defined");
    return value.detach();
  }, err, cap);
}

#include "collective.inc"
#include "telemetry.inc"
#include "tf32.inc"
#include "layer_norm.inc"
#include "fk_submitted.inc"
#include "ln_silu_tail.inc"
#include "profiling.inc"
#include "graph.inc"
#include "precision.inc"
#include "adam_checked_norm.inc"
#include "adam_smc.inc"
#include "operator_diagnostics.inc"
#include "smc_algebra.inc"
#include "native_cross.inc"
#include "compact_rotation.inc"
#include "fused_rotation.inc"
#include "geometry_tail.inc"
#include "geometry_vjp.inc"
#include "compact_heading.inc"
#include "split_sections.inc"
#include "compiled_block.inc"

// Single non-Adam tensor (Muon state or empirical moments). Keep transient
// restore allocations bounded by the largest tensor in this group.
extern "C" int mr_tensor_checkpoint_v1(void *ptr, const char *path, int load, char *err, int cap) {
  return status([&] {
    torch::NoGradGuard no_grad;
    auto &t = unbox(ptr);
    if (load) {
      torch::serialize::InputArchive archive;
      archive.load_from(path, t.device());
      torch::Tensor restored;
      archive.read("tensor", restored);
      TORCH_CHECK(t.sizes() == restored.sizes() && t.scalar_type() == restored.scalar_type(),
                  "checkpoint tensor shape or dtype mismatch");
      t.copy_(restored);
    } else {
      torch::serialize::OutputArchive archive;
      archive.write("tensor", t.detach());
      std::string tmp = std::string(path) + ".partial";
      archive.save_to(tmp);
      TORCH_CHECK(std::rename(tmp.c_str(), path) == 0, "checkpoint publish failed");
    }
  }, err, cap);
}

// The author's fused Adam update, sharing C++ Adam's serializable moments.
extern "C" int mr_adam_author_v1(void *ptr, void **all, int len, double clip, char *err, int cap) {
  return status([&] {
    auto &a = adam(ptr);
    torch::NoGradGuard guard;
    std::vector<torch::Tensor> grads, adam_grads, first, second, steps;
    for (int i=0; i<len; ++i) grads.push_back(unbox(all[i]).grad());
    auto norm = at::stack(at::_foreach_norm(grads, 2)).norm();
    TORCH_CHECK(std::isfinite(norm.item<double>()), "nonfinite GenCoord gradient norm");
    at::_foreach_mul_(grads, (1.0 / (norm + 1e-6)).clamp_max(1.0));
    if (clip > 0) {
      at::_foreach_clamp_min_(grads, -clip);
      at::_foreach_clamp_max_(grads, clip);
    }
    auto &states = a.optimizer->state();
    const auto &options = static_cast<const torch::optim::AdamOptions&>(a.optimizer->param_groups().at(0).options());
    const auto device_opts = a.parameters[0].options().requires_grad(false);
    // All active parameters in these dense MLPs step together.
    torch::Tensor counter;
    for (auto &p : a.parameters) {
      auto key = p.unsafeGetTensorImpl();
      if (!states.count(key)) {
        auto state = std::make_unique<torch::optim::AdamParamState>();
        state->exp_avg(torch::zeros_like(p));
        state->exp_avg_sq(torch::zeros_like(p));
        states[key] = std::move(state);
      }
      auto &st = static_cast<torch::optim::AdamParamState&>(*states.at(key));
      st.step(st.step()+1);
      if (!counter.defined()) counter = torch::full({}, double(st.step()), device_opts);
      adam_grads.push_back(p.grad());
      first.push_back(st.exp_avg()); second.push_back(st.exp_avg_sq()); steps.push_back(counter);
    }
    auto betas = options.betas();
    auto lr = torch::full({}, options.lr(), device_opts);
    at::_fused_adam_(a.parameters, adam_grads, first, second, {}, steps, lr,
                     std::get<0>(betas), std::get<1>(betas), 0, options.eps(), false, false);
  }, err, cap);
}

extern "C" void *mr_tensor_group_sum_v1(void *values, void *indices, int groups,
                                        char *err, int cap) {
  return tensor([&] {
    auto &x = unbox(values);
    auto &idx = unbox(indices);
    TORCH_CHECK(groups > 0 && x.dim() == 1 && idx.sizes() == x.sizes() &&
                idx.scalar_type() == at::kLong && x.device() == idx.device(),
                "invalid grouped sum inputs");
    return x.new_zeros({groups}).scatter_add_(0, idx, x);
  }, err, cap);
}
