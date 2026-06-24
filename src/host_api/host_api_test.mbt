///|
test "host api emits cockpit snapshot response" {
  let response = @host_api.snapshot_response("examples/noetix-e1")
  assert_eq(response.status, 200)
  assert_eq(response.content_type, "application/json")
  assert_true(response.body.contains("\"robot_id\": \"noetix-e1-lab-01\""))
  assert_true(response.body.contains("\"decision\": \"dry-run-required\""))
}

///|
test "host api routes health and missing paths" {
  let health = @host_api.route(
    "examples/noetix-e1",
    "GET",
    @host_api.health_path(),
  )
  assert_eq(health.status, 200)
  assert_true(
    health.body.contains("\"snapshot_path\": \"/api/cockpit/snapshot\""),
  )
  let missing = @host_api.route("examples/noetix-e1", "GET", "/missing")
  assert_eq(missing.status, 404)
  assert_true(missing.body.contains("\"code\": \"not-found\""))
}

///|
test "host api exposes persisted tool registry" {
  let root = "/tmp/moonrobo-host-api-tool-registry-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.tool_registry_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"registry_path\""))
  assert_true(response.body.contains("\"provider_id\": \"moonrobo-host-api\""))
  assert_true(
    response.body.contains("\"provider_id\": \"moonclaw-process-planner\""),
  )
  let registry = @runtime.read_tool_registry(root).unwrap()
  assert_eq(registry.provider_count, 3)
  assert_eq(registry.capability_count, 14)
  assert_true(
    response.body.contains("\"route\": \"/api/moonbook/conversation\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonclaw/task-loop\""))
}

///|
test "host api emits platform readiness report" {
  let root = "/tmp/moonrobo-host-api-readiness-test"
  prepare_submission_root(root)
  let response = @host_api.route(
    root,
    "GET",
    @host_api.platform_readiness_path(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"report\""))
  assert_true(response.body.contains("\"plan\""))
  assert_true(response.body.contains("\"status\": \"blocked\""))
  assert_true(response.body.contains("\"robobook-ready\""))
  assert_true(response.body.contains("\"tool-registry-ready\""))
  assert_true(response.body.contains("\"needs-action\""))
  assert_true(response.body.contains("\"persist-bounded-tool-registry\""))
}

///|
fn complete_required_paths(root : String) -> Unit raise {
  ensure_dir(root + "/safety")
  ensure_dir(root + "/bridge")
  @fsx.write_string_to_file(root + "/safety/policy.json", "{}") catch {
    _ => fail("failed to write safety policy")
  }
  @fsx.write_string_to_file(root + "/bridge/bridge.json", "{}") catch {
    _ => fail("failed to write bridge config")
  }
}

///|
test "host api bootstraps non-physical platform readiness substrate" {
  let root = "/tmp/moonrobo-host-api-platform-bootstrap-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let before = @host_api.route(root, "GET", @host_api.platform_readiness_path())
  assert_eq(before.status, 200)
  assert_true(before.body.contains("\"pass_count\": 3"))
  assert_true(before.body.contains("\"fail_count\": 5"))
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_bootstrap_path(),
    "{}",
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"persist-bounded-tool-registry\""))
  assert_true(response.body.contains("\"persist-first-task-message\""))
  assert_true(response.body.contains("\"persist-moonbook-robot-memory\""))
  assert_true(response.body.contains("\"physical_execution_allowed\": false"))
  let after = @host_api.route(root, "GET", @host_api.platform_readiness_path())
  assert_eq(after.status, 200)
  assert_true(after.body.contains("\"pass_count\": 6"))
  assert_true(after.body.contains("\"fail_count\": 2"))
  assert_true(after.body.contains("\"runtime-health-ready\""))
  assert_true(after.body.contains("\"task-execution-ready\""))
  assert_true(@fsx.path_exists(root + "/agents/tool-registry.json"))
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-bootstrap-first-task.json",
    ),
  )
}

///|
test "host api advances reviewed task message until runtime is required" {
  let root = "/tmp/moonrobo-host-api-platform-advance-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let bootstrap = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_bootstrap_path(),
    "{}",
  )
  assert_eq(bootstrap.status, 200)
  let evaluate = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_advance_path(),
    "{}",
  )
  assert_eq(evaluate.status, 200)
  assert_true(evaluate.body.contains("\"advanced\": true"))
  assert_true(evaluate.body.contains("\"kind\": \"evaluate-command-message\""))
  assert_true(evaluate.body.contains("\"stage\": \"needs-dry-run\""))
  let dry_run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_advance_path(),
    "{}",
  )
  assert_eq(dry_run.status, 200)
  assert_true(dry_run.body.contains("\"kind\": \"dry-run-command-message\""))
  assert_true(dry_run.body.contains("\"stage\": \"needs-approval\""))
  let approval = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_advance_path(),
    "{}",
  )
  assert_eq(approval.status, 200)
  assert_true(approval.body.contains("\"kind\": \"approve-command-message\""))
  assert_true(approval.body.contains("\"stage\": \"runtime-required\""))
  let execute = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_advance_path(),
    "{}",
  )
  assert_eq(execute.status, 409)
  assert_true(execute.body.contains("\"blocked\": true"))
  assert_true(execute.body.contains("\"code\": \"runtime-required\""))
  assert_true(execute.body.contains("\"kind\": \"execute-command-message\""))
  assert_true(!execute.body.contains("\"bridge_dispatch\""))
  let readiness = @host_api.route(
    root,
    "GET",
    @host_api.platform_readiness_path(),
  )
  assert_eq(readiness.status, 200)
  assert_true(readiness.body.contains("\"pass_count\": 6"))
  assert_true(readiness.body.contains("\"fail_count\": 2"))
}

///|
test "host api first-loop bootstraps and advances until runtime proof is required" {
  let root = "/tmp/moonrobo-host-api-first-loop-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_first_loop_path(),
    "{}",
  )
  assert_eq(response.status, 409)
  assert_true(response.body.contains("\"stopped_reason\": \"advance-blocked\""))
  assert_true(response.body.contains("\"step_id\": \"bootstrap\""))
  assert_true(
    response.body.contains("\"step_id\": \"evaluate-command-message\""),
  )
  assert_true(
    response.body.contains("\"step_id\": \"dry-run-command-message\""),
  )
  assert_true(
    response.body.contains("\"step_id\": \"approve-command-message\""),
  )
  assert_true(
    response.body.contains("\"step_id\": \"execute-command-message\""),
  )
  assert_true(response.body.contains("\"stage\": \"runtime-required\""))
  assert_true(response.body.contains("\"runtime-required\""))
  assert_true(response.body.contains("\"pass_count\": 6"))
  assert_true(response.body.contains("\"fail_count\": 2"))
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-bootstrap-first-task.json",
    ),
  )
}

///|
test "host api rejects runtime proof without matching identity or active supervisor" {
  let root = "/tmp/moonrobo-host-api-runtime-proof-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let wrong_robot_request : @host_api.PlatformRuntimeProofRequest = {
    telemetry: @core.empty_telemetry_frame(
      "frame-wrong-robot", "other-robot", "sdk-e1", 5000L,
    ),
  }
  let wrong_robot = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_runtime_proof_path(),
    wrong_robot_request.to_json().stringify(),
  )
  assert_eq(wrong_robot.status, 409)
  assert_true(wrong_robot.body.contains("runtime-proof-robot-mismatch"))
  let wrong_bridge_request : @host_api.PlatformRuntimeProofRequest = {
    telemetry: @core.empty_telemetry_frame(
      "frame-wrong-bridge", "noetix-e1-lab-01", "other-bridge", 5001L,
    ),
  }
  let wrong_bridge = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_runtime_proof_path(),
    wrong_bridge_request.to_json().stringify(),
  )
  assert_eq(wrong_bridge.status, 409)
  assert_true(wrong_bridge.body.contains("runtime-proof-bridge-mismatch"))
  let matching_request : @host_api.PlatformRuntimeProofRequest = {
    telemetry: @core.empty_telemetry_frame(
      "frame-matching", "noetix-e1-lab-01", "sdk-e1", 5002L,
    ),
  }
  let matching = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_runtime_proof_path(),
    matching_request.to_json().stringify(),
  )
  assert_eq(matching.status, 409)
  assert_true(matching.body.contains("runtime-proof-no-runtime-health"))
  assert_true(!@fsx.path_exists(root + "/runs/runtime-health/latest.json"))
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        5001L, "running-unprobed", true, true, 42, "launch-runtime-proof-host", "noetix-e1-lab-01:sdk-e1",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", false, "unknown",
        "runtime process is running; telemetry has not been probed", "", "", 0L,
      ),
    ),
  )
  let accepted = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_runtime_proof_path(),
    matching_request.to_json().stringify(),
  )
  assert_eq(accepted.status, 200)
  assert_true(accepted.body.contains("\"persisted\": true"))
  assert_true(accepted.body.contains("\"status\": \"healthy\""))
  assert_true(accepted.body.contains("\"runtime_ready\": true"))
  assert_true(accepted.body.contains("\"previous_record\""))
  assert_true(
    accepted.body.contains(
      "\"telemetry_path\": \"\{root}/runs/telemetry/runtime-proof/frame-matching.json\"",
    ),
  )
  assert_true(@fsx.path_exists(root + "/runs/runtime-health/latest.json"))
  assert_true(
    @fsx.path_exists(root + "/runs/telemetry/runtime-proof/frame-matching.json"),
  )
}

///|
test "host api registers bounded tool provider" {
  let root = "/tmp/moonrobo-host-api-tool-register-test"
  prepare_submission_root(root)
  let provider = @tool_registry.rabbita_cockpit_provider(
    "noetix-e1-lab-01", 99L,
  )
  let request : @host_api.ToolRegistrationRequest = { provider, now_ms: 99L }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.tool_register_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"registered_at_ms\": \"99\""))
  assert_true(
    response.body.contains("\"provider_id\": \"rabbita-operator-cockpit\""),
  )
}

///|
test "host api emits bridge sidecar manifest" {
  let response = @host_api.route(
    "examples/noetix-e1",
    "GET",
    @host_api.bridge_sidecar_path(),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"sidecar_id\": \"noetix-e1-lab-01:sdk-e1\""),
  )
  assert_true(response.body.contains("\"spec\""))
  assert_true(response.body.contains("\"status\""))
  assert_true(response.body.contains("\"runtime\""))
  assert_true(response.body.contains("\"state\": \"MissingCommand\""))
  assert_true(response.body.contains("\"health_path\": \"/health\""))
  assert_true(response.body.contains("\"execute_path\": \"/intents/execute\""))
  assert_true(
    response.body.contains("\"snapshot_path\": \"/tmp/moonrobo-sdk-e1.json\""),
  )
  assert_true(response.body.contains("/tmp/moonrobo-sdk-e1-command.json"))
  assert_true(response.body.contains("\"role\": \"SnapshotCollector\""))
  assert_true(response.body.contains("\"role\": \"HighControlWriter\""))
  assert_true(response.body.contains("\"role\": \"BridgeSidecar\""))
}

