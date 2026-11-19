///|
type NativeOperatorDiagnostics

///|
priv struct OperatorDiagnosticSession {
  native : NativeOperatorDiagnostics
  iteration : Int32
  phase : String
  observer : String
  mut active : Bool
  mut started : Bool
}

///|
let operator_diagnostic_session : Ref[OperatorDiagnosticSession?] = Ref::new(
  None,
)

///|
extern "c" fn operator_flush_native() -> Int32 = "mr_operator_diagnostics_flush_call"

///|
/// Explicit flush for the two watchdog lines only. Never called per operator.
pub fn operator_diagnostic_flush() -> Unit raise TensorError {
  if operator_diagnostic_session.val is Some(_) && operator_flush_native() != 0 {
    raise Native("cannot flush operator diagnostic watchdog marker")
  }
}

///|
#borrow(backend)
extern "c" fn operator_create_native(
  backend : Backend,
  device : Int32,
  capacity : Int32,
  structural : Bool,
) -> NativeOperatorDiagnostics = "mr_operator_diagnostics_create_call"

///|
#borrow(session)
extern "c" fn operator_mode_native(
  session : NativeOperatorDiagnostics,
  mode : Int32,
) -> Int32 = "mr_operator_diagnostics_mode_call"

///|
#borrow(session)
extern "c" fn operator_error_native(
  session : NativeOperatorDiagnostics,
) -> Bytes = "mr_operator_diagnostics_error_call"

///|
#borrow(session)
extern "c" fn operator_start_native(
  session : NativeOperatorDiagnostics,
) -> Int32 = "mr_operator_diagnostics_start_call"

///|
#borrow(session, label)
extern "c" fn operator_begin_native(
  session : NativeOperatorDiagnostics,
  label : Bytes,
) -> Int64 = "mr_operator_diagnostics_begin_call"

///|
#borrow(session)
extern "c" fn operator_end_native(
  session : NativeOperatorDiagnostics,
  token : Int64,
  cancel : Bool,
) -> Int32 = "mr_operator_diagnostics_end_call"

///|
#borrow(session)
extern "c" fn operator_finish_native(
  session : NativeOperatorDiagnostics,
  cancel : Bool,
) -> Int32 = "mr_operator_diagnostics_finish_call"

///|
#borrow(session)
extern "c" fn operator_report_native(
  session : NativeOperatorDiagnostics,
) -> Bytes = "mr_operator_diagnostics_report_call"

///|
#borrow(session)
extern "c" fn operator_close_native(
  session : NativeOperatorDiagnostics,
) -> Int32 = "mr_operator_diagnostics_close_call"

///|
fn NativeOperatorDiagnostics::check(
  self : NativeOperatorDiagnostics,
) -> Unit raise TensorError {
  let error = @utf8.decode_lossy(operator_error_native(self))
  if error != "" {
    raise Native(error)
  }
}

///|
/// Configure one diagnostic window. This never enables callbacks until the
/// selected iteration begins. Structural-only CPU tests exercise labels and
/// cleanup, and explicitly do not claim CUDA, NVTX or autograd capture coverage.
pub fn configure_operator_diagnostics(
  backend : Backend,
  cuda_device~ : Int32,
  iteration~ : Int32 = 41,
  structural_only~ : Bool = false,
  max_ranges~ : Int32 = 65536,
  phase~ : String = "actor_critic",
  observer~ : String = "aten",
) -> Unit raise TensorError {
  guard operator_diagnostic_session.val is None else {
    raise Native("operator diagnostics session is already configured")
  }
  guard iteration >= 1 && max_ranges >= 1 && max_ranges <= 65536 else {
    raise Native(
      "operator diagnostics need positive iteration and 1..65536 ranges",
    )
  }
  guard ["collection", "world", "actor_critic"].contains(phase) &&
    ["off", "ranges", "aten"].contains(observer) else {
    raise Native("invalid diagnostic phase or observer mode")
  }
  let native = operator_create_native(
    backend, cuda_device, max_ranges, structural_only,
  )
  backend.check()
  if observer != "aten" {
    ignore(operator_mode_native(native, if observer == "off" { 0 } else { 1 }))
    native.check()
  }
  operator_diagnostic_session.val = Some({
    native,
    iteration,
    phase,
    observer,
    active: false,
    started: false,
  })
}

