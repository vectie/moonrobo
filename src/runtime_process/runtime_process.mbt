///|
pub(all) struct RuntimeSupervisorRun {
  launch_id : String
  runtime_id : String
  pid : Int
  running : Bool
  status : String
  script_path : String
  receipt_path : String
  bridge_base_url : String
  command : Array[String]
  plan : @supervisor.SupervisorPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeSupervisorStopResult {
  launch_id : String
  pid : Int
  stopped : Bool
  running : Bool
  status : String
  run_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeTelemetryProbe {
  ok : Bool
  code : String
  path : String
  message : String
  frame_id : String
  captured_at_ms : Int64
  robot_id : String
  bridge_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeHealthSnapshot {
  active : Bool
  status : String
  running : Bool
  pid : Int
  launch_id : String
  runtime_id : String
  bridge_base_url : String
  telemetry_ok : Bool
  telemetry_status : String
  telemetry_message : String
  telemetry_path : String
  telemetry_frame_id : String
  telemetry_captured_at_ms : Int64
  robot_id : String
  bridge_id : String
  run : RuntimeSupervisorRun?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  status : Int,
  code : String,
  path : String,
  message : String,
) -> @pipeline.PipelineIssue {
  { http_status: status, code, path, message }
}

///|
fn run_json(run : RuntimeSupervisorRun, indent? : Int = 2) -> String {
  run.to_json().stringify(indent~)
}

///|
fn active_run_path(root : String) -> String {
  @runtime_launcher.active_run_path(root)
}

///|
pub fn telemetry_probe_from_frame(
  frame : @core.TelemetryFrame,
  path? : String = "/telemetry/latest",
) -> RuntimeTelemetryProbe {
  {
    ok: true,
    code: "telemetry-ok",
    path,
    message: "bridge telemetry is reachable",
    frame_id: frame.frame_id,
    captured_at_ms: frame.captured_at_ms,
    robot_id: frame.robot_id,
    bridge_id: frame.bridge_id,
  }
}

///|
pub fn telemetry_probe_from_error(
  code : String,
  path : String,
  message : String,
) -> RuntimeTelemetryProbe {
  {
    ok: false,
    code,
    path,
    message,
    frame_id: "",
    captured_at_ms: 0L,
    robot_id: "",
    bridge_id: "",
  }
}

///|
fn empty_health_snapshot(
  status : String,
  run_path : String,
) -> RuntimeHealthSnapshot {
  {
    active: false,
    status,
    running: false,
    pid: 0,
    launch_id: "",
    runtime_id: "",
    bridge_base_url: "",
    telemetry_ok: false,
    telemetry_status: "unknown",
    telemetry_message: "no active runtime supervisor",
    telemetry_path: run_path,
    telemetry_frame_id: "",
    telemetry_captured_at_ms: 0L,
    robot_id: "",
    bridge_id: "",
    run: None,
  }
}

///|
fn health_snapshot_from_run(
  run : RuntimeSupervisorRun,
  telemetry_probe : RuntimeTelemetryProbe?,
) -> RuntimeHealthSnapshot {
  let telemetry_status = match telemetry_probe {
    Some(probe) => probe.code
    None => "unknown"
  }
  let telemetry_message = match telemetry_probe {
    Some(probe) => probe.message
    None => "runtime process is running; telemetry has not been probed"
  }
  let telemetry_path = match telemetry_probe {
    Some(probe) => probe.path
    None => ""
  }
  let telemetry_ok = match telemetry_probe {
    Some(probe) => probe.ok
    None => false
  }
  let status = if !run.running {
    "process-stopped"
  } else {
    match telemetry_probe {
      Some(probe) => if probe.ok { "healthy" } else { "bridge-unhealthy" }
      None => "running-unprobed"
    }
  }
  {
    active: true,
    status,
    running: run.running,
    pid: run.pid,
    launch_id: run.launch_id,
    runtime_id: run.runtime_id,
    bridge_base_url: run.bridge_base_url,
    telemetry_ok,
    telemetry_status,
    telemetry_message,
    telemetry_path,
    telemetry_frame_id: match telemetry_probe {
      Some(probe) => probe.frame_id
      None => ""
    },
    telemetry_captured_at_ms: match telemetry_probe {
      Some(probe) => probe.captured_at_ms
      None => 0L
    },
    robot_id: match telemetry_probe {
      Some(probe) => probe.robot_id
      None => ""
    },
    bridge_id: match telemetry_probe {
      Some(probe) => probe.bridge_id
      None => ""
    },
    run: Some(run),
  }
}

///|
pub fn runtime_health_snapshot(
  root : String,
  telemetry_probe? : RuntimeTelemetryProbe? = None,
) -> Result[RuntimeHealthSnapshot, @pipeline.PipelineIssue] {
  match read_active_run(root) {
    Ok(None) => Ok(empty_health_snapshot("not-running", active_run_path(root)))
    Ok(Some(run)) => Ok(health_snapshot_from_run(run, telemetry_probe))
    Err(error) => Err(error)
  }
}

///|
pub fn runtime_health_record(
  snapshot : RuntimeHealthSnapshot,
) -> @runtime_health.RuntimeHealthRecord {
  let recorded_at_ms = if snapshot.telemetry_captured_at_ms > 0L {
    snapshot.telemetry_captured_at_ms
  } else {
    0L
  }
  @runtime_health.record(
    recorded_at_ms,
    snapshot.status,
    snapshot.active,
    snapshot.running,
    snapshot.pid,
    snapshot.launch_id,
    snapshot.runtime_id,
    snapshot.robot_id,
    snapshot.bridge_id,
    snapshot.bridge_base_url,
    snapshot.telemetry_ok,
    snapshot.telemetry_status,
    snapshot.telemetry_message,
    snapshot.telemetry_path,
    snapshot.telemetry_frame_id,
    snapshot.telemetry_captured_at_ms,
  )
}

///|
fn read_run_file(
  path : String,
) -> Result[RuntimeSupervisorRun, @pipeline.PipelineIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          500, "read-runtime-run", path, "failed to read runtime supervisor run receipt",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          500, "parse-runtime-run", path, "failed to parse runtime supervisor run receipt",
        ),
      )
  }
  let run : RuntimeSupervisorRun = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          500, "decode-runtime-run", path, "failed to decode runtime supervisor run receipt",
        ),
      )
  }
  Ok(run)
}

