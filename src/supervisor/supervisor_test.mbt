///|
fn runtime(snapshot_path : String) -> @bridge_sidecar.PhysicalRuntimeSpec {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  @bridge_sidecar.runtime_spec_for_profile(
    profile,
    "examples/noetix-e1",
    // Metadata-only fixtures. No test executes these generated commands.
    sidecar_path="/bin/sh",
    collector_path="/bin/sh",
    writer_path="/bin/sh",
    backend=Native,
    library_path="/bin/sh",
    snapshot_path~,
  )
}

///|
test "supervisor plan starts collector and writer before bridge" {
  let plan = @supervisor.plan(runtime("/tmp/moonrobo-supervisor-missing.json"))
  assert_eq(plan.status, "collector-ready")
  assert_true(plan.ready)
  assert_false(plan.snapshot_ready)
  assert_eq(plan.processes.length(), 3)
  assert_true(plan.processes[0].state == ReadyToStart)
  assert_true(plan.processes[1].state == ReadyToStart)
  assert_true(plan.processes[2].state == WaitingForSnapshot)
  assert_eq(plan.processes[0].command_resolution, "local-path")
  assert_eq(plan.processes[1].command_resolution, "local-path")
  assert_eq(plan.processes[2].command_resolution, "local-path")
  assert_eq(plan.steps.length(), 9)
  assert_true(plan.steps[1].action == StartProcess)
  assert_eq(plan.steps[1].process_id, "noetix-e1-lab-01:sdk-e1:collector")
  assert_true(plan.steps[2].action == WaitForArtifact)
  assert_true(plan.steps[2].state == Pending)
  assert_true(plan.steps[3].action == StartProcess)
  assert_eq(plan.steps[3].process_id, "noetix-e1-lab-01:sdk-e1:writer")
  assert_true(plan.steps[3].state == Ready)
  assert_true(plan.steps[4].action == StartProcess)
  assert_eq(plan.steps[4].process_id, "noetix-e1-lab-01:sdk-e1:bridge")
  assert_true(plan.steps[4].state == Pending)
  assert_eq(plan.steps[5].target, "http://127.0.0.1:5391/health")
}

///|
test "supervisor plan marks bridge ready after snapshot exists" {
  let plan = @supervisor.plan(
    runtime("/tmp/moonrobo-supervisor-ready.json"),
    snapshot_ready=true,
  )
  assert_eq(plan.status, "bridge-ready")
  assert_true(plan.snapshot_ready)
  assert_true(plan.processes[2].state == ReadyForHealthProbe)
  assert_true(plan.steps[2].state == Complete)
  assert_true(plan.steps[3].state == Ready)
  assert_true(plan.steps[4].state == Ready)
  assert_true(plan.steps[5].state == Ready)
}

///|
test "supervisor blocks structurally invalid dependencies" {
  let valid = runtime("/tmp/moonrobo-supervisor-invalid.json")
  let runtime : @bridge_sidecar.PhysicalRuntimeSpec = {
    ..valid,
    processes: [{ ..valid.processes[1], depends_on: ["missing-collector"], }],
  }
  let plan = @supervisor.plan(runtime, snapshot_ready=true)
  assert_eq(plan.status, "blocked")
  assert_false(plan.ready)
  assert_eq(plan.issues.length(), 1)
  assert_eq(plan.issues[0].code, "process-dependency-missing")
  assert_true(plan.processes[0].state == WaitingForDependency)
  assert_true(plan.steps[0].state == Blocked)
  let script = @supervisor.shell_script(plan)
  assert_true(script.contains("exit 1"))
  assert_false(script.contains("rm -f"))
  assert_false(script.contains("--watch"))
}

