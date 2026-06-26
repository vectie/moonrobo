///|
extern "c" fn ignore_sigpipe_ffi() -> Unit = "moonrobo_desktop_host_ignore_sigpipe"

///|
fn install_native_signal_guards() -> Unit {
  ignore_sigpipe_ffi()
}
