///|
type NativeProfile

///|
let active_profile : Ref[NativeProfile?] = Ref::new(None)

///|
#borrow(backend)
extern "c" fn profile_create_native(
  backend : Backend,
  device : Int32,
  capacity : Int32,
  nvtx : Bool,
) -> NativeProfile = "mr_profile_create_call"

///|
#borrow(profile)
extern "c" fn profile_error_native(profile : NativeProfile) -> Bytes = "mr_profile_error_call"

///|
#borrow(profile, label)
extern "c" fn profile_begin_native(
  profile : NativeProfile,
  label : Bytes,
) -> Int64 = "mr_profile_begin_call"

///|
#borrow(profile)
extern "c" fn profile_end_native(
  profile : NativeProfile,
  token : Int64,
  cancelled : Bool,
) -> Int32 = "mr_profile_end_call"

///|
#borrow(profile)
extern "c" fn profile_report_native(profile : NativeProfile) -> Bytes = "mr_profile_report_call"

///|
#borrow(profile)
extern "c" fn profile_close_native(profile : NativeProfile) -> Int32 = "mr_profile_close_call"

///|
fn NativeProfile::check(self : NativeProfile) -> Unit raise TensorError {
  let message = @utf8.decode_lossy(profile_error_native(self))
  if message != "" {
    raise Native(message)
  }
}

///|
/// Opt-in, bounded profiling. The default is disabled and markers make no
/// native calls. A session belongs to the configuring thread. CUDA markers
/// record the current LibTorch stream and never synchronize it. The report
/// distinguishes pending intervals from measured elapsed intervals; elapsed
/// stream time includes dependency waits and is not GPU kernel active time.
pub fn configure_profiling(
  backend : Backend,
  cuda_device~ : Int32,
  max_spans~ : Int32 = 8192,
  nvtx~ : Bool = true,
) -> Unit raise TensorError {
  if active_profile.val is Some(_) {
    raise Native("profiling session already configured; clear it explicitly")
  }
  if cuda_device < -1 || max_spans < 1 || max_spans > 65536 {
    raise Native("profiling needs device >= -1 and 1..65536 spans")
  }
  let profile = profile_create_native(backend, cuda_device, max_spans, nvtx)
  backend.check()
  active_profile.val = Some(profile)
}

///|
pub fn profiling_enabled() -> Bool {
  active_profile.val is Some(_)
}

///|
/// A zero token means disabled or capacity exhausted. Nonzero tokens must be
/// closed in reverse nesting order on the same thread.
pub fn profile_begin(stage : String) -> Int64 raise TensorError {
  match active_profile.val {
    None =>
      if operator_diagnostics_enabled() {
        -operator_range_begin("diag.profile." + stage)
      } else {
        0L
      }
    Some(profile) => {
      let token = profile_begin_native(profile, @utf8.encode(stage))
      profile.check()
      token
    }
  }
}

///|
pub fn profile_end(token : Int64) -> Unit raise TensorError {
  if token < 0L {
    operator_range_end(-token)
    return
  }
  if token == 0L {
    return
  }
  guard active_profile.val is Some(profile) else {
    raise Native("cannot end a scope after clearing its profiling session")
  }
  ignore(profile_end_native(profile, token, false))
  profile.check()
}

///|
/// Error cleanup never replaces the original training error. A cancelled span
/// is excluded from completed GPU measurements and is labelled in the report.
pub fn profile_cancel(token : Int64) -> Unit {
  if token < 0L {
    operator_range_cancel(-token)
    return
  }
  if token != 0L && active_profile.val is Some(profile) {
    ignore(profile_end_native(profile, token, true))
  }
}

///|
pub fn[T] profile_span(stage : String, run : () -> T raise) -> T raise {
  if active_profile.val is None && !operator_diagnostics_enabled() {
    return run()
  }
  let token = profile_begin(stage)
  errdefer profile_cancel(token)
  let value = run()
  profile_end(token)
  value
}

///|
/// Snapshot all recorded spans, without draining or waiting. Invoke after an
/// existing synchronization boundary if completed GPU measurements are needed.
/// Inclusive nested CPU/GPU durations must not be added as disjoint phases.
pub fn profiling_report() -> String raise TensorError {
  match active_profile.val {
    None =>
      "{\"schema\":\"moonrobo.execution-profile.v1\",\"enabled\":false,\"synchronized\":false,\"spans\":[]}"
    Some(profile) => {
      let report = profile_report_native(profile)
      profile.check()
      @utf8.decode_lossy(report)
    }
  }
}

///|
/// Release a completed session. Open scopes are rejected; pending CUDA events
/// are destroyed using the backend event API without a profiling sync.
pub fn clear_profiling() -> Unit raise TensorError {
  if active_profile.val is Some(profile) {
    ignore(profile_close_native(profile))
    profile.check()
    active_profile.val = None
  }
}
