///|
pub(all) struct ProcessIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StartedProcess {
  pid : Int
  running : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
#borrow(script_path)
extern "c" fn native_start_shell_script(script_path : Bytes) -> Int = "moonrobo_process_start_shell_script"

///|
#borrow(script_path)
extern "c" fn native_run_shell_script(script_path : Bytes) -> Int = "moonrobo_process_run_shell_script"

///|
extern "c" fn native_is_running(pid : Int) -> Int = "moonrobo_process_is_running"

///|
extern "c" fn native_stop(pid : Int) -> Int = "moonrobo_process_stop"

///|
extern "c" fn native_last_error() -> Bytes = "moonrobo_process_last_error"

///|
fn issue(code : String, message : String) -> ProcessIssue {
  { code, message }
}

///|
fn last_error(default_message : String) -> String {
  let message = @utf8.decode_lossy(native_last_error())
  if message == "" {
    default_message
  } else {
    message
  }
}

///|
pub fn start_shell_script(
  script_path : String,
) -> Result[StartedProcess, ProcessIssue] {
  if script_path == "" {
    return Err(
      issue("script-path-empty", "runtime supervisor script path is empty"),
    )
  }
  let pid = native_start_shell_script(@utf8.encode(script_path))
  if pid <= 0 {
    Err(issue("process-start-failed", last_error("failed to start process")))
  } else {
    Ok({ pid, running: true })
  }
}

///|
pub fn run_shell_script(script_path : String) -> Result[Int, ProcessIssue] {
  if script_path == "" {
    return Err(
      issue("script-path-empty", "runtime process script path is empty"),
    )
  }
  let code = native_run_shell_script(@utf8.encode(script_path))
  if code < 0 {
    Err(issue("process-run-failed", last_error("failed to run process")))
  } else {
    Ok(code)
  }
}

///|
pub fn is_running(pid : Int) -> Bool {
  pid > 0 && native_is_running(pid) == 1
}

///|
pub fn stop(pid : Int) -> Result[Bool, ProcessIssue] {
  if pid <= 0 {
    return Err(issue("pid-invalid", "process pid must be positive"))
  }
  let code = native_stop(pid)
  if code < 0 {
    Err(issue("process-stop-failed", last_error("failed to stop process")))
  } else {
    Ok(code == 1)
  }
}