///|
test "host api emits physical runtime supervisor plan" {
  let response = @host_api.route(
    "examples/noetix-e1",
    "GET",
    @host_api.runtime_supervisor_path(),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"runtime_id\": \"noetix-e1-lab-01:sdk-e1\""),
  )
  assert_true(
    response.body.contains("\"snapshot_path\": \"/tmp/moonrobo-sdk-e1.json\""),
  )
  assert_true(response.body.contains("/tmp/moonrobo-sdk-e1-command.json"))
  assert_true(response.body.contains("\"action\": \"StartProcess\""))
  assert_true(response.body.contains("\"action\": \"WaitForArtifact\""))
  assert_true(
    response.body.contains("\"target\": \"http://127.0.0.1:5391/health\""),
  )
}

///|
test "host api emits physical runtime supervisor script" {
  let response = @host_api.route(
    "examples/noetix-e1",
    "GET",
    @host_api.runtime_supervisor_script_path(),
  )
  assert_eq(response.status, 200)
  assert_eq(response.content_type, "text/plain")
  assert_true(response.body.contains("#!/usr/bin/env sh"))
  assert_true(
    response.body.contains("wait_for_file '/tmp/moonrobo-sdk-e1.json'"),
  )
  assert_true(
    response.body.contains("probe_health 'http://127.0.0.1:5391/health'"),
  )
  assert_true(response.body.contains("kill \"$BRIDGE_PID\""))
  assert_true(response.body.contains("kill \"$COLLECTOR_PID\""))
}

///|
test "host api prepares physical runtime supervisor launch receipt" {
  let root = "/tmp/moonrobo-host-runtime-launch-test"
  prepare_submission_root(root)
  let response = @host_api.route(
    root,
    "POST",
    @host_api.runtime_supervisor_launch_path(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": ["))
  assert_true(
    response.body.contains("\"bridge_base_url\": \"http://127.0.0.1:5391\""),
  )
  assert_true(
    @fsx.path_exists(
      root +
      "/runs/runtime-supervisor/runtime-supervisor-noetix-e1-lab-01:sdk-e1.sh",
    ),
  )
  assert_true(
    @fsx.path_exists(
      root +
      "/runs/runtime-supervisor/runtime-supervisor-noetix-e1-lab-01:sdk-e1.json",
    ),
  )
}

///|
test "host api emits moontown resident projection" {
  let root = "/tmp/moonrobo-host-api-resident-test"
  prepare_submission_root(root)
  let _started = @host_api.route_with_body(
    root,
    "POST",
    @host_api.observation_start_path(),
    observation_start_json(
      "observe-session-resident", "receipt-observe-resident",
    ),
  )
  let response = @host_api.route(root, "GET", @host_api.resident_path())
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"resident_id\": \"robot:noetix-e1-lab-01\""),
  )
  assert_true(response.body.contains("\"role\": \"physical-robot\""))
  assert_true(response.body.contains("\"availability\": \"observing\""))
  assert_true(
    response.body.contains("\"session_id\": \"observe-session-resident\""),
  )
}

///|
test "host api emits process review queue" {
  let root = "/tmp/moonrobo-host-api-review-queue-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("standing-goal-review-queue", 2),
  )
  let response = @host_api.route(root, "GET", @host_api.reviews_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"review_count\": 1"))
  assert_true(response.body.contains("\"needs_human_count\": 0"))
  assert_true(
    response.body.contains(
      "\"review_id\": \"review-task-standing-goal-review-queue-observe\"",
    ),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.review_path("review-task-standing-goal-review-queue-observe"),
  )
  assert_eq(detail.status, 200)
  assert_true(
    detail.body.contains(
      "\"session_id\": \"task-standing-goal-review-queue-observe\"",
    ),
  )
}

///|
test "host api emits moonclaw context plan" {
  let root = "/tmp/moonrobo-host-api-moonclaw-context-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"pack_id\""))
  assert_true(response.body.contains("\"action\": \"Observe\""))
  assert_true(response.body.contains("/api/moontown/tasks/observe-run"))
  assert_true(response.body.contains("\"memory\""))
  assert_true(response.body.contains("moonbook-memory-noetix-e1-lab-01-0"))
  assert_true(response.body.contains("\"tool_registry\""))
  assert_true(response.body.contains("/api/moonbook/conversation"))
}

///|
test "host api moonclaw context prioritizes runtime revalidation" {
  let root = "/tmp/moonrobo-host-api-moonclaw-revalidation-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8100L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"action\": \"RemediateReadiness\""))
  assert_true(response.body.contains("\"readiness\""))
  assert_true(response.body.contains("\"readiness_plan\""))
  assert_true(
    response.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  assert_true(response.body.contains("\"runtime-validation-current\""))
}

///|
test "host api runtime validation session writes gateway evidence" {
  let root = "/tmp/moonrobo-host-api-runtime-validation-session-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8150L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.runtime_validation_session_path(),
    "",
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"ready_for_live_sdk\": true"))
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
  )
  let context = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(context.status, 200)
  assert_true(context.body.contains("\"action\": \"Observe\""))
}

///|
test "host api emits moonstat status projection" {
  let root = "/tmp/moonrobo-host-api-moonstat-status-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="moonstat-host-run",
      goal="host api moonstat status",
      now_ms=9100L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let response = @host_api.route(root, "GET", @host_api.moonstat_status_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"service\": \"moonrobo\""))
  assert_true(response.body.contains("\"status\": \"not-ready\""))
  assert_true(response.body.contains("\"receipt_count\": 2"))
  assert_true(response.body.contains("\"observation_count\": 1"))
  assert_true(response.body.contains("\"process_review_count\": 1"))
  assert_true(response.body.contains("\"agent_process_run_count\": 1"))
  assert_true(
    response.body.contains(
      "\"latest_evidence_path\": \"/api/moonclaw/runs/agent-process-moonstat-host-run-9100\"",
    ),
  )
}

///|
test "host api projects agent work queue from replay evidence" {
  let root = "/tmp/moonrobo-host-api-work-queue-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="work-queue-host-run",
      goal="host api work queue",
      now_ms=9400L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let response = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"queue_id\": \"work-queue-noetix-e1-lab-01-0\""),
  )
  assert_true(response.body.contains("\"kind\": \"connect-bridge\""))
  assert_true(response.body.contains("\"kind\": \"annotate-replay\""))
  assert_true(
    response.body.contains(
      "\"target_path\": \"/api/replays/task-work-queue-host-run-observe/annotations\"",
    ),
  )
  let next = @host_api.route(root, "GET", @host_api.agent_next_action_path())
  assert_eq(next.status, 200)
  assert_true(next.body.contains("\"action\""))
  assert_true(next.body.contains("\"kind\": \"connect-bridge\""))
  assert_true(next.body.contains("\"http_method\": \"GET\""))
  assert_true(next.body.contains("\"route\": \"/api/bridge/sidecar\""))
  assert_true(next.body.contains("\"body_schema\": \"none\""))
  assert_true(!next.body.contains("\"body_template\""))
  assert_true(next.body.contains("\"physical_execution_allowed\": false"))
}