///|
/// Pure MoonBit check: disabled paths perform no native query or label encoding.
pub fn operator_diagnostics_enabled() -> Bool {
  match operator_diagnostic_session.val {
    Some(session) => session.active && session.observer != "off"
    None => false
  }
}

///|
/// Allows one fixed watchdog line before the diagnostic boundary synchronization.
/// This is a pure state check; it neither enables the observer nor allocates labels.
pub fn operator_diagnostic_iteration_selected(
  iteration : Int32,
  phase~ : String = "actor_critic",
) -> Bool {
  match operator_diagnostic_session.val {
    Some(session) =>
      session.iteration == iteration &&
      session.phase == phase &&
      !session.started
    None => false
  }
}

///|
/// Called around the complete actor/critic update, including replay preparation.
/// Returns zero outside the selected iteration, otherwise a single-use token.
pub fn operator_diagnostic_iteration_begin(
  iteration : Int32,
  phase~ : String = "actor_critic",
) -> Int64 raise TensorError {
  guard operator_diagnostic_session.val is Some(session) else { return 0L }
  if session.iteration != iteration || session.phase != phase {
    return 0L
  }
  guard !session.started else { raise Native("operator capture is single-use") }
  session.started = true
  ignore(operator_start_native(session.native))
  session.native.check()
  session.active = true
  1L
}

///|
pub fn operator_diagnostic_iteration_end(
  token : Int64,
) -> Unit raise TensorError {
  if token == 0L {
    return
  }
  guard token == 1L &&
    operator_diagnostic_session.val is Some(session) &&
    session.active else {
    raise Native("invalid operator capture token")
  }
  // On an error the caller's errdefer still sees active=true and can cancel.
  ignore(operator_finish_native(session.native, false))
  session.native.check()
  session.active = false
}

///|
pub fn operator_diagnostic_iteration_cancel(token : Int64) -> Unit {
  if token == 1L &&
    operator_diagnostic_session.val is Some(session) &&
    session.active {
    ignore(operator_finish_native(session.native, true))
    session.active = false
  }
}

///|
pub fn operator_range_begin(label : String) -> Int64 raise TensorError {
  guard operator_diagnostic_session.val is Some(session) &&
    session.active &&
    session.observer != "off" else {
    return 0L
  }
  let token = operator_begin_native(session.native, @utf8.encode(label))
  session.native.check()
  token
}

///|
pub fn operator_range_end(token : Int64) -> Unit raise TensorError {
  if token == 0L {
    return
  }
  guard operator_diagnostic_session.val is Some(session) && session.active else {
    raise Native("operator range ended outside capture")
  }
  ignore(operator_end_native(session.native, token, false))
  session.native.check()
}

///|
/// Error cleanup never replaces the training error and may revisit closed tokens.
pub fn operator_range_cancel(token : Int64) -> Unit {
  if token != 0L &&
    operator_diagnostic_session.val is Some(session) &&
    session.active {
    ignore(operator_end_native(session.native, token, true))
  }
}

///|
pub fn[T] operator_span(label : String, run : () -> T raise) -> T raise {
  if !operator_diagnostics_enabled() {
    return run()
  }
  let token = operator_range_begin(label)
  errdefer operator_range_cancel(token)
  let value = run()
  operator_range_end(token)
  value
}

///|
/// Structural evidence only. Real CUDA kernel/NVTX capture is verified from the
/// independent Nsight artifact, never inferred from successful marker calls.
pub fn operator_diagnostics_report() -> String raise TensorError {
  match operator_diagnostic_session.val {
    None =>
      "{\"schema\":\"moonrobo.operator-diagnostics.v1\",\"enabled\":false}"
    Some(session) => {
      let text = operator_report_native(session.native)
      session.native.check()
      @utf8.decode_lossy(text)
    }
  }
}

///|
pub fn clear_operator_diagnostics() -> Unit raise TensorError {
  if operator_diagnostic_session.val is Some(session) {
    ignore(operator_close_native(session.native))
    session.native.check()
    operator_diagnostic_session.val = None
  }
}