///|
fn write_active_run(
  root : String,
  run : RuntimeSupervisorRun,
) -> Result[String, @pipeline.PipelineIssue] {
  let path = active_run_path(root)
  @fsx.write_string_to_file(path, run_json(run)) catch {
    _ =>
      return Err(
        issue(
          500, "write-runtime-run", path, "failed to write runtime supervisor run receipt",
        ),
      )
  }
  Ok(path)
}

///|
pub fn read_active_run(
  root : String,
) -> Result[RuntimeSupervisorRun?, @pipeline.PipelineIssue] {
  let path = active_run_path(root)
  if !@fsx.path_exists(path) {
    Ok(None)
  } else {
    match read_run_file(path) {
      Ok(run) => {
        let running = @native_process.is_running(run.pid)
        Ok(
          Some({
            ..run,
            running,
            status: if running {
              "running"
            } else {
              "stopped"
            },
          }),
        )
      }
      Err(error) => Err(error)
    }
  }
}

///|
pub fn require_active_run(
  root : String,
  expected_bridge_base_url? : String = "",
) -> Result[RuntimeSupervisorRun, @pipeline.PipelineIssue] {
  let path = active_run_path(root)
  let run = match read_active_run(root) {
    Ok(Some(run)) => run
    Ok(None) =>
      return Err(
        issue(
          409, "runtime-not-running", path, "physical runtime supervisor must be running before bridge execution",
        ),
      )
    Err(error) => return Err(error)
  }
  if !run.running {
    return Err(
      issue(
        409, "runtime-not-running", path, "physical runtime supervisor is not running",
      ),
    )
  }
  if expected_bridge_base_url != "" &&
    run.bridge_base_url != expected_bridge_base_url {
    Err(
      issue(
        409,
        "runtime-bridge-mismatch",
        path,
        "active runtime bridge endpoint \{run.bridge_base_url} does not match requested endpoint \{expected_bridge_base_url}",
      ),
    )
  } else {
    Ok(run)
  }
}

///|
pub fn start_launch(
  root : String,
  plan : @supervisor.SupervisorPlan,
  launch_id? : String = @runtime_launcher.launch_id_for_plan(plan),
) -> Result[RuntimeSupervisorRun, @pipeline.PipelineIssue] {
  match read_active_run(root) {
    Ok(Some(run)) if run.running => return Ok(run)
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let launch = match @runtime_launcher.prepare_launch(root, plan, launch_id~) {
    Ok(launch) => launch
    Err(error) => return Err(error)
  }
  let started = match @native_process.start_shell_script(launch.script_path) {
    Ok(started) => started
    Err(error) =>
      return Err(issue(500, error.code, launch.script_path, error.message))
  }
  let run : RuntimeSupervisorRun = {
    launch_id,
    runtime_id: plan.runtime_id,
    pid: started.pid,
    running: true,
    status: "running",
    script_path: launch.script_path,
    receipt_path: launch.receipt_path,
    bridge_base_url: plan.bridge_base_url,
    command: launch.command,
    plan,
  }
  match write_active_run(root, run) {
    Ok(_) => Ok(run)
    Err(error) => Err(error)
  }
}

///|
pub fn stop_active_run(
  root : String,
) -> Result[RuntimeSupervisorStopResult, @pipeline.PipelineIssue] {
  match read_active_run(root) {
    Ok(None) =>
      Ok({
        launch_id: "",
        pid: 0,
        stopped: false,
        running: false,
        status: "not-running",
        run_path: active_run_path(root),
      })
    Ok(Some(run)) => {
      let stopped = match @native_process.stop(run.pid) {
        Ok(stopped) => stopped
        Err(error) =>
          return Err(
            issue(500, error.code, active_run_path(root), error.message),
          )
      }
      let running = @native_process.is_running(run.pid)
      let updated : RuntimeSupervisorRun = {
        ..run,
        running,
        status: if running {
          "running"
        } else {
          "stopped"
        },
      }
      match write_active_run(root, updated) {
        Ok(path) =>
          Ok({
            launch_id: run.launch_id,
            pid: run.pid,
            stopped,
            running,
            status: updated.status,
            run_path: path,
          })
        Err(error) => Err(error)
      }
    }
    Err(error) => Err(error)
  }
}
