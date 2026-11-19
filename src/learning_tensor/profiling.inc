// Optional ABI-2 extension. Include after adapter.cpp's shared error helpers.
#include <c10/core/Event.h>
#include <c10/core/DeviceGuard.h>
#include <vector>

// NVTX 3 is header-only. Enable only for an explicitly opted-in build whose
// matching header tree is present. CPU/older builds retain the optional NVTX 2
// lookup below; missing NVTX never prevents CUDA event profiling.
#if defined(MR_ENABLE_NVTX3) && MR_ENABLE_NVTX3 && defined(__has_include)
#if __has_include(<nvtx3/nvToolsExt.h>) && !defined(NVTX_DISABLE)
#if !defined(NVTX_VERSION) || NVTX_VERSION >= 3
#include <nvtx3/nvToolsExt.h>
#define MR_PROFILE_HAS_NVTX3 1
#endif
#endif
#endif
#ifndef MR_PROFILE_HAS_NVTX3
#define MR_PROFILE_HAS_NVTX3 0
#endif

namespace {
#if MR_PROFILE_HAS_NVTX3
int profile_nvtx3_push(const char *label) { return nvtxRangePushA(label); }
int profile_nvtx3_pop() { return nvtxRangePop(); }
#endif
struct ProfileSpan {
  int64_t id = 0, parent = 0;
  std::string label;
  std::chrono::steady_clock::time_point start;
  double cpu_us = 0;
  bool ended = false, cancelled = false;
  std::unique_ptr<c10::Event> first, last;
  std::unique_ptr<c10::Stream> stream;
};
struct ExecutionProfile {
  int device, capacity;
  bool nvtx_requested, closed = false;
  int (*nvtx_push)(const char *) = nullptr;
  int (*nvtx_pop)() = nullptr;
  const char *nvtx_backend = "disabled";
  std::thread::id owner = std::this_thread::get_id();
  std::chrono::steady_clock::time_point origin = std::chrono::steady_clock::now();
  std::vector<ProfileSpan> spans;
  std::vector<size_t> stack;
  uint64_t dropped = 0;
  std::string report;
  ExecutionProfile(int d, int n, bool nvtx) : device(d), capacity(n), nvtx_requested(nvtx) {
    if (d < -1 || n < 1 || n > 65536) throw std::invalid_argument("invalid profiling device or span bound");
    if (d >= 0 && d >= mr_tensor_device_count()) throw std::invalid_argument("profiling CUDA device unavailable");
    spans.reserve(n); stack.reserve(64);
    if (nvtx) {
      nvtx_backend = "unavailable";
#if MR_PROFILE_HAS_NVTX3
      nvtx_push = &profile_nvtx3_push;
      nvtx_pop = &profile_nvtx3_pop;
      nvtx_backend = "nvtx3_header";
#else
      // Optional NVTX 2 exports, including profiler injection. Do not introduce
      // a required CUDA/NVTX dependency into CPU or legacy plugin loads.
      nvtx_push = reinterpret_cast<int (*)(const char *)>(dlsym(RTLD_DEFAULT, "nvtxRangePushA"));
      nvtx_pop = reinterpret_cast<int (*)()>(dlsym(RTLD_DEFAULT, "nvtxRangePop"));
      if (!nvtx_push || !nvtx_pop) {
        void *lib = dlopen("libnvToolsExt.so.1", RTLD_NOW | RTLD_LOCAL);
        if (lib) {
          nvtx_push = reinterpret_cast<int (*)(const char *)>(dlsym(lib, "nvtxRangePushA"));
          nvtx_pop = reinterpret_cast<int (*)()>(dlsym(lib, "nvtxRangePop"));
          // Keep the optional module loaded just like the tensor plugin.
        }
      }
      if (!nvtx_push || !nvtx_pop) { nvtx_push = nullptr; nvtx_pop = nullptr; }
      else nvtx_backend = "nvtx2_dynamic";
#endif
    }
  }
  void check() const {
    if (owner != std::this_thread::get_id()) throw std::runtime_error("profiling session used from another thread");
    if (closed) throw std::runtime_error("profiling session is closed");
  }
  int64_t begin(const char *label) {
    check();
    if (!label || !*label || std::strlen(label) > 160) throw std::invalid_argument("profiling label must contain 1..160 ASCII characters");
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(label); *p; ++p)
      if (*p < 32 || *p > 126) throw std::invalid_argument("profiling label must be printable ASCII");
    if (spans.size() == static_cast<size_t>(capacity)) { ++dropped; return 0; }
    ProfileSpan span;
    span.id = static_cast<int64_t>(spans.size()) + 1;
    span.parent = stack.empty() ? 0 : static_cast<int64_t>(stack.back()) + 1;
    span.label = label;
    if (device >= 0) {
      c10::DeviceGuard device_guard(c10::Device(c10::DeviceType::CUDA, device));
      c10::impl::VirtualGuardImpl guard(c10::DeviceType::CUDA);
      span.stream = std::make_unique<c10::Stream>(guard.getStream(c10::Device(c10::DeviceType::CUDA, device)));
      // BACKEND_DEFAULT enables CUDA event timing (PYTORCH_DEFAULT disables it).
      span.first = std::make_unique<c10::Event>(c10::DeviceType::CUDA, c10::EventFlag::BACKEND_DEFAULT);
      span.last = std::make_unique<c10::Event>(c10::DeviceType::CUDA, c10::EventFlag::BACKEND_DEFAULT);
      span.first->record(*span.stream);
    }
    if (nvtx_push) nvtx_push(label);
    span.start = std::chrono::steady_clock::now();
    spans.push_back(std::move(span));
    stack.push_back(spans.size() - 1);
    return static_cast<int64_t>(spans.size());
  }
  void end(int64_t id, bool cancelled) {
    check();
    if (!id) return;
    if (stack.empty() || id != static_cast<int64_t>(stack.back()) + 1) throw std::runtime_error("profiling scopes must close in reverse nesting order");
    auto &span = spans[stack.back()];
    span.cpu_us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - span.start).count();
    span.cancelled = cancelled;
    // Restore nesting even when CUDA event recording fails, allowing the
    // enclosing error cleanup to close its own NVTX range.
    stack.pop_back();
    if (nvtx_pop) nvtx_pop();
    if (span.last && !cancelled) {
      c10::DeviceGuard device_guard(c10::Device(c10::DeviceType::CUDA, device));
      c10::impl::VirtualGuardImpl guard(c10::DeviceType::CUDA);
      auto current = guard.getStream(c10::Device(c10::DeviceType::CUDA, device));
      if (current != *span.stream) { span.cancelled = true; throw std::runtime_error("profiling scope changed its current CUDA stream"); }
      span.last->record(current);
    }
    span.ended = true;
  }
  const char *snapshot() {
    check();
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "{\"schema\":\"moonrobo.execution-profile.v1\",\"enabled\":true,\"synchronized\":false,\"cuda_device\":" << device
        << ",\"max_spans\":" << capacity << ",\"recorded_spans\":" << spans.size()
        << ",\"dropped_spans\":" << dropped << ",\"open_spans\":" << stack.size()
        << ",\"nvtx_requested\":" << (nvtx_requested ? "true" : "false")
        << ",\"nvtx_available\":" << (nvtx_push ? "true" : "false")
        << ",\"nvtx_backend\":\"" << nvtx_backend << "\",\"nvtx_capture_verified\":false"
        << ",\"cuda_event_count_bound\":" << (device < 0 ? 0 : 2 * capacity)
        << ",\"cpu_timing\":\"inclusive_host_submission\",\"gpu_timing\":\"inclusive_current_stream_elapsed_not_kernel_active\",\"spans\":[";
    for (size_t i = 0; i < spans.size(); ++i) {
      auto &span = spans[i];
      if (i) out << ',';
      out << "{\"id\":" << span.id << ",\"parent_id\":" << span.parent << ",\"label\":\"";
      for (char ch : span.label) { if (ch == '"' || ch == '\\') out << '\\'; out << ch; }
      out << "\",\"cpu_start_us\":" << std::chrono::duration<double, std::micro>(span.start - origin).count()
          << ",\"cpu_submit_us\":";
      if (span.ended) out << span.cpu_us; else out << "null";
      out << ",\"cpu_inclusive\":true,\"cancelled\":" << (span.cancelled ? "true" : "false") << ",\"stream_id\":";
      if (span.stream) out << '"' << span.stream->id() << '"'; else out << "null";
      const char *gpu_status = span.cancelled ? "cancelled" : !span.first ? "disabled" : "pending";
      double elapsed = 0;
      if (span.first && span.ended && !span.cancelled && span.first->query() && span.last->query()) {
        elapsed = span.first->elapsedTime(*span.last);
        gpu_status = "complete";
      }
      out << ",\"gpu_status\":\"" << gpu_status << "\",\"gpu_elapsed_ms\":";
      if (std::strcmp(gpu_status, "complete") == 0) out << elapsed; else out << "null";
      out << '}';
    }
    out << "]}";
    report = out.str();
    return report.c_str();
  }
};
ExecutionProfile &execution_profile(void *p) {
  if (!p) throw std::invalid_argument("empty profiling session");
  return *static_cast<ExecutionProfile *>(p);
}
}
extern "C" void *mr_profile_create_v1(int device, int capacity, int nvtx, char *err, int cap) {
  try { return new ExecutionProfile(device, capacity, nvtx != 0); }
  catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" void mr_profile_destroy_v1(void *p) { try { delete static_cast<ExecutionProfile *>(p); } catch (...) {} }
extern "C" int64_t mr_profile_begin_v1(void *p, const char *label, char *err, int cap) {
  try { return execution_profile(p).begin(label); }
  catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" int mr_profile_end_v1(void *p, int64_t token, int cancelled, char *err, int cap) {
  return status([&] { execution_profile(p).end(token, cancelled != 0); }, err, cap);
}
extern "C" const char *mr_profile_report_v1(void *p, char *err, int cap) {
  try { return execution_profile(p).snapshot(); }
  catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" int mr_profile_close_v1(void *p, char *err, int cap) {
  return status([&] {
    auto &profile = execution_profile(p); profile.check();
    if (!profile.stack.empty()) throw std::runtime_error("cannot clear profiling with open scopes");
    profile.closed = true;
  }, err, cap);
}
