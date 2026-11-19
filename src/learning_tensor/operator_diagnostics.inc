// Independent, opt-in diagnostic extension. No per-operator CUDA events,
// tensor values, shapes or autograd graphs are retained by this adapter.
#include <ATen/record_function.h>
#include <chrono>
#if defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) && MR_ENABLE_OPERATOR_DIAGNOSTICS
#include <torch/csrc/autograd/profiler_kineto.h>
#include <torch/csrc/profiler/orchestration/observer.h>
#endif

namespace {
struct OperatorRange {
  int64_t id, parent;
  std::string label;
  bool ended = false, cancelled = false;
  std::unique_ptr<at::RecordFunction> record;
};
struct OperatorDiagnostics {
  int device, capacity;
  int mode = 2; // 0: boundary only, 1: explicit ranges, 2: original ATen observer.
  using Clock = std::chrono::steady_clock;
  Clock::time_point boundary_start, work_start;
  double setup_ms = 0, submit_ms = 0, drain_ms = 0, teardown_ms = 0;
  bool structural, active = false, completed = false, cancelled = false, broken = false;
  bool profiler_started = false, trigger_started = false, closed = false;
  std::thread::id owner = std::this_thread::get_id();
  std::vector<OperatorRange> ranges;
  std::vector<size_t> stack;
  std::string report;
  OperatorDiagnostics(int d, int n, bool test) : device(d), capacity(n), structural(test) {
    if (n < 1 || n > 65536) throw std::invalid_argument("operator diagnostics range bound must be 1..65536");
    if (structural && d != -1) throw std::invalid_argument("structural-only diagnostics require CPU device -1");
    if (!structural) {
#if !defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) || !MR_ENABLE_OPERATOR_DIAGNOSTICS
      throw std::runtime_error("operator NVTX diagnostics require an explicitly enabled diagnostic plugin build");
#elif !MR_PROFILE_HAS_NVTX3
      throw std::runtime_error("operator NVTX diagnostics require matching NVTX3 headers in diagnostic plugin");
#else
      if (d < 0 || d >= mr_tensor_device_count()) throw std::invalid_argument("operator diagnostics CUDA device unavailable");
#endif
    }
    ranges.reserve(n); stack.reserve(128);
  }
  void check() const {
    if (owner != std::this_thread::get_id()) throw std::runtime_error("operator diagnostics require their configuring thread");
    if (closed) throw std::runtime_error("operator diagnostics session is closed");
  }
  void start() {
    check();
    if (active || completed || cancelled) throw std::runtime_error("operator diagnostics capture is single-use");
    boundary_start = Clock::now();
    if (!structural) {
#if defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) && MR_ENABLE_OPERATOR_DIAGNOSTICS && MR_PROFILE_HAS_NVTX3
      // Same explicit boundary as torch.autograd.profiler.emit_nvtx. This is
      // instrumentation overhead, not a throughput measurement.
      torch::cuda::synchronize(device);
      if (mode == 2) { torch::autograd::profiler::enableProfiler(
          torch::profiler::impl::ProfilerConfig(torch::profiler::impl::ProfilerState::NVTX,
                                               false, false, false, false, false), {});
      profiler_started = true; }
      nvtxRangePushA("moonrobo.actor_critic.capture");
      trigger_started = true;
#endif
    }
    active = true;
    work_start = Clock::now();
    setup_ms = std::chrono::duration<double, std::milli>(work_start - boundary_start).count();
  }
  int64_t begin(const char *label) {
    check();
    if (!active) throw std::runtime_error("operator range outside selected capture");
    if (mode == 0) return 0;
    if (!label || !*label || std::strlen(label) > 160) throw std::invalid_argument("operator label requires 1..160 printable ASCII characters");
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(label); *p; ++p)
      if (*p < 32 || *p > 126) throw std::invalid_argument("operator label requires printable ASCII");
    if (ranges.size() >= static_cast<size_t>(capacity)) throw std::runtime_error("operator structural range bound exceeded; capture is incomplete");
    if (stack.size() >= 128) throw std::runtime_error("operator diagnostic nesting exceeds 128");
    OperatorRange r{static_cast<int64_t>(ranges.size()) + 1,
                    stack.empty() ? 0 : static_cast<int64_t>(stack.back()) + 1, label};
    ranges.push_back(std::move(r));
    auto &saved = ranges.back();
    stack.push_back(ranges.size() - 1);
    try {
      if (!structural && mode == 2) {
        saved.record = std::make_unique<at::RecordFunction>(at::RecordScope::USER_SCOPE);
        saved.record->before(saved.label.c_str());
      }
#if defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) && MR_ENABLE_OPERATOR_DIAGNOSTICS && MR_PROFILE_HAS_NVTX3
      if (!structural && mode == 1) nvtxRangePushA(saved.label.c_str());
#endif
    } catch (...) {
      // The object may have installed an observer before before() failed.
      // Restore both stacks, retain failed evidence, and never call it complete.
      saved.record.reset(); saved.ended = true; saved.cancelled = true;
      stack.pop_back(); broken = true;
      throw;
    }
    return saved.id;
  }
  void end(int64_t id, bool cancel) {
    check();
    if (!id) return;
    if (id < 1 || static_cast<size_t>(id) > ranges.size()) throw std::runtime_error("unknown operator diagnostic token");
    auto &r = ranges[static_cast<size_t>(id - 1)];
    if (r.ended && cancel) return; // errdefer may revisit a successfully closed scope.
    if (!active || r.ended || stack.empty() || stack.back() != static_cast<size_t>(id - 1))
      throw std::runtime_error("operator diagnostic scopes must close in reverse nesting order");
    r.record.reset();
#if defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) && MR_ENABLE_OPERATOR_DIAGNOSTICS && MR_PROFILE_HAS_NVTX3
    if (!structural && mode == 1) nvtxRangePop();
#endif
    r.ended = true; r.cancelled = cancel;
    stack.pop_back();
  }
  void finish(bool cancel) {
    check();
    if (!active) {
      if (cancel) return;
      throw std::runtime_error("operator capture is not active");
    }
    if (!cancel && !stack.empty()) throw std::runtime_error("operator capture has open structural scopes");
    while (!stack.empty()) end(static_cast<int64_t>(stack.back()) + 1, true);
    // Always remove the observer/trigger, even when the diagnostic-only drain
    // fails; preserve the first exception and refuse a second capture.
    std::exception_ptr first;
    const auto drain_start = Clock::now();
    submit_ms = std::chrono::duration<double, std::milli>(drain_start - work_start).count();
    if (!structural) {
#if defined(MR_ENABLE_OPERATOR_DIAGNOSTICS) && MR_ENABLE_OPERATOR_DIAGNOSTICS && MR_PROFILE_HAS_NVTX3
      try { torch::cuda::synchronize(device); } catch (...) { first = std::current_exception(); }
      drain_ms = std::chrono::duration<double, std::milli>(Clock::now() - drain_start).count();
      if (trigger_started) { nvtxRangePop(); trigger_started = false; }
      if (profiler_started) {
        try { (void)torch::autograd::profiler::disableProfiler(); }
        catch (...) { if (!first) first = std::current_exception(); }
        profiler_started = false;
      }
#endif
    }
    teardown_ms = std::chrono::duration<double, std::milli>(Clock::now() - drain_start).count() - drain_ms;
    active = false; cancelled = cancel || broken || static_cast<bool>(first); completed = !cancelled;
    if (first) std::rethrow_exception(first);
    if (broken && !cancel) throw std::runtime_error("operator capture contains a failed range construction");
  }
  const char *snapshot() {
    check();
    std::ostringstream out;
    out << "{\"schema\":\"moonrobo.operator-diagnostics.v1\",\"structural_only\":" << (structural ? "true" : "false")
        << ",\"automatic_aten_autograd_nvtx\":" << ((!structural && mode == 2) ? "true" : "false")
        << ",\"observer\":\"" << (mode == 0 ? "off" : mode == 1 ? "ranges" : "aten") << "\""
        << ",\"boundary_timing_ms\":{\"setup\":" << setup_ms << ",\"submit\":" << submit_ms
        << ",\"drain\":" << drain_ms << ",\"teardown\":" << teardown_ms << "}"
        << ",\"record_shapes\":false,\"cuda_events_created\":0,\"capture_verified\":false"
        << ",\"capture_trigger\":\"moonrobo.actor_critic.capture\",\"active\":" << (active ? "true" : "false")
        << ",\"completed\":" << (completed ? "true" : "false") << ",\"cancelled\":" << (cancelled ? "true" : "false")
        << ",\"open_ranges\":" << stack.size() << ",\"max_ranges\":" << capacity
        << ",\"range_count\":" << ranges.size() << ",\"ranges\":[";
    for (size_t i = 0; i < ranges.size(); ++i) {
      auto &r = ranges[i]; if (i) out << ',';
      out << "{\"id\":" << r.id << ",\"parent\":" << r.parent << ",\"label\":\"";
      for (char ch : r.label) { if (ch == '"' || ch == '\\') out << '\\'; out << ch; }
      out << "\",\"ended\":" << (r.ended ? "true" : "false") << ",\"cancelled\":" << (r.cancelled ? "true" : "false") << '}';
    }
    out << "]}"; report = out.str(); return report.c_str();
  }
  ~OperatorDiagnostics() { if (active && owner == std::this_thread::get_id()) { try { finish(true); } catch (...) {} } }
};
OperatorDiagnostics &operator_diagnostics(void *p) {
  if (!p) throw std::invalid_argument("empty operator diagnostic session");
  return *static_cast<OperatorDiagnostics *>(p);
}
}
extern "C" void *mr_operator_diagnostics_create_v1(int d, int n, int structural, char *err, int cap) {
  try { return new OperatorDiagnostics(d, n, structural != 0); }
  catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" void mr_operator_diagnostics_destroy_v1(void *p) { delete static_cast<OperatorDiagnostics *>(p); }
extern "C" int mr_operator_diagnostics_mode_v1(void *p, int mode, char *err, int cap) {
  return status([&] { auto &s = operator_diagnostics(p); s.check();
    if (s.active || s.completed || s.cancelled || mode < 0 || mode > 2)
      throw std::invalid_argument("observer mode must be 0..2 and configured before capture");
    s.mode = mode;
  }, err, cap);
}
extern "C" int mr_operator_diagnostics_start_v1(void *p, char *err, int cap) {
  return status([&] { operator_diagnostics(p).start(); }, err, cap);
}
extern "C" int64_t mr_operator_diagnostics_begin_v1(void *p, const char *label, char *err, int cap) {
  try { return operator_diagnostics(p).begin(label); }
  catch (const std::exception &e) { error(err, cap, e.what()); return -1; }
}
extern "C" int mr_operator_diagnostics_end_v1(void *p, int64_t token, int cancel, char *err, int cap) {
  return status([&] { operator_diagnostics(p).end(token, cancel != 0); }, err, cap);
}
extern "C" int mr_operator_diagnostics_finish_v1(void *p, int cancel, char *err, int cap) {
  return status([&] { operator_diagnostics(p).finish(cancel != 0); }, err, cap);
}
extern "C" const char *mr_operator_diagnostics_report_v1(void *p, char *err, int cap) {
  try { return operator_diagnostics(p).snapshot(); }
  catch (const std::exception &e) { error(err, cap, e.what()); return nullptr; }
}
extern "C" int mr_operator_diagnostics_close_v1(void *p, char *err, int cap) {
  return status([&] { auto &s = operator_diagnostics(p); s.check(); if (s.active) s.finish(true); s.closed = true; }, err, cap);
}