///|
test "host api projects runtime calibration plan into agent work queue" {
  let root = "/tmp/moonrobo-host-api-runtime-calibration-work-test"
  prepare_submission_root(root)
  ignore(
    @runtime.write_runtime_calibration_plan(
      root,
      "runtime-calibration-host",
      (
        #|{
        #|  "plan_id": "runtime-calibration-host",
        #|  "generated_at_ms": "9800",
        #|  "session_id": "runtime-validation-session-host",
        #|  "runtime_id": "runtime-noetix-e1-lab-01:sdk-e1",
        #|  "robot_id": "noetix-e1-lab-01",
        #|  "bridge_id": "sdk-e1",
        #|  "status": "needs-calibration",
        #|  "action_count": 1,
        #|  "blocking_action_count": 1,
        #|  "actions": [
        #|    {
        #|      "action_id": "calibrate-runtime-process",
        #|      "blocker_code": "runtime-active",
        #|      "severity": "blocker",
        #|      "owner": "runtime",
        #|      "evidence_path": "/api/runtime/validation",
        #|      "summary": "Physical runtime supervisor is not active",
        #|      "next_step": "Start the runtime supervisor and refresh validation before dispatching physical tasks"
        #|    }
        #|  ]
        #|}
      ),
    ),
  )
  let response = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"kind\": \"calibrate-runtime\""))
  assert_true(
    response.body.contains(
      "\"target_path\": \"/api/agent/runtime-calibration/latest\"",
    ),
  )
  assert_true(response.body.contains("\"priority\": 95"))
  let calibration = @host_api.route(
    root,
    "GET",
    @host_api.agent_runtime_calibration_path(),
  )
  assert_eq(calibration.status, 200)
  assert_true(
    calibration.body.contains("\"plan_id\": \"runtime-calibration-host\""),
  )
  assert_true(calibration.body.contains("\"blocker_code\": \"runtime-active\""))
  let resolved = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_runtime_calibration_resolve_path(),
    (
      #|{
      #|  "action_id": "calibrate-runtime-process",
      #|  "resolved_by": "operator",
      #|  "resolved_at_ms": "9900",
      #|  "note": "started runtime supervisor and reran bridge checks"
      #|}
    ),
  )
  assert_eq(resolved.status, 200)
  assert_true(resolved.body.contains("\"persisted\": true"))
  assert_true(
    resolved.body.contains(
      "\"resolution_id\": \"runtime-calibration-resolution-calibrate-runtime-process-9900\"",
    ),
  )
  assert_true(
    resolved.body.contains(
      "\"next_validation_route\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_calibration_resolution_path(root)),
  )
  let after_resolution = @host_api.route(
    root,
    "GET",
    @host_api.agent_work_queue_path(),
  )
  assert_eq(after_resolution.status, 200)
  assert_true(after_resolution.body.contains("\"kind\": \"validate-runtime\""))
  assert_true(
    after_resolution.body.contains(
      "\"target_path\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(after_resolution.body.contains("\"priority\": 101"))
  let next_after_resolution = @host_api.route(
    root,
    "GET",
    @host_api.agent_next_action_path(),
  )
  assert_eq(next_after_resolution.status, 200)
  assert_true(
    next_after_resolution.body.contains("\"kind\": \"validate-runtime\""),
  )
  assert_true(
    next_after_resolution.body.contains(
      "\"route\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(
    next_after_resolution.body.contains(
      "\"execution_mode\": \"operator-validation\"",
    ),
  )
  ignore(
    @runtime.write_runtime_validation_session(
      root,
      "runtime-validation-session-ready",
      (
        #|{
        #|  "session_id": "runtime-validation-session-ready",
        #|  "generated_at_ms": "10000",
        #|  "runtime_id": "runtime-noetix-e1-lab-01:sdk-e1",
        #|  "robot_id": "noetix-e1-lab-01",
        #|  "bridge_id": "sdk-e1",
        #|  "status": "ready",
        #|  "ready_for_live_sdk": true,
        #|  "required_sample_count": 1,
        #|  "sample_count": 1,
        #|  "ready_sample_count": 1,
        #|  "blocked_sample_count": 0,
        #|  "first_blocker_code": "",
        #|  "report_ids": [],
        #|  "reports": []
        #|}
      ),
    ),
  )
  let after_ready_validation = @host_api.route(
    root,
    "GET",
    @host_api.agent_work_queue_path(),
  )
  assert_eq(after_ready_validation.status, 200)
  assert_true(
    !after_ready_validation.body.contains("\"kind\": \"validate-runtime\""),
  )
  assert_true(
    !after_ready_validation.body.contains("\"kind\": \"calibrate-runtime\""),
  )
}

///|
test "host api projects and persists MoonBook memory" {
  let root = "/tmp/moonrobo-host-api-moonbook-memory-test"
  prepare_submission_root(root)
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        9400L, "bridge-unhealthy", true, true, 42, "launch-memory-host", "runtime-memory-host",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", false, "bridge-connect-failed",
        "failed to connect", "/telemetry/latest", "", 0L,
      ),
    ),
  )
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="moonbook-memory-host-run",
      goal="host api moonbook memory",
      now_ms=9500L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let projected = @host_api.route(root, "GET", @host_api.moonbook_memory_path())
  assert_eq(projected.status, 200)
  assert_true(projected.body.contains("\"persisted\": false"))
  assert_true(projected.body.contains("\"kind\": \"resident-state\""))
  assert_true(projected.body.contains("\"kind\": \"latest-observation\""))
  assert_true(projected.body.contains("\"kind\": \"next-work\""))
  assert_true(projected.body.contains("\"kind\": \"runtime-health\""))
  assert_true(
    projected.body.contains("\"next_route\": \"/api/runtime/health\""),
  )
  let remembered = @host_api.route(
    root,
    "POST",
    @host_api.moonbook_remember_path(),
  )
  assert_eq(remembered.status, 200)
  assert_true(remembered.body.contains("\"persisted\": true"))
  assert_true(
    remembered.body.contains(
      "\"memory_path\": \"\{root}/moonbook/memory/moonbook-memory-noetix-e1-lab-01-0.json\"",
    ),
  )
  let text = @fsx.read_file_to_string(
    root + "/moonbook/memory/moonbook-memory-noetix-e1-lab-01-0.json",
  ) catch {
    _ => fail("failed to read persisted MoonBook memory")
  }
  assert_true(text.contains("\"card_count\""))
  assert_true(text.contains("\"next_route\": \"/api/agent/next-action\""))
}

///|
test "host api accepts task message and persists MoonBook memory" {
  let root = "/tmp/moonrobo-host-api-task-message-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    task_message_json("inspect-desk", "Inspect the desk and report telemetry"),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"message_id\": \"inspect-desk\""))
  assert_true(
    response.body.contains(
      "\"message_path\": \"\{root}/moonbook/task-messages/message-inspect-desk.json\"",
    ),
  )
  assert_true(response.body.contains("\"classification\": \"observation\""))
  assert_true(response.body.contains("\"task_id\": \"message-inspect-desk\""))
  assert_true(
    response.body.contains(
      "\"session_id\": \"task-message-inspect-desk-observe\"",
    ),
  )
  assert_true(response.body.contains("\"memory_path\""))
  assert_true(response.body.contains("\"kind\": \"latest-observation\""))
  let text = @fsx.read_file_to_string(
    root + "/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
  ) catch {
    _ => fail("failed to read task-message memory pack")
  }
  assert_true(text.contains("task-message-inspect-desk-observe"))
  let message_text = @fsx.read_file_to_string(
    root + "/moonbook/task-messages/message-inspect-desk.json",
  ) catch {
    _ => fail("failed to read task-message plan")
  }
  assert_true(message_text.contains("\"classification\": \"observation\""))
}

///|
test "host api accepts physical action task message for review only" {
  let root = "/tmp/moonrobo-host-api-task-message-safety-queue-test-v2"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    task_message_json("walk-queue-now", "walk forward"),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"classification\": \"command-intent-review\""),
  )
  assert_true(response.body.contains("\"physical_execution_allowed\": false"))
  assert_true(response.body.contains("\"requires_review\": true"))
  assert_true(response.body.contains("\"route\": \"/api/intents/evaluate\""))
  assert_true(response.body.contains("\"intent_draft\""))
  assert_true(
    response.body.contains("\"intent_id\": \"intent-message-walk-queue-now\""),
  )
  assert_true(!response.body.contains("\"session_id\""))
  let message_text = @fsx.read_file_to_string(
    root + "/moonbook/task-messages/message-walk-queue-now.json",
  ) catch {
    _ => fail("failed to read physical task-message plan")
  }
  assert_true(
    message_text.contains("\"classification\": \"command-intent-review\""),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_path("message-walk-queue-now"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"message_path\""))
  assert_true(detail.body.contains("\"task_id\": \"message-walk-queue-now\""))
  let initial_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-walk-queue-now"),
  )
  assert_eq(initial_status.status, 200)
  assert_true(initial_status.body.contains("\"stage\": \"needs-evaluation\""))
  assert_true(
    initial_status.body.contains(
      "\"next_route\": \"/api/moonbook/task-messages/message-walk-queue-now/evaluate\"",
    ),
  )
  let evaluated = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_evaluate_path("message-walk-queue-now"),
    "",
  )
  assert_eq(evaluated.status, 200)
  assert_true(evaluated.body.contains("\"persisted\": true"))
  assert_true(evaluated.body.contains("\"message_plan\""))
  assert_true(
    evaluated.body.contains("\"intent_id\": \"intent-message-walk-queue-now\""),
  )
  assert_true(evaluated.body.contains("\"next_action\": \"CollectDryRun\""))
  assert_true(
    evaluated.body.contains(
      "\"receipt_path\": \"\{root}/runs/receipts/receipt-message-walk-queue-now-review.json\"",
    ),
  )
  let dry_run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_dry_run_path("message-walk-queue-now"),
    "",
  )
  assert_eq(dry_run.status, 200)
  assert_true(
    dry_run.body.contains(
      "\"dry_run_receipt_id\": \"dry-run-intent-message-walk-queue-now-3000\"",
    ),
  )
  assert_true(
    dry_run.body.contains(
      "\"dry_run_path\": \"\{root}/runs/dry-runs/dry-run-intent-message-walk-queue-now-3000.json\"",
    ),
  )
  let approved = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_approve_path("message-walk-queue-now"),
    "",
  )
  assert_eq(approved.status, 200)
  assert_true(
    approved.body.contains(
      "\"approval_id\": \"approval-intent-message-walk-queue-now-3000\"",
    ),
  )
  assert_true(approved.body.contains("\"next_action\": \"RequestApproval\""))
  let ready_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-walk-queue-now"),
  )
  assert_eq(ready_status.status, 200)
  assert_true(ready_status.body.contains("\"stage\": \"ready-to-dispatch\""))
  assert_true(ready_status.body.contains("\"approved\": true"))
  let executed = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_execute_path("message-walk-queue-now"),
    "",
  )
  assert_eq(executed.status, 200)
  assert_true(executed.body.contains("\"bridge_response\""))
  assert_true(executed.body.contains("\"bridge_dispatch\""))
  assert_true(executed.body.contains("\"memory_path\""))
  assert_true(
    executed.body.contains(
      "\"memory_path\": \"\{root}/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json\"",
    ),
  )
  assert_true(
    executed.body.contains(
      "\"dispatch_path\": \"\{root}/runs/bridge-dispatches/dispatch-request-execute-intent-message-walk-queue-now-3000.json\"",
    ),
  )
  assert_true(executed.body.contains("\"next_action\": \"Execute\""))
  assert_true(executed.body.contains("\"status\": \"Executed\""))
  let dispatch = @runtime.read_bridge_dispatch_evidence(
    root, "dispatch-request-execute-intent-message-walk-queue-now-3000",
  ).unwrap()
  assert_eq(dispatch.operation, "ExecuteIntent")
  assert_eq(dispatch.path, "/intents/execute")
  let memory = @fsx.read_file_to_string(
    root + "/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
  ) catch {
    _ => fail("failed to read completed task-message memory pack")
  }
  assert_true(memory.contains("moonbook-memory-noetix-e1-lab-01-3000"))
  let final_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-walk-queue-now"),
  )
  assert_eq(final_status.status, 200)
  assert_true(final_status.body.contains("\"stage\": \"completed\""))
  assert_true(final_status.body.contains("\"executed\": true"))
  assert_true(final_status.body.contains("\"bridge_status\": \"Accepted\""))
  let list = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_messages_path(),
  )
  assert_eq(list.status, 200)
  assert_true(list.body.contains("\"message_count\": 1"))
  assert_true(list.body.contains("\"status\""))
  assert_true(list.body.contains("\"stage\": \"completed\""))
  assert_true(list.body.contains("\"executed\": true"))
  assert_true(list.body.contains("\"next_route\": \"\""))
  let conversation = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_conversation_path(),
  )
  assert_eq(conversation.status, 200)
  assert_true(
    conversation.body.contains("\"thread_id\": \"moonbook-task-messages\""),
  )
  assert_true(conversation.body.contains("\"turn_count\": 1"))
  assert_true(
    conversation.body.contains("\"latest_task_id\": \"message-walk-queue-now\""),
  )
  assert_true(conversation.body.contains("\"user_text\": \"walk forward\""))
  assert_true(conversation.body.contains("\"stage\": \"completed\""))
  assert_true(conversation.body.contains("\"robo_text\""))
}