///|
test "supervisor shell script launches collector then bridge with cleanup trap" {
  let command_path = @bridge_sidecar.default_command_path()
  let plan = @supervisor.plan(
    runtime("/tmp/moonrobo-supervisor-script.json"),
    snapshot_ready=false,
  )
  let script = @supervisor.shell_script(
    plan,
    wait_attempts=3,
    sleep_seconds="0.01",
  )
  assert_true(script.contains("#!/usr/bin/env sh"))
  assert_true(script.contains("trap cleanup INT TERM EXIT"))
  assert_true(script.contains("ensure_parent_dir()"))
  assert_true(
    script.contains("ensure_parent_dir '/tmp/moonrobo-supervisor-script.json'"),
  )
  assert_true(script.contains("rm -f '/tmp/moonrobo-supervisor-script.json'"))
  assert_true(script.contains("ensure_parent_dir '\{command_path}'"))
  assert_true(script.contains("rm -f '\{command_path}'"))
  assert_true(script.contains("kill \"$BRIDGE_PID\""))
  assert_true(script.contains("kill \"$WRITER_PID\""))
  assert_true(script.contains("kill \"$COLLECTOR_PID\""))
  assert_true(script.contains("'/bin/sh' 'read' '--live'"))
  assert_true(
    script.contains("wait_for_file '/tmp/moonrobo-supervisor-script.json'"),
  )
  assert_true(script.contains("'/bin/sh' 'write' '--watch'"))
  assert_true(script.contains("'--input' '\{command_path}'"))
  assert_true(script.contains("'/bin/sh' 'serve' 'examples/noetix-e1'"))
  assert_true(script.contains("probe_health 'http://127.0.0.1:5391/health'"))
  assert_true(script.contains("wait \"$BRIDGE_PID\""))
  assert_false(script.contains("python3"))
}

///|
test "supervisor resolves PATH files and executable permissions without launching" {
  assert_eq(
    @supervisor.resolve_executable("sh", search_path="/bin"),
    Some("/bin/sh"),
  )
  assert_eq(
    @supervisor.resolve_executable(
      "moonrobo-definitely-uninstalled-spec-fixture",
      search_path="/bin:/usr/bin",
    ),
    None,
  )
  assert_eq(@supervisor.resolve_executable("/"), None)
  assert_eq(
    @supervisor.resolve_executable("src/supervisor/supervisor.mbt"),
    None,
  )
  let valid = runtime("/tmp/native-missing-snapshot.json")
  let missing : @bridge_sidecar.PhysicalRuntimeSpec = {
    ..valid,
    processes: [
      {
        ..valid.processes[0],
        command: ["moonrobo-definitely-uninstalled-spec-fixture"],
      },
      valid.processes[1],
      valid.processes[2],
    ],
  }
  let plan = @supervisor.plan(missing, snapshot_ready=true)
  assert_false(plan.ready)
  assert_true(plan.processes[0].state is MissingCommand)
  assert_false(plan.processes[0].command_available)
  let absent_library = @bridge_sidecar.runtime_spec_for_profile(
    @core.noetix_e1_profile("missing-adapter-fixture", "Fixture"),
    "examples/noetix-e1",
    backend=Native,
    sidecar_path="/bin/sh",
    collector_path="/bin/sh",
    writer_path="/bin/sh",
    library_path="/definitely-missing/moonrobo-sdk-e1.so",
  )
  let blocked = @supervisor.plan(absent_library, snapshot_ready=true)
  assert_false(blocked.ready)
  assert_true(blocked.processes[0].command_available)
  assert_true(blocked.processes[0].state is MissingRuntimeDependency)
  assert_true(
    blocked.processes[0].detail.contains(
      "/definitely-missing/moonrobo-sdk-e1.so",
    ),
  )
  assert_true(
    blocked.processes[0].detail.contains(
      "SDK C ABI and live readiness have not been probed",
    ),
  )
  let blocked_script = @supervisor.shell_script(blocked)
  assert_true(blocked_script.contains("exit 1"))
  assert_true(blocked_script.contains("/definitely-missing/moonrobo-sdk-e1.so"))
  assert_true(
    blocked_script.contains("[ -f \"$4\" ] && [ -r \"$4\" ] || exit 1"),
  )
  assert_true(blocked_script.contains("no processes started"))
  assert_true(
    blocked_script.split("rm -f").to_array()[0].contains("preflight_process"),
  )
}

///|
test "supervisor shell script quotes command arguments" {
  let valid = runtime("/tmp/moonrobo-supervisor-quote.json")
  let runtime : @bridge_sidecar.PhysicalRuntimeSpec = {
    ..valid,
    processes: [
      {
        ..valid.processes[0],
        command: ["/bin/sh", "bridge with space", "value'quoted"],
      },
      valid.processes[1],
    ],
  }
  let script = @supervisor.shell_script(
    @supervisor.plan(runtime, snapshot_ready=true),
  )
  assert_true(script.contains("'bridge with space'"))
  assert_true(script.contains("'value'\"'\"'quoted'"))
}
