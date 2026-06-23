///|
fn runtime(snapshot_path : String) -> @bridge_sidecar.PhysicalRuntimeSpec {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  @bridge_sidecar.runtime_spec_for_profile(
    profile,
    "examples/noetix-e1",
    sidecar_path="moonrobo-sdk-e1-bridge",
    collector_path="bridges/sdk_e1/sdk_e1_readonly_bridge.py",
    snapshot_path~,
  )
}

///|
test "supervisor plan starts collector before bridge and waits for snapshot" {
  let plan = @supervisor.plan(runtime("/tmp/moonrobo-supervisor-missing.json"))
  assert_eq(plan.status, "collector-ready")
  assert_true(plan.ready)
  assert_false(plan.snapshot_ready)
  assert_eq(plan.processes.length(), 2)
  assert_true(plan.processes[0].state == ReadyToStart)
  assert_true(plan.processes[1].state == WaitingForSnapshot)
  assert_eq(plan.processes[0].command_resolution, "search-path")
  assert_eq(plan.processes[1].command_resolution, "search-path")
  assert_eq(plan.steps.length(), 7)
  assert_true(plan.steps[1].action == StartProcess)
  assert_eq(plan.steps[1].process_id, "noetix-e1-lab-01:sdk-e1:collector")
  assert_true(plan.steps[2].action == WaitForArtifact)
  assert_true(plan.steps[2].state == Pending)
  assert_true(plan.steps[3].action == StartProcess)
  assert_eq(plan.steps[3].process_id, "noetix-e1-lab-01:sdk-e1:bridge")
  assert_true(plan.steps[3].state == Pending)
  assert_eq(plan.steps[4].target, "http://127.0.0.1:5391/health")
}

///|
test "supervisor plan marks bridge ready after snapshot exists" {
  let plan = @supervisor.plan(
    runtime("/tmp/moonrobo-supervisor-ready.json"),
    snapshot_ready=true,
  )
  assert_eq(plan.status, "bridge-ready")
  assert_true(plan.snapshot_ready)
  assert_true(plan.processes[1].state == ReadyForHealthProbe)
  assert_true(plan.steps[2].state == Complete)
  assert_true(plan.steps[3].state == Ready)
  assert_true(plan.steps[4].state == Ready)
}

///|
test "supervisor blocks structurally invalid dependencies" {
  let valid = runtime("/tmp/moonrobo-supervisor-invalid.json")
  let runtime : @bridge_sidecar.PhysicalRuntimeSpec = {
    ..valid,
    processes: [{ ..valid.processes[1], depends_on: ["missing-collector"] }],
  }
  let plan = @supervisor.plan(runtime, snapshot_ready=true)
  assert_eq(plan.status, "blocked")
  assert_false(plan.ready)
  assert_eq(plan.issues.length(), 1)
  assert_eq(plan.issues[0].code, "process-dependency-missing")
  assert_true(plan.processes[0].state == WaitingForDependency)
  assert_true(plan.steps[0].state == Blocked)
}