///|
test "host api task loop accepts message and advances bounded gates" {
  let root = "/tmp/moonrobo-host-api-task-loop-test"
  prepare_submission_root(root)
  let request : @host_api.PlatformTaskLoopRequest = {
    task_message: @task.task_message_request(
      "loop-walk-now",
      "",
      @core.operator_requester("rabbita"),
      "walk forward",
      3000L,
    ),
    max_steps: 6,
    allow_dispatch: false,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_task_loop_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 409)
  assert_true(response.body.contains("\"submitted\": true"))
  assert_true(response.body.contains("\"continued\": false"))
  assert_true(response.body.contains("\"dispatch_requested\": false"))
  assert_true(response.body.contains("\"task_id\": \"message-loop-walk-now\""))
  assert_true(
    response.body.contains("\"classification\": \"command-intent-review\""),
  )
  assert_true(response.body.contains("\"first_loop_status\": 409"))
  assert_true(response.body.contains("\"execution_proof\""))
  assert_true(response.body.contains("\"execution_count\": 0"))
  assert_true(response.body.contains("\"stopped_reason\": \"advance-blocked\""))
  assert_true(response.body.contains("\"stage\": \"runtime-required\""))
  assert_true(response.body.contains("\"task_status\""))
  assert_true(response.body.contains("\"conversation\""))
  let decoded : @host_api.PlatformTaskLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(decoded.conversation.turn_count >= 1)
  assert_eq(decoded.conversation.latest_task_id, "message-loop-walk-now")
  assert_eq(decoded.task_status.stage, "runtime-required")
  assert_eq(decoded.mapping.mapping_id, "mapping:noetix-e1-lab-01")
  assert_true(decoded.mapping.mapped)
  assert_eq(decoded.session.session_id, "robo-session:robot:noetix-e1-lab-01")
  assert_eq(decoded.session.thread_id, "moonbook-task-messages")
  assert_eq(decoded.session.mapping_id, decoded.mapping.mapping_id)
  assert_eq(decoded.session.latest_user_text, "walk forward")
  assert_eq(decoded.session.stage, "runtime-required")
  assert_true(!decoded.session.dispatch_requested)
  assert_true(!decoded.session.execution_verified)
  assert_true(
    response.body.contains("\"mapping_id\": \"mapping:noetix-e1-lab-01\""),
  )
  assert_true(response.body.contains("\"mapped\": true"))
  assert_true(response.body.contains("\"bridge_id\": \"sdk-e1\""))
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-loop-walk-now.json",
    ),
  )
  let status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-loop-walk-now"),
  )
  assert_eq(status.status, 200)
  assert_true(status.body.contains("\"stage\": \"ready-to-dispatch\""))
  assert_true(status.body.contains("\"approved\": true"))
}

///|
fn write_healthy_runtime(
  root : String,
  recorded_at_ms : Int64,
  command_intent_id? : String = "",
) -> Unit {
  let frame = {
    ..@core.empty_telemetry_frame(
      "frame-task-loop-dispatch", "noetix-e1-lab-01", "sdk-e1", recorded_at_ms,
    ),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: if command_intent_id == "" {
      { "source": "sdk-e1" }
    } else {
      {
        "source": "sdk-e1",
        "command_intent_id": command_intent_id,
        "command_capability": "control.high.walk",
        "command_x": "0.10",
        "command_yaw": "0.00",
        "command_duration_ms": "1000",
      }
    },
  }
  let telemetry_path = @runtime.write_telemetry_frame(
    root, "runtime-proof", frame,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        recorded_at_ms, "healthy", true, true, 42, "launch-task-loop-dispatch", "runtime-task-loop-dispatch",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        telemetry_path, "frame-task-loop-dispatch", recorded_at_ms,
      ),
    ).unwrap(),
  )
}

///|
fn task_loop_request(
  message_id : String,
  message : String,
  now_ms : Int64,
  allow_dispatch : Bool,
) -> @host_api.PlatformTaskLoopRequest {
  {
    task_message: @task.task_message_request(
      message_id,
      "",
      @core.operator_requester("rabbita"),
      message,
      now_ms,
    ),
    max_steps: 8,
    allow_dispatch,
  }
}

///|
fn write_pending_runtime_revalidation(root : String) -> Unit {
  ignore(
    @runtime.write_runtime_calibration_plan(
      root,
      "runtime-calibration-task-loop",
      (
        #|{
        #|  "plan_id": "runtime-calibration-task-loop",
        #|  "generated_at_ms": "3000",
        #|  "session_id": "runtime-validation-session-task-loop",
        #|  "runtime_id": "runtime-noetix-e1-lab-01:sdk-e1",
        #|  "robot_id": "noetix-e1-lab-01",
        #|  "bridge_id": "sdk-e1",
        #|  "status": "needs-calibration",
        #|  "action_count": 1,
        #|  "blocking_action_count": 1,
        #|  "actions": [
        #|    {
        #|      "action_id": "calibrate-runtime-task-loop",
        #|      "blocker_code": "runtime-active",
        #|      "severity": "blocker",
        #|      "owner": "runtime",
        #|      "evidence_path": "/api/runtime/validation",
        #|      "summary": "Physical runtime supervisor is not active",
        #|      "next_step": "Start the runtime supervisor and refresh validation before dispatching physical tasks"
        #|    }
        #|  ]
        #|}
      ),
    ),
  )
  ignore(
    @runtime.write_runtime_calibration_resolution(
      root,
      "runtime-calibration-resolution-task-loop",
      (
        #|{
        #|  "resolution_id": "runtime-calibration-resolution-task-loop",
        #|  "plan_id": "runtime-calibration-task-loop",
        #|  "action_id": "calibrate-runtime-task-loop",
        #|  "blocker_code": "runtime-active",
        #|  "owner": "runtime",
        #|  "resolved_by": "operator",
        #|  "resolved_at_ms": "3050",
        #|  "note": "runtime supervisor started",
        #|  "evidence_path": "/api/runtime/validation",
        #|  "next_validation_route": "/api/runtime/validation/session",
        #|  "status": "resolved-pending-validation"
        #|}
      ),
    ),
  )
}

