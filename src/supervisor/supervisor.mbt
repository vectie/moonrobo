///|
pub(all) enum SupervisorProcessState {
  MissingCommand
  ReadyToStart
  WaitingForDependency
  WaitingForSnapshot
  ReadyForHealthProbe
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisorStepAction {
  ValidateManifest
  StartProcess
  WaitForArtifact
  ProbeHealth
  StopProcess
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SupervisorStepState {
  Ready
  Pending
  Blocked
  Complete
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SupervisorIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SupervisorProcessStatus {
  process_id : String
  role : @bridge_sidecar.RuntimeProcessRole
  state : SupervisorProcessState
  command : Array[String]
  env : Map[String, String]
  cwd : String
  command_path : String
  command_resolution : String
  command_available : Bool
  output_path : String
  output_ready : Bool
  health_url : String
  depends_on : Array[String]
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SupervisorStep {
  index : Int
  action : SupervisorStepAction
  state : SupervisorStepState
  process_id : String
  target : String
  command : Array[String]
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SupervisorPlan {
  runtime_id : String
  robot_id : String
  bridge_id : String
  status : String
  ready : Bool
  snapshot_path : String
  snapshot_ready : Bool
  bridge_base_url : String
  processes : Array[SupervisorProcessStatus]
  steps : Array[SupervisorStep]
  issues : Array[SupervisorIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> SupervisorIssue {
  { code, path, message }
}

///|
fn command_path(command : Array[String]) -> String {
  if command.is_empty() {
    ""
  } else {
    command[0]
  }
}

///|
fn command_resolution(command : Array[String]) -> String {
  let path = command_path(command)
  if path == "" {
    "empty"
  } else if path.contains("/") {
    "local-path"
  } else {
    "search-path"
  }
}

///|
fn command_is_available(command : Array[String]) -> Bool {
  let path = command_path(command)
  if path == "" {
    false
  } else if path.contains("/") {
    @fsx.path_exists(path)
  } else {
    true
  }
}

///|
fn output_is_ready(path : String) -> Bool {
  path != "" && @fsx.path_exists(path)
}

///|
fn process_index(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  process_id : String,
) -> Int? {
  for index in 0..<runtime.processes.length() {
    if runtime.processes[index].process_id == process_id {
      return Some(index)
    }
  }
  None
}

///|
fn dependency_declared_before(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  current_index : Int,
  dependency_id : String,
) -> Bool {
  match process_index(runtime, dependency_id) {
    Some(index) => index < current_index
    None => false
  }
}

///|
fn has_missing_dependency(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  process_index : Int,
  process : @bridge_sidecar.RuntimeProcessSpec,
) -> Bool {
  for dependency in process.depends_on {
    if !dependency_declared_before(runtime, process_index, dependency) {
      return true
    }
  }
  false
}

///|
fn process_health_url(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  process : @bridge_sidecar.RuntimeProcessSpec,
) -> String {
  if process.health_path == "" {
    ""
  } else {
    runtime.bridge_base_url + process.health_path
  }
}

///|
fn process_state(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  index : Int,
  process : @bridge_sidecar.RuntimeProcessSpec,
  snapshot_ready : Bool,
) -> SupervisorProcessState {
  if !command_is_available(process.command) {
    MissingCommand
  } else if has_missing_dependency(runtime, index, process) {
    WaitingForDependency
  } else if process.role is BridgeSidecar && !snapshot_ready {
    WaitingForSnapshot
  } else if process.health_path != "" {
    ReadyForHealthProbe
  } else {
    ReadyToStart
  }
}

///|
fn process_detail(
  state : SupervisorProcessState,
  process_id : String,
) -> String {
  match state {
    MissingCommand => "command is missing for \{process_id}"
    ReadyToStart => "process is ready to start"
    WaitingForDependency => "process waits for an earlier dependency"
    WaitingForSnapshot => "bridge waits for collector snapshot output"
    ReadyForHealthProbe => "process can start, then health should be probed"
  }
}

///|
fn process_status(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  index : Int,
  process : @bridge_sidecar.RuntimeProcessSpec,
  snapshot_ready : Bool,
) -> SupervisorProcessStatus {
  let state = process_state(runtime, index, process, snapshot_ready)
  {
    process_id: process.process_id,
    role: process.role,
    state,
    command: process.command,
    env: process.env,
    cwd: process.cwd,
    command_path: command_path(process.command),
    command_resolution: command_resolution(process.command),
    command_available: command_is_available(process.command),
    output_path: process.output_path,
    output_ready: output_is_ready(process.output_path),
    health_url: process_health_url(runtime, process),
    depends_on: process.depends_on,
    detail: process_detail(state, process.process_id),
  }
}

///|
fn duplicate_process_id(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  process_id : String,
  before_index : Int,
) -> Bool {
  for index in 0..<before_index {
    if runtime.processes[index].process_id == process_id {
      return true
    }
  }
  false
}

///|
fn structural_issues(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
) -> Array[SupervisorIssue] {
  let issues : Array[SupervisorIssue] = []
  if runtime.processes.is_empty() {
    issues.push(
      issue("runtime-empty", runtime.runtime_id, "runtime has no processes"),
    )
  }
  for index in 0..<runtime.processes.length() {
    let process = runtime.processes[index]
    if process.process_id == "" {
      issues.push(
        issue("process-id-empty", "processes[\{index}]", "process id is empty"),
      )
    } else if duplicate_process_id(runtime, process.process_id, index) {
      issues.push(
        issue(
          "process-id-duplicate",
          process.process_id,
          "process id is duplicated",
        ),
      )
    }
    if process.command.is_empty() {
      issues.push(
        issue(
          "process-command-empty",
          process.process_id,
          "process command is empty",
        ),
      )
    }
    for dependency in process.depends_on {
      if !dependency_declared_before(runtime, index, dependency) {
        issues.push(
          issue(
            "process-dependency-missing",
            process.process_id,
            "dependency is missing or declared after process: \{dependency}",
          ),
        )
      }
    }
  }
  issues
}

///|
fn blocked_by_process(status : SupervisorProcessStatus) -> Bool {
  status.state == MissingCommand || status.state == WaitingForDependency
}

///|
fn runtime_status(
  issues : Array[SupervisorIssue],
  processes : Array[SupervisorProcessStatus],
  snapshot_ready : Bool,
) -> String {
  if !issues.is_empty() || processes.any(blocked_by_process) {
    "blocked"
  } else if !snapshot_ready {
    "collector-ready"
  } else {
    "bridge-ready"
  }
}

///|
fn process_statuses(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  snapshot_ready : Bool,
) -> Array[SupervisorProcessStatus] {
  [
    for index in 0..<runtime.processes.length() => {
      process_status(runtime, index, runtime.processes[index], snapshot_ready)
    }
  ]
}

///|
fn step(
  index : Int,
  action : SupervisorStepAction,
  state : SupervisorStepState,
  process_id : String,
  target : String,
  command : Array[String],
  detail : String,
) -> SupervisorStep {
  { index, action, state, process_id, target, command, detail }
}

///|
fn process_by_role(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  role : @bridge_sidecar.RuntimeProcessRole,
) -> @bridge_sidecar.RuntimeProcessSpec? {
  for process in runtime.processes {
    if process.role == role {
      return Some(process)
    }
  }
  None
}

///|
fn launch_step_state(status : SupervisorProcessStatus) -> SupervisorStepState {
  match status.state {
    MissingCommand | WaitingForDependency => Blocked
    WaitingForSnapshot => Pending
    ReadyToStart | ReadyForHealthProbe => Ready
  }
}

///|
fn status_for_process(
  processes : Array[SupervisorProcessStatus],
  process_id : String,
) -> SupervisorProcessStatus? {
  for process in processes {
    if process.process_id == process_id {
      return Some(process)
    }
  }
  None
}

///|
fn lifecycle_steps(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  processes : Array[SupervisorProcessStatus],
  issues : Array[SupervisorIssue],
  snapshot_ready : Bool,
) -> Array[SupervisorStep] {
  let steps : Array[SupervisorStep] = []
  steps.push(
    step(
      0,
      ValidateManifest,
      if issues.is_empty() {
        Complete
      } else {
        Blocked
      },
      runtime.runtime_id,
      runtime.runtime_id,
      [],
      if issues.is_empty() {
        "runtime manifest is structurally valid"
      } else {
        "runtime manifest has structural issues"
      },
    ),
  )
  let mut next_index = 1
  match process_by_role(runtime, SnapshotCollector) {
    Some(collector) => {
      let status = status_for_process(processes, collector.process_id).unwrap()
      steps.push(
        step(
          next_index,
          StartProcess,
          launch_step_state(status),
          collector.process_id,
          collector.process_id,
          collector.command,
          "start SDK snapshot collector",
        ),
      )
      next_index += 1
      steps.push(
        step(
          next_index,
          WaitForArtifact,
          if snapshot_ready {
            Complete
          } else {
            Pending
          },
          collector.process_id,
          runtime.snapshot_path,
          [],
          "wait for latest SdkE1Snapshot output",
        ),
      )
      next_index += 1
    }
    None => ()
  }
  match process_by_role(runtime, HighControlWriter) {
    Some(writer) => {
      let status = status_for_process(processes, writer.process_id).unwrap()
      steps.push(
        step(
          next_index,
          StartProcess,
          launch_step_state(status),
          writer.process_id,
          writer.process_id,
          writer.command,
          "start SDK high-control command writer",
        ),
      )
      next_index += 1
    }
    None => ()
  }
  match process_by_role(runtime, BridgeSidecar) {
    Some(bridge) => {
      let status = status_for_process(processes, bridge.process_id).unwrap()
      steps.push(
        step(
          next_index,
          StartProcess,
          launch_step_state(status),
          bridge.process_id,
          bridge.process_id,
          bridge.command,
          "start SDK bridge sidecar after collector output is available",
        ),
      )
      next_index += 1
      steps.push(
        step(
          next_index,
          ProbeHealth,
          if snapshot_ready && status.state == ReadyForHealthProbe {
            Ready
          } else {
            Pending
          },
          bridge.process_id,
          process_health_url(runtime, bridge),
          [],
          "probe bridge health endpoint",
        ),
      )
      next_index += 1
      steps.push(
        step(
          next_index,
          StopProcess,
          Pending,
          bridge.process_id,
          bridge.process_id,
          [],
          "stop bridge sidecar before collector",
        ),
      )
      next_index += 1
    }
    None => ()
  }
  match process_by_role(runtime, HighControlWriter) {
    Some(writer) => {
      steps.push(
        step(
          next_index,
          StopProcess,
          Pending,
          writer.process_id,
          writer.process_id,
          [],
          "stop SDK high-control command writer before collector",
        ),
      )
      next_index += 1
    }
    None => ()
  }
  match process_by_role(runtime, SnapshotCollector) {
    Some(collector) =>
      steps.push(
        step(
          next_index,
          StopProcess,
          Pending,
          collector.process_id,
          collector.process_id,
          [],
          "stop SDK snapshot collector last",
        ),
      )
    None => ()
  }
  steps
}

///|
pub fn plan(
  runtime : @bridge_sidecar.PhysicalRuntimeSpec,
  snapshot_ready? : Bool = output_is_ready(runtime.snapshot_path),
) -> SupervisorPlan {
  let issues = structural_issues(runtime)
  let processes = process_statuses(runtime, snapshot_ready)
  let status = runtime_status(issues, processes, snapshot_ready)
  {
    runtime_id: runtime.runtime_id,
    robot_id: runtime.robot_id,
    bridge_id: runtime.bridge_id,
    status,
    ready: status != "blocked",
    snapshot_path: runtime.snapshot_path,
    snapshot_ready,
    bridge_base_url: runtime.bridge_base_url,
    processes,
    steps: lifecycle_steps(runtime, processes, issues, snapshot_ready),
    issues,
  }
}

///|
pub fn plan_json(plan : SupervisorPlan, indent? : Int = 2) -> String {
  plan.to_json().stringify(indent~)
}

///|
fn shell_quote(value : String) -> String {
  "'" + value.replace(old="'", new="'\"'\"'") + "'"
}

///|
fn command_line(command : Array[String]) -> String {
  [ for arg in command => shell_quote(arg) ].join(" ")
}

///|
fn env_prefix(env : Map[String, String]) -> String {
  let parts : Array[String] = []
  for key, value in env {
    parts.push("\{key}=\{shell_quote(value)}")
  }
  if parts.is_empty() {
    ""
  } else {
    "env " + parts.join(" ") + " "
  }
}

///|
fn process_for_role(
  plan : SupervisorPlan,
  role : @bridge_sidecar.RuntimeProcessRole,
) -> SupervisorProcessStatus? {
  for process in plan.processes {
    if process.role == role {
      return Some(process)
    }
  }
  None
}

///|
fn start_process_line(
  process : SupervisorProcessStatus,
  pid_var : String,
) -> String {
  "( cd \{shell_quote(process.cwd)} && \{env_prefix(process.env)}\{command_line(process.command)} ) & \{pid_var}=$!"
}

///|
pub fn shell_script(
  plan : SupervisorPlan,
  wait_attempts? : Int = 100,
  sleep_seconds? : String = "0.10",
  log_path? : String = "",
) -> String {
  let lines : Array[String] = [
    "#!/usr/bin/env sh",
    "set -eu",
    "",
    "COLLECTOR_PID=\"\"",
    "WRITER_PID=\"\"",
    "BRIDGE_PID=\"\"",
    "",
    "cleanup() {",
    "  if [ -n \"${BRIDGE_PID:-}\" ]; then kill \"$BRIDGE_PID\" 2>/dev/null || true; fi",
    "  if [ -n \"${WRITER_PID:-}\" ]; then kill \"$WRITER_PID\" 2>/dev/null || true; fi",
    "  if [ -n \"${COLLECTOR_PID:-}\" ]; then kill \"$COLLECTOR_PID\" 2>/dev/null || true; fi",
    "}",
    "trap cleanup INT TERM EXIT",
    "",
    "wait_for_file() {",
    "  path=$1",
    "  i=0",
    "  while [ \"$i\" -lt \{wait_attempts} ]; do",
    "    if [ -s \"$path\" ]; then return 0; fi",
    "    i=$((i + 1))",
    "    sleep \{shell_quote(sleep_seconds)}",
    "  done",
    "  echo \"MoonRobo supervisor timed out waiting for $path\" >&2",
    "  return 1",
    "}",
    "",
    "probe_health() {",
    "  url=$1",
    "  i=0",
    "  while [ \"$i\" -lt \{wait_attempts} ]; do",
    "    if curl -fsS --max-time 1 \"$url\" >/dev/null 2>&1; then return 0; fi",
    "    i=$((i + 1))",
    "    sleep \{shell_quote(sleep_seconds)}",
    "  done",
    "  echo \"MoonRobo supervisor timed out probing $url\" >&2",
    "  return 1",
    "}",
    "",
    "ensure_parent_dir() {",
    "  path=$1",
    "  dir=${path%/*}",
    "  if [ \"$dir\" != \"$path\" ]; then mkdir -p \"$dir\"; fi",
    "}",
    "",
    "echo \{shell_quote("MoonRobo runtime supervisor: \{plan.runtime_id}")}",
    "ensure_parent_dir \{shell_quote(plan.snapshot_path)}",
    "rm -f \{shell_quote(plan.snapshot_path)}",
  ]
  if log_path != "" {
    lines.insert(3, "exec >> \{shell_quote(log_path)} 2>&1")
  }
  match process_for_role(plan, HighControlWriter) {
    Some(writer) =>
      if writer.output_path != "" {
        lines.push("ensure_parent_dir \{shell_quote(writer.output_path)}")
        lines.push("rm -f \{shell_quote(writer.output_path)}")
      }
    None => ()
  }
  match process_for_role(plan, SnapshotCollector) {
    Some(collector) => {
      lines.push("echo \{shell_quote("starting \{collector.process_id}")}")
      lines.push(start_process_line(collector, "COLLECTOR_PID"))
      lines.push("wait_for_file \{shell_quote(plan.snapshot_path)}")
    }
    None =>
      lines.push(
        "echo 'MoonRobo supervisor: no snapshot collector process' >&2",
      )
  }
  match process_for_role(plan, HighControlWriter) {
    Some(writer) => {
      lines.push("echo \{shell_quote("starting \{writer.process_id}")}")
      lines.push(start_process_line(writer, "WRITER_PID"))
    }
    None =>
      lines.push(
        "echo 'MoonRobo supervisor: no high-control writer process' >&2",
      )
  }
  match process_for_role(plan, BridgeSidecar) {
    Some(bridge) => {
      lines.push("echo \{shell_quote("starting \{bridge.process_id}")}")
      lines.push(start_process_line(bridge, "BRIDGE_PID"))
      if bridge.health_url != "" {
        lines.push("probe_health \{shell_quote(bridge.health_url)}")
      }
      lines.push(
        "echo \{shell_quote("MoonRobo bridge ready: \{plan.bridge_base_url}")}",
      )
      lines.push("wait \"$BRIDGE_PID\"")
    }
    None =>
      lines.push("echo 'MoonRobo supervisor: no bridge sidecar process' >&2")
  }
  lines.join("\n") + "\n"
}