///|
test "host api task loop honors explicit dispatch flag" {
  let held_root = "/tmp/moonrobo-host-api-task-loop-held-dispatch-test"
  prepare_submission_root(held_root)
  write_healthy_runtime(held_root, 3100L)
  let held = @host_api.route_with_body(
    held_root,
    "POST",
    @host_api.platform_task_loop_path(),
    task_loop_request("loop-held-dispatch", "walk forward", 3100L, false)
    .to_json()
    .stringify(),
  )
  assert_eq(held.status, 409)
  assert_true(held.body.contains("\"dispatch_requested\": false"))
  assert_true(held.body.contains("\"continued\": false"))
  assert_true(held.body.contains("\"stopped_reason\": \"dispatch-ready\""))
  assert_true(held.body.contains("\"stage\": \"ready-to-dispatch\""))
  let continued = @host_api.route_with_body(
    held_root,
    "POST",
    @host_api.platform_task_loop_continue_path(),
    @host_api.PlatformTaskLoopContinueRequest::{
      task_id: "message-loop-held-dispatch",
      max_steps: 6,
      allow_dispatch: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(continued.status, 200)
  assert_true(continued.body.contains("\"submitted\": false"))
  assert_true(continued.body.contains("\"continued\": true"))
  assert_true(continued.body.contains("\"dispatch_requested\": true"))
  let continued_decoded : @host_api.PlatformTaskLoopResponse = @json.from_json(
    @json.parse(continued.body),
  )
  assert_eq(continued_decoded.task_id, "message-loop-held-dispatch")
  assert_eq(continued_decoded.conversation.turn_count, 2)
  assert_eq(
    continued_decoded.session.session_id,
    "robo-session:robot:noetix-e1-lab-01",
  )
  assert_true(continued_decoded.session.dispatch_requested)
  let continued_messages = @host_api.route(
    held_root,
    "GET",
    @host_api.moonbook_task_messages_path(),
  )
  assert_eq(continued_messages.status, 200)
  assert_true(continued_messages.body.contains("\"message_count\": 2"))
  let revalidation_root = "/tmp/moonrobo-host-api-task-loop-revalidation-test"
  prepare_submission_root(revalidation_root)
  write_healthy_runtime(revalidation_root, 3150L)
  write_pending_runtime_revalidation(revalidation_root)
  let revalidation_blocked = @host_api.route_with_body(
    revalidation_root,
    "POST",
    @host_api.platform_task_loop_path(),
    task_loop_request("loop-revalidation-blocked", "walk forward", 3150L, true)
    .to_json()
    .stringify(),
  )
  assert_eq(revalidation_blocked.status, 409)
  assert_true(
    revalidation_blocked.body.contains(
      "\"code\": \"runtime-validation-current\"",
    ),
  )
  assert_true(
    revalidation_blocked.body.contains(
      "\"route\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(
    revalidation_blocked.body.contains("\"dispatch_requested\": true"),
  )
  assert_true(!revalidation_blocked.body.contains("\"execution_count\": 1"))
  let revalidation_decoded : @host_api.PlatformTaskLoopResponse = @json.from_json(
    @json.parse(revalidation_blocked.body),
  )
  assert_true(!revalidation_decoded.session.dispatch_ready)
  assert_eq(
    revalidation_decoded.session.continuation_route,
    "/api/runtime/validation/session",
  )
  assert_true(
    revalidation_decoded.recovery
    is Some(
      {
        kind: "runtime-validation-current",
        path: "/api/runtime/validation/session",
        ..,
      }
    ),
  )
  let moonclaw_root = "/tmp/moonrobo-host-api-moonclaw-task-loop-auto-test"
  prepare_submission_root(moonclaw_root)
  write_healthy_runtime(
    moonclaw_root,
    3160L,
    command_intent_id="intent-message-moonclaw-loop-auto",
  )
  write_pending_runtime_revalidation(moonclaw_root)
  let moonclaw = @host_api.route_with_body(
    moonclaw_root,
    "POST",
    @host_api.moonclaw_task_loop_path(),
    @host_api.MoonClawTaskLoopRequest::{
      task_loop: task_loop_request(
        "moonclaw-loop-auto", "walk forward", 3160L, true,
      ),
      auto_continue: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(moonclaw.status, 200)
  assert_true(moonclaw.body.contains("\"remediated\": true"))
  assert_true(moonclaw.body.contains("\"continued\": true"))
  assert_true(moonclaw.body.contains("\"initial_status\": 409"))
  assert_true(moonclaw.body.contains("\"final_status\": 200"))
  assert_true(
    moonclaw.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  let moonclaw_decoded : @host_api.MoonClawTaskLoopResponse = @json.from_json(
    @json.parse(moonclaw.body),
  )
  assert_eq(moonclaw_decoded.task_id, "message-moonclaw-loop-auto")
  assert_true(moonclaw_decoded.gateway is Some(_))
  match moonclaw_decoded.gateway {
    Some(gateway) => {
      assert_eq(gateway.route, "/api/runtime/validation/session")
      assert_eq(gateway.status, 200)
      assert_true(@fsx.path_exists(gateway.evidence_path))
    }
    None => fail("expected gateway evidence")
  }
  assert_true(moonclaw_decoded.final_loop is Some(_))
  match moonclaw_decoded.final_loop {
    Some(loop_response) => {
      assert_eq(loop_response.task_status.stage, "completed")
      assert_true(loop_response.execution_proof.execution_count >= 1)
      assert_true(loop_response.session.execution_verified)
    }
    None => fail("expected continued task-loop response")
  }
  let dispatched_root = "/tmp/moonrobo-host-api-task-loop-dispatch-test"
  prepare_submission_root(dispatched_root)
  write_healthy_runtime(
    dispatched_root,
    3200L,
    command_intent_id="intent-message-loop-dispatch-now",
  )
  let dispatched = @host_api.route_with_body(
    dispatched_root,
    "POST",
    @host_api.platform_task_loop_path(),
    task_loop_request("loop-dispatch-now", "walk forward", 3200L, true)
    .to_json()
    .stringify(),
  )
  assert_eq(dispatched.status, 200)
  assert_true(dispatched.body.contains("\"dispatch_requested\": true"))
  assert_true(dispatched.body.contains("\"continued\": false"))
  assert_true(dispatched.body.contains("\"first_loop_status\": 200"))
  assert_true(dispatched.body.contains("\"execution_proof\""))
  assert_true(dispatched.body.contains("\"execution_count\": 1"))
  assert_true(dispatched.body.contains("\"verified_count\": 1"))
  assert_true(dispatched.body.contains("\"stopped_reason\": \"completed\""))
  assert_true(dispatched.body.contains("\"stage\": \"completed\""))
  assert_true(dispatched.body.contains("\"task_status\""))
  assert_true(dispatched.body.contains("\"conversation\""))
  assert_true(dispatched.body.contains("\"resident\""))
  assert_true(dispatched.body.contains("\"mapping\""))
  assert_true(dispatched.body.contains("\"runtime_status\": \"healthy\""))
  let decoded_dispatch : @host_api.PlatformTaskLoopResponse = @json.from_json(
    @json.parse(dispatched.body),
  )
  assert_true(decoded_dispatch.conversation.turn_count >= 1)
  assert_eq(
    decoded_dispatch.conversation.latest_task_id,
    "message-loop-dispatch-now",
  )
  assert_eq(decoded_dispatch.task_status.stage, "completed")
  assert_eq(decoded_dispatch.mapping.runtime_status, "healthy")
  assert_eq(
    decoded_dispatch.session.session_id,
    "robo-session:robot:noetix-e1-lab-01",
  )
  assert_eq(decoded_dispatch.session.task_id, "message-loop-dispatch-now")
  assert_eq(decoded_dispatch.session.stage, "completed")
  assert_eq(
    decoded_dispatch.session.mapping_id,
    decoded_dispatch.mapping.mapping_id,
  )
  assert_true(decoded_dispatch.session.dispatch_requested)
  assert_true(decoded_dispatch.session.execution_verified)
  assert_eq(
    decoded_dispatch.mapping.latest_task_id,
    "message-loop-dispatch-now",
  )
  assert_eq(decoded_dispatch.mapping.latest_execution_status, "verified")
  assert_eq(
    decoded_dispatch.execution_proof.latest_snapshot_id,
    "task-execution-message-loop-dispatch-now-3200",
  )
  assert_true(decoded_dispatch.execution_proof.latest is Some(_))
  assert_true(
    dispatched.body.contains(
      "\"latest_task_id\": \"message-loop-dispatch-now\"",
    ),
  )
  assert_true(
    dispatched.body.contains("\"latest_execution_status\": \"verified\""),
  )
  assert_true(
    dispatched.body.contains(
      "\"latest_command_outcome_status\": \"motion-feedback-observed\"",
    ),
  )
  assert_true(
    dispatched.body.contains("\"step_id\": \"execute-command-message\""),
  )
  assert_true(dispatched.body.contains("\"physical_execution_allowed\": true"))
  assert_true(
    @fsx.path_exists(
      dispatched_root +
      "/runs/task-executions/task-execution-message-loop-dispatch-now-3200.json",
    ),
  )
  let status = @host_api.route(
    dispatched_root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-loop-dispatch-now"),
  )
  assert_eq(status.status, 200)
  assert_true(status.body.contains("\"stage\": \"completed\""))
  assert_true(status.body.contains("\"executed\": true"))
  assert_true(status.body.contains("\"bridge_status\": \"Accepted\""))
  let memory_id = @moonbook.memory_pack_id("noetix-e1-lab-01", 3200L)
  let memory_path = @runtime.moonbook_memory_path(dispatched_root, memory_id)
  let snapshot = @runtime.read_task_execution_snapshot(
    dispatched_root, "task-execution-message-loop-dispatch-now-3200",
  ).unwrap()
  assert_eq(snapshot.memory_path, memory_path)
  assert_eq(snapshot.telemetry_frame_id, "frame-task-loop-dispatch")
  assert_eq(
    snapshot.physical_feedback_path,
    dispatched_root +
    "/runs/telemetry/runtime-proof/frame-task-loop-dispatch.json",
  )
  assert_true(snapshot.physical_feedback_verified)
  assert_eq(snapshot.command_outcome_status, "motion-feedback-observed")
  assert_true(snapshot.command_outcome_verified)
  let memory_json = @runtime.read_moonbook_memory_json(
    dispatched_root, memory_id,
  ).unwrap()
  assert_true(memory_json.contains("\"kind\": \"latest-execution\""))
  assert_true(
    memory_json.contains(
      "verified task message-loop-dispatch-now; control.high.walk; bridge Accepted; runtime healthy; feedback matched; outcome motion-feedback-observed",
    ),
  )
  let executions = @host_api.route(
    dispatched_root,
    "GET",
    @host_api.task_executions_path(),
  )
  assert_eq(executions.status, 200)
  assert_true(executions.body.contains("\"execution_count\": 1"))
  assert_true(executions.body.contains("\"verified_count\": 1"))
  assert_true(
    executions.body.contains(
      "\"latest_snapshot_id\": \"task-execution-message-loop-dispatch-now-3200\"",
    ),
  )
  assert_true(executions.body.contains("\"status\": \"verified\""))
  assert_true(executions.body.contains("\"runtime_status\": \"healthy\""))
  assert_true(
    executions.body.contains(
      "\"command_outcome_status\": \"motion-feedback-checked\"",
    ),
  )
  let readiness = @host_api.route(
    dispatched_root,
    "GET",
    @host_api.platform_readiness_path(),
  )
  assert_eq(readiness.status, 200)
  assert_true(readiness.body.contains("\"task_execution_count\": 1"))
  assert_true(readiness.body.contains("\"task-execution-ready\""))
}

///|
test "host api reports task execution proof snapshots" {
  let root = "/tmp/moonrobo-host-api-task-execution-proof-test"
  prepare_submission_root(root)
  ensure_dir(root + "/runs/task-executions")
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-proof",
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("rabbita"),
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "test proof intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-proof-ready", "sdk-e1", intent, verdict, 3000L,
  )
  let receipt = @core.executed_receipt("receipt-proof-executed", ready, 3001L)
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-proof",
    "request-proof",
    "sdk-e1",
    "noetix-e1-lab-01",
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    3001L,
  )
  let verified_feedback_path = @runtime.write_telemetry_frame(
    root,
    "runtime-proof",
    {
      ..@core.empty_telemetry_frame(
        "frame-proof-verified", "noetix-e1-lab-01", "sdk-e1", 3002L,
      ),
      imu: Some({
        orientation: [1.0, 0.0, 0.0, 0.0],
        angular_velocity: [0.0, 0.0, 0.0],
        linear_acceleration: [0.0, 0.0, 9.8],
      }),
      operator_input: {
        "source": "sdk-e1",
        "command_intent_id": "intent-proof",
        "command_capability": "control.high.walk",
      },
    },
  ).unwrap()
  let partial = @core.task_execution_snapshot(
    "task-execution-proof-partial",
    "message-proof",
    root + "/moonbook/task-messages/message-proof.json",
    root + "/runs/receipts/receipt-proof-executed.json",
    root + "/runs/bridge-dispatches/dispatch-proof.json",
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    3001L,
  )
  let verified = @core.task_execution_snapshot(
    "task-execution-proof-verified",
    "message-proof",
    root + "/moonbook/task-messages/message-proof.json",
    root + "/runs/receipts/receipt-proof-executed.json",
    root + "/runs/bridge-dispatches/dispatch-proof.json",
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    3002L,
    runtime_health_path=root + "/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/moonrobo.log",
    telemetry_frame_id="frame-proof-verified",
    telemetry_captured_at_ms=3002L,
    physical_feedback_path=verified_feedback_path,
  )
  ignore(@runtime.write_run_receipt(root, receipt).unwrap())
  ignore(@runtime.write_task_execution_snapshot(root, partial).unwrap())
  ignore(@runtime.write_task_execution_snapshot(root, verified).unwrap())
  let response = @host_api.route(root, "GET", @host_api.task_executions_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"execution_count\": 2"))
  assert_true(response.body.contains("\"verified_count\": 1"))
  assert_true(
    response.body.contains(
      "\"command_outcome_status\": \"motion-feedback-checked\"",
    ),
  )
  assert_true(
    response.body.contains(
      "\"latest_snapshot_id\": \"task-execution-proof-verified\"",
    ),
  )
  assert_true(response.body.contains("\"status\": \"bridge-accepted\""))
  assert_true(response.body.contains("\"status\": \"verified\""))
  let resident = @host_api.route(root, "GET", @host_api.resident_path())
  assert_eq(resident.status, 200)
  assert_true(resident.body.contains("\"execution_count\": 2"))
  assert_true(resident.body.contains("\"verified_execution_count\": 1"))
  assert_true(
    resident.body.contains("\"snapshot_id\": \"task-execution-proof-verified\""),
  )
  assert_true(resident.body.contains("\"status\": \"verified\""))
}

///|
fn submit_command_message(root : String, message_id : String) -> Unit raise {
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    task_message_json(message_id, "walk forward"),
  )
  assert_eq(response.status, 200)
}

///|
fn assert_queue_step(
  root : String,
  kind : String,
  target_path : String,
) -> Unit raise {
  let queue = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"\{kind}\""))
  assert_true(queue.body.contains("\"target_path\": \"\{target_path}\""))
}

///|
test "host work queue starts reviewed command messages at evaluation" {
  let root = "/tmp/moonrobo-host-api-task-message-queue-evaluate-test"
  prepare_submission_root(root)
  submit_command_message(root, "queue-evaluate")
  assert_queue_step(
    root, "evaluate-command-message", "/api/moonbook/task-messages/message-queue-evaluate/evaluate",
  )
}

///|
test "host work queue advances reviewed command messages to dry run" {
  let root = "/tmp/moonrobo-host-api-task-message-queue-dry-run-test"
  prepare_submission_root(root)
  submit_command_message(root, "queue-dry-run")
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_evaluate_path("message-queue-dry-run"),
      "",
    ),
  )
  assert_queue_step(
    root, "dry-run-command-message", "/api/moonbook/task-messages/message-queue-dry-run/dry-run",
  )
}

///|
test "host work queue advances reviewed command messages to approval" {
  let root = "/tmp/moonrobo-host-api-task-message-queue-approve-test"
  prepare_submission_root(root)
  submit_command_message(root, "queue-approve")
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_evaluate_path("message-queue-approve"),
      "",
    ),
  )
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_dry_run_path("message-queue-approve"),
      "",
    ),
  )
  assert_queue_step(
    root, "approve-command-message", "/api/moonbook/task-messages/message-queue-approve/approve",
  )
}

///|
test "host work queue advances reviewed command messages to execution" {
  let root = "/tmp/moonrobo-host-api-task-message-queue-execute-test"
  prepare_submission_root(root)
  submit_command_message(root, "queue-execute")
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_evaluate_path("message-queue-execute"),
      "",
    ),
  )
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_dry_run_path("message-queue-execute"),
      "",
    ),
  )
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_approve_path("message-queue-execute"),
      "",
    ),
  )
  assert_queue_step(
    root, "execute-command-message", "/api/moonbook/task-messages/message-queue-execute/execute-sidecar",
  )
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_execute_path("message-queue-execute"),
      "",
    ),
  )
  let queue = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(queue.status, 200)
  assert_true(!queue.body.contains("\"kind\": \"execute-command-message\""))
}

///|
test "host api refuses evaluating non-command task messages" {
  let root = "/tmp/moonrobo-host-api-task-message-evaluate-reject-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    task_message_json("inspect-only", "Inspect the desk"),
  )
  assert_eq(response.status, 200)
  let evaluated = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_evaluate_path("message-inspect-only"),
    "",
  )
  assert_eq(evaluated.status, 400)
  assert_true(evaluated.body.contains("\"code\": \"missing-intent-draft\""))
}

///|
test "host api moonclaw context prioritizes review queue" {
  let root = "/tmp/moonrobo-host-api-moonclaw-review-test"
  prepare_submission_root(root)
  ignore(
    @runtime.write_process_review(root, {
      review_id: "review-moonclaw-host-test",
      task_id: "task-moonclaw-host-test",
      session_id: "session-moonclaw-host-test",
      robot_id: "noetix-e1-lab-01",
      receipt_id: "receipt-moonclaw-host-test",
      disposition: NeedsHumanReview,
      severity: Attention,
      summary: "needs review",
      findings: ["host test finding"],
      artifact_paths: ["/tmp/moonclaw-host-artifact.json"],
      created_at_ms: 5000L,
      resolved_at_ms: None,
      resolution_note: None,
    }),
  )
  let response = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"action\": \"ReviewEvidence\""))
  assert_true(response.body.contains("/api/reviews"))
  assert_true(response.body.contains("/tmp/moonclaw-host-artifact.json"))
  assert_true(response.body.contains("\"tool_registry\""))
}

///|
test "host api runs next MoonClaw observation process" {
  let root = "/tmp/moonrobo-host-api-moonclaw-run-next-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="moonclaw-host-run-next",
      goal="host api moonclaw run next",
      now_ms=7000L,
      frame_count=3,
      frame_interval_ms=2L,
    )
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains(
      "\"run_id\": \"agent-process-moonclaw-host-run-next-7000\"",
    ),
  )
  assert_true(response.body.contains("\"outcome\": \"Observed\""))
  assert_true(response.body.contains("\"action\": \"Observe\""))
  assert_true(
    response.body.contains(
      "\"session_id\": \"task-moonclaw-host-run-next-observe\"",
    ),
  )
  let runs = @host_api.route(root, "GET", @host_api.moonclaw_runs_path())
  assert_eq(runs.status, 200)
  assert_true(runs.body.contains("\"run_count\": 1"))
  assert_true(
    runs.body.contains(
      "\"run_id\": \"agent-process-moonclaw-host-run-next-7000\"",
    ),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.moonclaw_run_path("agent-process-moonclaw-host-run-next-7000"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"evidence\""))
  assert_true(
    detail.body.contains(
      "\"replay_path\": \"/api/replays/task-moonclaw-host-run-next-observe\"",
    ),
  )
  assert_true(detail.body.contains("\"telemetry_frame_count\": 3"))
  assert_true(detail.body.contains("\"memory_path\""))
  assert_true(
    detail.body.contains(
      "\"review_id\": \"review-task-moonclaw-host-run-next-observe\"",
    ),
  )
  assert_true(
    detail.body.contains(
      "\"review_path\": \"/api/reviews/review-task-moonclaw-host-run-next-observe\"",
    ),
  )
  let review = @host_api.route(
    root,
    "GET",
    @host_api.review_path("review-task-moonclaw-host-run-next-observe"),
  )
  assert_eq(review.status, 200)
  assert_true(review.body.contains("\"disposition\": \"Accepted\""))
}

///|
test "host api MoonClaw run-next remediates runtime validation" {
  let root = "/tmp/moonrobo-host-api-moonclaw-run-revalidation-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8250L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="moonclaw-host-revalidation",
      goal="host api moonclaw runtime validation",
      now_ms=8300L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"outcome\": \"RemediatedReadiness\""))
  assert_true(response.body.contains("\"action\": \"RemediateReadiness\""))
  assert_true(
    response.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  assert_true(response.body.contains("\"memory_persisted\": true"))
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.moonclaw_run_path("agent-process-moonclaw-host-revalidation-8300"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"gateway_status\": 200"))
  assert_true(
    detail.body.contains(
      "\"gateway_route\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(detail.body.contains("\"memory_path\""))
}

///|
test "host api exports dataset episode from replay evidence" {
  let root = "/tmp/moonrobo-host-api-dataset-episode-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="dataset-host-run",
      goal="host api dataset episode",
      now_ms=9200L,
      frame_count=3,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let response = @host_api.route(
    root,
    "GET",
    @host_api.dataset_episode_path("task-dataset-host-run-observe"),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains(
      "\"episode_id\": \"episode-task-dataset-host-run-observe\"",
    ),
  )
  assert_true(response.body.contains("\"format_version\": 1"))
  assert_true(response.body.contains("\"frame_count\": 3"))
  assert_true(
    response.body.contains(
      "\"replay_path\": \"/api/replays/task-dataset-host-run-observe\"",
    ),
  )
  assert_true(
    response.body.contains(
      "\"review_id\": \"review-task-dataset-host-run-observe\"",
    ),
  )
  let quality = @host_api.route(
    root,
    "GET",
    @host_api.dataset_episode_quality_path("task-dataset-host-run-observe"),
  )
  assert_eq(quality.status, 200)
  assert_true(quality.body.contains("\"passed\": true"))
  assert_true(quality.body.contains("\"blocker_count\": 0"))
  assert_true(quality.body.contains("\"frame_count\": 3"))
}

///|
test "host api records replay annotations" {
  let root = "/tmp/moonrobo-host-api-replay-annotation-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id="annotation-host-run",
      goal="host api replay annotation",
      now_ms=9300L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let session_id = "task-annotation-host-run-observe"
  let create = @host_api.route_with_body(
    root,
    "POST",
    @host_api.replay_annotations_path(session_id),
    replay_annotation_json(
      "annotation-host-test", "sdk-task-annotation-host-run-observe-1",
    ),
  )
  assert_eq(create.status, 200)
  assert_true(create.body.contains("\"persisted\": true"))
  assert_true(
    create.body.contains("\"annotation_id\": \"annotation-host-test\""),
  )
  assert_true(create.body.contains("\"label\": \"usable\""))
  let list = @host_api.route(
    root,
    "GET",
    @host_api.replay_annotations_path(session_id),
  )
  assert_eq(list.status, 200)
  assert_true(list.body.contains("\"annotation_count\": 1"))
  assert_true(
    list.body.contains(
      "\"frame_id\": \"sdk-task-annotation-host-run-observe-1\"",
    ),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.replay_annotation_path(session_id, "annotation-host-test"),
  )
  assert_eq(detail.status, 200)
  assert_true(
    detail.body.contains("\"note\": \"operator accepted replay frame\""),
  )
}

///|
test "host api dispatches selected safe agent evidence work" {
  let root = "/tmp/moonrobo-host-api-agent-dispatch-test"
  prepare_submission_root(root)
  let task_id = fresh_dispatch_task_id(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    @agent_process.default_run_request(
      task_id~,
      goal="host api agent dispatch annotation",
      now_ms=9400L,
      frame_count=2,
      frame_interval_ms=1L,
    )
    .to_json()
    .stringify(),
  )
  let session_id = "task-\{task_id}-observe"
  let resolution : @host_api.ReviewResolutionRequest = {
    note: "operator accepted dispatch evidence",
    resolved_at_ms: 9402L,
  }
  let _resolved = @host_api.route_with_body(
    root,
    "POST",
    @host_api.review_resolve_path("review-\{session_id}"),
    resolution.to_json().stringify(),
  )
  let blocked = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    "",
  )
  assert_eq(blocked.status, 409)
  assert_true(blocked.body.contains("\"agent-action-not-dispatchable\""))
  let request : @host_api.AgentDispatchRequest = {
    work_id: "work-\{session_id}-annotate-replay",
    body: None,
  }
  let dispatched = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    request.to_json().stringify(),
  )
  assert_eq(dispatched.status, 200)
  assert_true(dispatched.body.contains("\"dispatched\": true"))
  assert_true(dispatched.body.contains("\"kind\": \"annotate-replay\""))
  assert_true(dispatched.body.contains("\"downstream_status\": 200"))
  assert_true(
    dispatched.body.contains(
      "\"annotation_id\": \"annotation-\{session_id}-curation\"",
    ),
  )
  let list = @host_api.route(
    root,
    "GET",
    @host_api.replay_annotations_path(session_id),
  )
  assert_eq(list.status, 200)
  assert_true(list.body.contains("\"annotation_count\": 1"))
}

///|
test "host api run-next returns review queue before observation" {
  let root = "/tmp/moonrobo-host-api-moonclaw-run-review-test"
  prepare_submission_root(root)
  ignore(
    @runtime.write_process_review(root, {
      review_id: "review-moonclaw-run-review",
      task_id: "task-moonclaw-run-review",
      session_id: "session-moonclaw-run-review",
      robot_id: "noetix-e1-lab-01",
      receipt_id: "receipt-moonclaw-run-review",
      disposition: NeedsHumanReview,
      severity: Attention,
      summary: "review before running",
      findings: ["review finding"],
      artifact_paths: ["/tmp/moonclaw-run-review.json"],
      created_at_ms: 7100L,
      resolved_at_ms: None,
      resolution_note: None,
    }),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_run_next_path(),
    "",
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"outcome\": \"ReviewRequired\""))
  assert_true(response.body.contains("\"action\": \"ReviewEvidence\""))
  assert_true(!response.body.contains("\"outcome\": \"Observed\""))
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.moonclaw_run_path("agent-process-standing-goal-agent-process-0"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"outcome\": \"ReviewRequired\""))
  assert_true(
    detail.body.contains("\"review_id\": \"review-moonclaw-run-review\""),
  )
  assert_true(detail.body.contains("\"replay_path\": \"-\""))
}

///|
test "host api resolves review queue and reopens MoonClaw observation" {
  let root = "/tmp/moonrobo-host-api-review-resolution-test"
  prepare_submission_root(root)
  ignore(
    @runtime.write_process_review(root, {
      review_id: "review-moonclaw-resolution",
      task_id: "task-moonclaw-resolution",
      session_id: "session-moonclaw-resolution",
      robot_id: "noetix-e1-lab-01",
      receipt_id: "receipt-moonclaw-resolution",
      disposition: NeedsHumanReview,
      severity: Attention,
      summary: "review before running",
      findings: ["review finding"],
      artifact_paths: ["/tmp/moonclaw-resolution.json"],
      created_at_ms: 7200L,
      resolved_at_ms: None,
      resolution_note: None,
    }),
  )
  let blocked = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_true(blocked.body.contains("\"action\": \"ReviewEvidence\""))
  let request : @host_api.ReviewResolutionRequest = {
    note: "operator checked evidence",
    resolved_at_ms: 7300L,
  }
  let resolved = @host_api.route_with_body(
    root,
    "POST",
    @host_api.review_resolve_path("review-moonclaw-resolution"),
    request.to_json().stringify(),
  )
  assert_eq(resolved.status, 200)
  assert_true(resolved.body.contains("\"disposition\": \"Accepted\""))
  assert_true(resolved.body.contains("\"resolved_at_ms\": \"7300\""))
  assert_true(resolved.body.contains("operator checked evidence"))
  let reopened = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_true(reopened.body.contains("\"action\": \"Observe\""))
  assert_true(reopened.body.contains("\"memory\""))
  let review = @runtime.read_process_review(root, "review-moonclaw-resolution").unwrap()
  assert_true(review.disposition == Accepted)
  assert_true(review.resolved_at_ms is Some(7300L))
}

///|
test "host api rejects non-get methods" {
  let response = @host_api.route(
    "examples/noetix-e1",
    "PUT",
    @host_api.snapshot_path(),
  )
  assert_eq(response.status, 405)
  assert_true(response.body.contains("\"code\": \"method-not-allowed\""))
}

///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create test directory: \{path}")
    }
  }
}

///|
fn clear_json_files(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path) catch {
      _ => fail("failed to read test directory: \{path}")
    }
    for name in names {
      if name.has_suffix(".json") {
        @fsx.remove_file(path + "/\{name}") catch {
          _ => fail("failed to remove stale test file: \{path}/\{name}")
        }
      }
    }
  }
}

///|
fn prepare_submission_root(root : String) -> Unit raise {
  ensure_dir(root)
  ensure_dir(root + "/runs")
  ensure_dir(root + "/runs/receipts")
  ensure_dir(root + "/runs/dry-runs")
  ensure_dir(root + "/runs/approvals")
  ensure_dir(root + "/runs/bridge-dispatches")
  ensure_dir(root + "/runs/runtime-health")
  ensure_dir(root + "/runs/runtime-validation")
  ensure_dir(root + "/runs/runtime-validation/sessions")
  ensure_dir(root + "/runs/runtime-calibration")
  ensure_dir(root + "/runs/runtime-calibration/resolutions")
  ensure_dir(root + "/moonbook")
  ensure_dir(root + "/moonbook/memory")
  ensure_dir(root + "/moonbook/task-messages")
  ensure_dir(root + "/agents")
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/dry-runs")
  clear_json_files(root + "/runs/approvals")
  clear_json_files(root + "/runs/bridge-dispatches")
  clear_json_files(root + "/runs/runtime-health")
  clear_json_files(root + "/runs/runtime-validation")
  clear_json_files(root + "/runs/runtime-validation/sessions")
  clear_json_files(root + "/runs/runtime-calibration")
  clear_json_files(root + "/runs/runtime-calibration/resolutions")
  clear_json_files(root + "/moonbook/memory")
  clear_json_files(root + "/moonbook/task-messages")
  clear_json_files(root + "/agents")
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write test profile")
  }
}

///|
fn walk_submission_json_with_evidence(
  receipt_id : String,
  dry_run_receipt_id : String,
  approval_id : String,
) -> String {
  let request : @host_api.IntentSubmissionRequest = {
    intent_id: "intent-host-api-walk",
    robot_id: "",
    capability: "control.high.walk",
    parameters: { "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
    requester: { kind: "operator", id: "host-api-test" },
    receipt_id,
    now_ms: 1000L,
    approval_id,
    dry_run_receipt_id,
    developer_gate: false,
    telemetry_age_ms: 10,
  }
  request.to_json().stringify()
}

///|
fn walk_submission_json(receipt_id : String) -> String {
  walk_submission_json_with_evidence(receipt_id, "", "")
}

///|
fn observation_start_json(session_id : String, receipt_id : String) -> String {
  let request : @pipeline.ObservationStartRequest = {
    session_id,
    receipt_id,
    requester: { kind: "operator", id: "host-api-test" },
    now_ms: 2000L,
  }
  request.to_json().stringify()
}

///|
fn observation_stop_json(receipt_id : String) -> String {
  let request : @pipeline.ObservationStopRequest = {
    receipt_id,
    requester: { kind: "operator", id: "host-api-test" },
    now_ms: 2500L,
    telemetry_frame_count: 5,
    latest_frame_id: "sdk-e1-sidecar-2500",
  }
  request.to_json().stringify()
}

///|
fn observation_frame_json(frame_id : String, captured_at_ms : Int64) -> String {
  let frame = {
    ..@core.empty_telemetry_frame(
      frame_id, "noetix-e1-lab-01", "sdk-e1", captured_at_ms,
    ),
    mode: "high",
  }
  frame.to_json().stringify()
}

///|
fn observe_task_json(task_id : String) -> String {
  let request = @task.observe_task_request(
    task_id,
    "",
    @core.moontown_requester("standing-goal"),
    "scheduled telemetry observation",
    3000L,
  )
  request.to_json().stringify()
}

///|
fn task_message_json(message_id : String, message : String) -> String {
  let request = @task.task_message_request(
    message_id,
    "",
    @core.operator_requester("rabbita"),
    message,
    3000L,
  )
  request.to_json().stringify()
}

///|
fn observe_run_json(task_id : String, frame_count : Int) -> String {
  let request : @pipeline.ObservationRunRequest = {
    task_id,
    robot_id: "",
    requester: @core.moontown_requester("standing-goal"),
    goal: "scheduled telemetry observation run",
    now_ms: 4000L,
    frame_count,
    frame_interval_ms: 5L,
  }
  request.to_json().stringify()
}

///|
fn replay_annotation_json(annotation_id : String, frame_id : String) -> String {
  let request : @host_api.ReplayAnnotationRequest = {
    annotation_id,
    frame_id,
    label: "usable",
    note: "operator accepted replay frame",
    severity: "info",
    requester: @core.operator_requester("host-api-test"),
    created_at_ms: 5002L,
  }
  request.to_json().stringify()
}

///|
fn fresh_dispatch_task_id(root : String) -> String {
  for i in 0..<10000 {
    let task_id = "annotation-dispatch-run-\{i}"
    let session_id = "task-\{task_id}-observe"
    if !@fsx.path_exists(root + "/runs/observations/\{session_id}.json") &&
      !@fsx.path_exists(root + "/runs/annotations/\{session_id}") {
      return task_id
    }
  }
  "annotation-dispatch-run-overflow"
}

///|
fn policy_evaluation_json() -> String {
  let request : @host_api.PolicyEvaluationRequest = {
    proposal: {
      proposal_id: "proposal-host-policy",
      policy_id: "policy-host",
      episode_id: "episode-task-host-policy",
      robot_id: "",
      capability: "control.high.walk",
      parameters: { "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
      confidence: 0.82,
      created_at_ms: 5000L,
    },
    evaluation_id: "policy-eval-host",
    receipt_id: "receipt-policy-host",
    now_ms: 5001L,
    telemetry_age_ms: 10,
    quality_report: None,
  }
  request.to_json().stringify()
}

///|
test "host api evaluates intent submissions and persists receipts" {
  let root = "/tmp/moonrobo-host-api-submit-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_evaluate_path(),
    walk_submission_json("receipt-host-api-submit"),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"next_action\": \"CollectDryRun\""))
  assert_true(response.body.contains("\"status\": \"WaitingForDryRun\""))
  let receipt = @fsx.read_file_to_string(
    root + "/runs/receipts/receipt-host-api-submit.json",
  ) catch {
    _ => fail("failed to read persisted receipt")
  }
  assert_true(receipt.contains("\"capability\": \"control.high.walk\""))
  assert_true(receipt.contains("\"reason\": \"DryRunMissing\""))
}

///|
test "host api evaluates policy proposals as receipt-only gates" {
  let root = "/tmp/moonrobo-host-api-policy-eval-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.policy_evaluate_path(),
    policy_evaluation_json(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"gate_status\": \"requires-dry-run\""))
  assert_true(response.body.contains("\"physical_execution_allowed\": false"))
  assert_true(response.body.contains("\"kind\": \"policy\""))
  let receipt = @fsx.read_file_to_string(
    root + "/runs/receipts/receipt-policy-host.json",
  ) catch {
    _ => fail("failed to read policy run receipt")
  }
  assert_true(receipt.contains("\"capability\": \"control.high.walk\""))
  let evaluation = @fsx.read_file_to_string(
    root + "/runs/policy-evals/policy-eval-host.json",
  ) catch {
    _ => fail("failed to read policy evaluation receipt")
  }
  assert_true(evaluation.contains("\"policy_id\": \"policy-host\""))
  assert_true(evaluation.contains("\"physical_execution_allowed\": false"))
  let list = @host_api.route(root, "GET", @host_api.policy_evaluations_path())
  assert_eq(list.status, 200)
  assert_true(list.body.contains("\"evaluation_count\": 1"))
  assert_true(
    list.body.contains("\"latest_evaluation_id\": \"policy-eval-host\""),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.policy_evaluation_path("policy-eval-host"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"evaluation_id\": \"policy-eval-host\""))
  let status = @host_api.route(root, "GET", @host_api.moonstat_status_path())
  assert_eq(status.status, 200)
  assert_true(status.body.contains("\"policy_evaluation_count\": 1"))
  assert_true(
    status.body.contains(
      "\"latest_policy_evaluation_id\": \"policy-eval-host\"",
    ),
  )
  assert_true(
    status.body.contains("\"latest_policy_gate_status\": \"requires-dry-run\""),
  )
}

///|
test "host api starts and stops observation sessions" {
  let root = "/tmp/moonrobo-host-api-observe-test"
  prepare_submission_root(root)
  let started = @host_api.route_with_body(
    root,
    "POST",
    @host_api.observation_start_path(),
    observation_start_json("observe-session-host-api", "receipt-observe-start"),
  )
  assert_eq(started.status, 200)
  assert_true(started.body.contains("\"status\": \"Active\""))
  assert_true(started.body.contains("\"operation\": \"StartObserve\""))
  let active_session = @fsx.read_file_to_string(
    root + "/runs/observations/observe-session-host-api.json",
  ) catch {
    _ => fail("failed to read active observation")
  }
  assert_true(active_session.contains("\"status\": \"Active\""))
  assert_true(
    active_session.contains(
      "\"/tmp/moonrobo-host-api-observe-test/runs/telemetry/observe-session-host-api/mock-noetix-e1-lab-01-2000.json\"",
    ),
  )
  let frame = @fsx.read_file_to_string(
    root +
    "/runs/telemetry/observe-session-host-api/mock-noetix-e1-lab-01-2000.json",
  ) catch {
    _ => fail("failed to read observation telemetry frame")
  }
  assert_true(frame.contains("\"frame_id\": \"mock-noetix-e1-lab-01-2000\""))
  let ingested = @host_api.route_with_body(
    root,
    "POST",
    @host_api.observation_frame_path("observe-session-host-api"),
    observation_frame_json("host-api-ingested-2100", 2100L),
  )
  assert_eq(ingested.status, 200)
  assert_true(ingested.body.contains("\"telemetry_frame_count\": 2"))
  assert_true(
    ingested.body.contains("\"latest_frame_id\": \"host-api-ingested-2100\""),
  )
  let ingested_frame = @fsx.read_file_to_string(
    root +
    "/runs/telemetry/observe-session-host-api/host-api-ingested-2100.json",
  ) catch {
    _ => fail("failed to read ingested telemetry frame")
  }
  assert_true(ingested_frame.contains("\"mode\": \"high\""))
  let replay = @host_api.route(
    root,
    "GET",
    @host_api.replay_path("observe-session-host-api"),
  )
  assert_eq(replay.status, 200)
  assert_true(replay.body.contains("\"frame_id\": \"host-api-ingested-2100\""))
  let stopped = @host_api.route_with_body(
    root,
    "POST",
    @host_api.observation_stop_path("observe-session-host-api"),
    observation_stop_json("receipt-observe-stop"),
  )
  assert_eq(stopped.status, 200)
  assert_true(stopped.body.contains("\"status\": \"Stopped\""))
  assert_true(stopped.body.contains("\"operation\": \"StopSession\""))
  assert_true(stopped.body.contains("\"telemetry_frame_count\": 5"))
  let stopped_session = @fsx.read_file_to_string(
    root + "/runs/observations/observe-session-host-api.json",
  ) catch {
    _ => fail("failed to read stopped observation")
  }
  assert_true(stopped_session.contains("\"status\": \"Stopped\""))
  assert_true(
    stopped_session.contains("\"latest_frame_id\": \"sdk-e1-sidecar-2500\""),
  )
}

///|
test "host api accepts moontown observation task" {
  let root = "/tmp/moonrobo-host-api-task-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_task_path(),
    observe_task_json("standing-goal-host-test"),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Accepted\""))
  assert_true(
    response.body.contains(
      "\"session_id\": \"task-standing-goal-host-test-observe\"",
    ),
  )
  assert_true(response.body.contains("\"availability\": \"observing\""))
  let session = @fsx.read_file_to_string(
    root + "/runs/observations/task-standing-goal-host-test-observe.json",
  ) catch {
    _ => fail("failed to read task observation session")
  }
  assert_true(session.contains("\"status\": \"Active\""))
  assert_true(response.body.contains("\"latest_artifact_path\""))
  let frame = @fsx.read_file_to_string(
    root +
    "/runs/telemetry/task-standing-goal-host-test-observe/mock-noetix-e1-lab-01-3000.json",
  ) catch {
    _ => fail("failed to read task telemetry frame")
  }
  assert_true(frame.contains("\"frame_id\": \"mock-noetix-e1-lab-01-3000\""))
  let replay = @host_api.route(
    root,
    "GET",
    @host_api.replay_path("task-standing-goal-host-test-observe"),
  )
  assert_eq(replay.status, 200)
  assert_true(
    replay.body.contains(
      "\"session_id\": \"task-standing-goal-host-test-observe\"",
    ),
  )
  assert_true(replay.body.contains("\"frames\""))
  assert_true(replay.body.contains("\"artifact_path\""))
  assert_true(
    replay.body.contains("\"frame_id\": \"mock-noetix-e1-lab-01-3000\""),
  )
}

///|
test "host api runs a complete moontown observation pipeline" {
  let root = "/tmp/moonrobo-host-api-observe-run-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("standing-goal-run-test", 3),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"status\": \"Stopped\""))
  assert_true(response.body.contains("\"telemetry_frame_count\": 3"))
  assert_true(response.body.contains("\"frame_submissions\""))
  assert_true(
    response.body.contains("\"frame_id\": \"mock-noetix-e1-lab-01-4000\""),
  )
  assert_true(
    response.body.contains(
      "\"frame_id\": \"sdk-task-standing-goal-run-test-observe-1\"",
    ),
  )
  assert_true(
    response.body.contains(
      "\"frame_id\": \"sdk-task-standing-goal-run-test-observe-2\"",
    ),
  )
  assert_true(response.body.contains("\"availability\": \"bridge-missing\""))
  assert_true(response.body.contains("\"review\""))
  assert_true(response.body.contains("\"disposition\": \"Accepted\""))
  assert_true(
    response.body.contains(
      "\"review_path\": \"\{root}/runs/reviews/review-task-standing-goal-run-test-observe.json\"",
    ),
  )
  let session = @runtime.read_observation_session(
    root, "task-standing-goal-run-test-observe",
  ).unwrap()
  assert_true(session.status == Stopped)
  assert_eq(session.telemetry_frame_count, 3)
  let frame_paths = @runtime.list_telemetry_frame_paths(
    root, "task-standing-goal-run-test-observe",
  ).unwrap()
  assert_eq(frame_paths.length(), 3)
  let review = @runtime.read_process_review(
    root, "review-task-standing-goal-run-test-observe",
  ).unwrap()
  assert_true(review.disposition == Accepted)
  assert_eq(review.findings.length(), 0)
}

///|
test "host api records dry-run and approval evidence" {
  let root = "/tmp/moonrobo-host-api-evidence-test"
  prepare_submission_root(root)
  let dry_run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_dry_run_path(),
    walk_submission_json_with_evidence(
      "receipt-host-api-dry-run", "dry-run-host-api", "",
    ),
  )
  assert_eq(dry_run.status, 200)
  assert_true(
    dry_run.body.contains("\"dry_run_receipt_id\": \"dry-run-host-api\""),
  )
  assert_true(dry_run.body.contains("\"next_action\": \"CollectDryRun\""))
  let approval = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_approve_path(),
    walk_submission_json_with_evidence(
      "receipt-host-api-approval", "dry-run-host-api", "approval-host-api",
    ),
  )
  assert_eq(approval.status, 200)
  assert_true(approval.body.contains("\"approval_id\": \"approval-host-api\""))
  assert_true(approval.body.contains("\"next_action\": \"RequestApproval\""))
  let ready = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_evaluate_path(),
    walk_submission_json_with_evidence(
      "receipt-host-api-ready", "dry-run-host-api", "approval-host-api",
    ),
  )
  assert_eq(ready.status, 200)
  assert_true(ready.body.contains("\"status\": \"ReadyForExecution\""))
  let executed = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_execute_path(),
    walk_submission_json_with_evidence(
      "receipt-host-api-executed", "dry-run-host-api", "approval-host-api",
    ),
  )
  assert_eq(executed.status, 200)
  assert_true(executed.body.contains("\"status\": \"Executed\""))
  assert_true(executed.body.contains("\"operation\": \"ExecuteIntent\""))
  assert_true(executed.body.contains("\"bridge_dispatch\""))
  assert_true(
    executed.body.contains(
      "\"dispatch_path\": \"\{root}/runs/bridge-dispatches/dispatch-request-execute-intent-host-api-walk-1000.json\"",
    ),
  )
  let receipt = @fsx.read_file_to_string(
    root + "/runs/receipts/receipt-host-api-executed.json",
  ) catch {
    _ => fail("failed to read executed receipt")
  }
  assert_true(receipt.contains("\"status\": \"Executed\""))
  let dispatch = @runtime.read_bridge_dispatch_evidence(
    root, "dispatch-request-execute-intent-host-api-walk-1000",
  ).unwrap()
  assert_eq(dispatch.receipt_id, "receipt-host-api-executed")
  assert_eq(dispatch.http_method, "POST")
}

///|
test "host api refuses execution without approval evidence" {
  let root = "/tmp/moonrobo-host-api-execute-block-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.intent_execute_path(),
    walk_submission_json_with_evidence(
      "receipt-host-api-blocked-execute", "missing-dry-run", "",
    ),
  )
  assert_eq(response.status, 400)
  assert_true(response.body.contains("\"code\": \"missing-approval\""))
}

///|
test "host api rejects malformed intent submissions" {
  let response = @host_api.route_with_body(
    "examples/noetix-e1",
    "POST",
    @host_api.intent_evaluate_path(),
    "{bad json",
  )
  assert_eq(response.status, 400)
  assert_true(response.body.contains("\"code\": \"parse-intent-submission\""))
}
