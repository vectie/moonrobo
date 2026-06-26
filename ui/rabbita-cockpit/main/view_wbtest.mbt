///|
test "sample snapshot keeps imported cockpit contract" {
  let snapshot = sample_snapshot()
  inspect(snapshot.robot.robot_id, content="noetix-e1-lab-01")
  inspect(snapshot.safety.decision, content="dry-run-required")
  inspect(snapshot.sidecar.state, content="missing-command")
  inspect(snapshot.read_only, content="true")
}

///|
test "runtime supervisor parser extracts launch readiness" {
  let fixture = #|{
                #|  "runtime_id": "noetix-e1-lab-01:sdk-e1",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "bridge_id": "sdk-e1",
                #|  "status": "bridge-ready",
                #|  "ready": true,
                #|  "snapshot_path": "/tmp/moonrobo-sdk-e1.json",
                #|  "snapshot_ready": true,
                #|  "bridge_base_url": "http://127.0.0.1:5391",
                #|  "processes": [
                #|    {
                #|      "process_id": "collector",
                #|      "role": "SnapshotCollector",
                #|      "state": "ReadyToStart",
                #|      "command": [],
                #|      "env": {},
                #|      "cwd": ".",
                #|      "command_path": "collector",
                #|      "command_resolution": "search-path",
                #|      "command_available": true,
                #|      "output_path": "/tmp/moonrobo-sdk-e1.json",
                #|      "output_ready": true,
                #|      "health_url": "",
                #|      "depends_on": [],
                #|      "detail": "process is ready to start"
                #|    }
                #|  ],
                #|  "steps": [],
                #|  "issues": []
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse runtime supervisor fixture")
  }
  let parsed = parse_runtime_supervisor_payload(json).unwrap()
  inspect(parsed.status, content="bridge-ready")
  inspect(parsed.ready, content="true")
  inspect(parsed.bridge_base_url, content="http://127.0.0.1:5391")
  inspect(parsed.processes.length(), content="1")
}

///|
test "runtime health parser extracts persisted telemetry evidence" {
  let parsed = parse_runtime_health_payload({
    "persisted": true,
    "runtime_health_path": "/tmp/robobook/runs/runtime-health/health-42.json",
    "latest_runtime_health_path": "/tmp/robobook/runs/runtime-health/latest.json",
    "record": {
      "status": "healthy",
      "telemetry_ok": true,
      "telemetry_status": "ok",
      "telemetry_message": "telemetry accepted",
      "telemetry_frame_id": "frame-42",
    },
  }).unwrap()
  inspect(parsed.status, content="healthy")
  inspect(parsed.persisted, content="true")
  inspect(parsed.telemetry_ok, content="true")
  inspect(parsed.telemetry_status, content="ok")
  inspect(parsed.telemetry_frame_id, content="frame-42")
  inspect(parsed.latest_runtime_health_path.contains("latest.json"), content="true")
}

///|
test "runtime log parser extracts bounded log tail" {
  let parsed = parse_runtime_log_payload({
    "active": true,
    "running": true,
    "status": "running",
    "log_path": "/tmp/robobook/runs/runtime-supervisor/run.log",
    "exists": true,
    "truncated": true,
    "line_count": 120,
    "max_lines": 80,
    "tail": "line-119",
  }).unwrap()
  inspect(parsed.status, content="running")
  inspect(parsed.exists, content="true")
  inspect(parsed.truncated, content="true")
  inspect(parsed.line_count, content="120")
  inspect(parsed.tail, content="line-119")
}

///|
test "runtime validation parser extracts readiness gate" {
  let parsed = parse_runtime_validation_payload({
    "persisted": true,
    "report_path": "/tmp/robobook/runs/runtime-validation/report.json",
    "latest_report_path": "/tmp/robobook/runs/runtime-validation/latest.json",
    "calibration_path": "/tmp/robobook/runs/runtime-calibration/report.json",
    "latest_calibration_path": "/tmp/robobook/runs/runtime-calibration/latest.json",
    "report": {
      "status": "blocked",
      "ready_for_live_sdk": false,
      "pass_count": 5,
      "fail_count": 4,
      "check_count": 12,
    },
  }).unwrap()
  inspect(parsed.status, content="blocked")
  inspect(parsed.ready_for_live_sdk, content="false")
  inspect(parsed.persisted, content="true")
  inspect(parsed.fail_count, content="4")
  inspect(parsed.latest_report_path.contains("latest.json"), content="true")
  inspect(parsed.latest_calibration_path.contains("runtime-calibration/latest.json"), content="true")
}

///|
test "runtime validation session parser extracts repeated readiness evidence" {
  let parsed = parse_runtime_validation_session_payload({
    "persisted": true,
    "sample_count": 3,
    "session_path": "/tmp/robobook/runs/runtime-validation/sessions/session.json",
    "latest_session_path": "/tmp/robobook/runs/runtime-validation/latest-session.json",
    "calibration_path": "/tmp/robobook/runs/runtime-calibration/session.json",
    "latest_calibration_path": "/tmp/robobook/runs/runtime-calibration/latest.json",
    "session": {
      "status": "blocked",
      "ready_for_live_sdk": false,
      "required_sample_count": 3,
      "ready_sample_count": 1,
      "blocked_sample_count": 2,
      "first_blocker_code": "runtime-active",
      "mapping_proof": {
        "status": "mismatch",
        "stable": false,
        "matching_sample_count": 1,
        "mismatch_sample_count": 2,
        "message": "2 validation sample(s) did not match RoboBook robot noetix-e1-lab-01 and bridge sdk-e1",
      },
    },
    "calibration": {
      "status": "needs-calibration",
      "action_count": 2,
      "blocking_action_count": 1,
    },
  }).unwrap()
  inspect(parsed.status, content="blocked")
  inspect(parsed.sample_count, content="3")
  inspect(parsed.ready_sample_count, content="1")
  inspect(parsed.blocked_sample_count, content="2")
  inspect(parsed.first_blocker_code, content="runtime-active")
  inspect(parsed.mapping_status, content="mismatch")
  inspect(parsed.mapping_stable, content="false")
  inspect(parsed.mapping_mismatch_sample_count, content="2")
  inspect(parsed.calibration_status, content="needs-calibration")
  inspect(parsed.latest_session_path.contains("latest-session.json"), content="true")
}

///|
test "platform readiness parser extracts first milestone report" {
  let parsed = parse_platform_readiness_payload({
    "report": {
      "report_id": "moonrobo-readiness-noetix-e1-lab-01",
      "root": "examples/noetix-e1",
      "robot_id": "noetix-e1-lab-01",
      "ready": false,
      "status": "blocked",
      "check_count": 6,
      "pass_count": 4,
      "fail_count": 2,
      "conversation_turn_count": 1,
      "memory_card_count": 1,
      "registered_capability_count": 13,
      "task_execution_count": 0,
      "latest_runtime_status": "healthy",
      "checks": [
        {
          "code": "task-execution-ready",
          "status": "fail",
          "path": "runs/task-executions",
          "message": "no task execution evidence is persisted",
        },
      ],
    },
    "plan": {
      "plan_id": "moonrobo-readiness-plan-noetix-e1-lab-01",
      "report_id": "moonrobo-readiness-noetix-e1-lab-01",
      "status": "needs-action",
      "ready": false,
      "action_count": 1,
      "blocking_action_count": 1,
      "next_action": {
        "action_id": "execute-reviewed-task-through-gates",
        "check_code": "task-execution-ready",
        "priority": 82,
        "title": "Execute reviewed task through gates",
        "summary": "Use the platform queue to continue a reviewed MoonBook task.",
        "http_method": "GET",
        "route": "/api/moonrobo/platform-queue",
        "body_schema": "none",
        "body_template": null,
        "execution_mode": "operator-review",
        "physical_execution_allowed": false,
        "safety_note": "The platform queue describes the next gated action.",
      },
      "actions": [
        {
          "action_id": "execute-reviewed-task-through-gates",
          "check_code": "task-execution-ready",
          "priority": 82,
          "title": "Execute reviewed task through gates",
          "summary": "Use the platform queue to continue a reviewed MoonBook task.",
          "http_method": "GET",
          "route": "/api/moonrobo/platform-queue",
          "body_schema": "none",
          "body_template": null,
          "execution_mode": "operator-review",
          "physical_execution_allowed": false,
          "safety_note": "The platform queue describes the next gated action.",
        },
      ],
    },
  }).unwrap()
  inspect(parsed.report.status, content="blocked")
  inspect(parsed.report.ready, content="false")
  inspect(parsed.report.pass_count, content="4")
  inspect(parsed.report.fail_count, content="2")
  inspect(parsed.report.conversation_turn_count, content="1")
  inspect(parsed.report.memory_card_count, content="1")
  inspect(parsed.report.registered_capability_count, content="13")
  inspect(parsed.report.task_execution_count, content="0")
  inspect(parsed.report.checks.length(), content="1")
  inspect(parsed.report.checks[0].code, content="task-execution-ready")
  inspect(parsed.plan is Some({ status: "needs-action", action_count: 1, .. }), content="true")
}

///|
test "platform loop-proof parser extracts milestone status" {
  let parsed = parse_platform_loop_proof_payload({
    "status": "operational-unproven",
    "ready": false,
    "completed_count": 4,
    "total_count": 6,
    "percent": 66,
    "robot_id": "noetix-e1-lab-01",
    "root": "examples/noetix-e1",
    "readiness_status": "blocked",
    "readiness_pass_count": 6,
    "readiness_fail_count": 2,
    "latest_task_execution_path": "/runs/task-executions/task-execution-message-walk.json",
    "latest_gateway_command_path": "/runs/gateway-commands/routine-walk.json",
    "latest_robo_loop_path": "/runs/robo-loops/loop-walk.json",
    "next_route": "/api/moonrobo/executions",
    "checks": [
      {
        "code": "digital-physical-map",
        "label": "One robot profile is mapped into Moontown",
        "ready": true,
        "evidence_route": "/api/moontown/resident",
        "evidence_path": "robot.json",
        "message": "identity is present",
      },
      {
        "code": "physical-feedback-verified",
        "label": "Physical execution feedback is verified",
        "ready": false,
        "evidence_route": "/api/moonrobo/executions",
        "evidence_path": "",
        "message": "capture feedback",
      },
    ],
    "message": "Moonrobo loop is 4/6 proven.",
  }).unwrap()
  inspect(parsed.status, content="operational-unproven")
  inspect(parsed.ready, content="false")
  inspect(parsed.completed_count, content="4")
  inspect(parsed.total_count, content="6")
  inspect(parsed.percent, content="66")
  inspect(parsed.next_route, content="/api/moonrobo/executions")
  inspect(parsed.checks.length(), content="2")
  inspect(parsed.checks[0].ready, content="true")
  inspect(parsed.checks[1].code, content="physical-feedback-verified")
}

///|
test "live readiness parser extracts physical preflight status" {
  let parsed = parse_moonrobo_live_readiness_payload({
    "status": "ready-for-proof-session",
    "ready_for_live_sdk": true,
    "can_run_proof_session": true,
    "can_submit_gateway_command": true,
    "physical_execution_allowed": false,
    "robot_id": "noetix-e1-lab-01",
    "bridge_id": "sdk-e1",
    "runtime_status": "healthy",
    "runtime_bridge_base_url": "http://127.0.0.1:5391",
    "runtime_health_path": "runs/runtime-health/latest.json",
    "runtime_validation_session_path": "runs/runtime-validation/latest-session.json",
    "calibration_status": "clear",
    "calibration_path": "runs/runtime-calibration/latest.json",
    "calibration_pending_revalidation": false,
    "proof_session_count": 2,
    "latest_proof_session_path": "runs/proof-sessions/proof-session-ready.json",
    "proof_session_auto_feedback_attempted_count": 2,
    "proof_session_auto_feedback_success_count": 1,
    "proof_session_feedback_closed": true,
    "proof_session_latest_feedback_status": 200,
    "proof_session_latest_feedback_message": "Physical feedback verified.",
    "next_method": "POST",
    "next_route": "/api/moonrobo/proof-session",
    "next_title": "Run a bounded proof session against the live-ready runtime",
    "message": "Live SDK readiness is proven.",
  }).unwrap()
  inspect(parsed.status, content="ready-for-proof-session")
  inspect(parsed.ready_for_live_sdk, content="true")
  inspect(parsed.can_run_proof_session, content="true")
  inspect(parsed.can_submit_gateway_command, content="true")
  inspect(parsed.calibration_status, content="clear")
  inspect(parsed.proof_session_count, content="2")
  inspect(parsed.proof_session_feedback_closed, content="true")
  inspect(parsed.proof_session_latest_feedback_status, content="200")
  inspect(parsed.next_route, content="/api/moonrobo/proof-session")
}

///|
test "platform prove-loop parser projects after proof" {
  let parsed = parse_platform_prove_loop_payload({
    "status": "operational-unproven",
    "ready": false,
    "advanced": true,
    "bootstrap_applied": true,
    "routine_attempted": true,
    "routine_http_status": 409,
    "auto_feedback_attempted": true,
    "auto_feedback_status": 200,
    "auto_feedback_message": "Physical feedback verified.",
    "after": {
      "status": "operational-unproven",
      "ready": false,
      "completed_count": 5,
      "total_count": 6,
      "percent": 83,
      "robot_id": "noetix-e1-lab-01",
      "root": "examples/noetix-e1",
      "readiness_status": "blocked",
      "readiness_pass_count": 6,
      "readiness_fail_count": 2,
      "latest_task_execution_path": "",
      "latest_gateway_command_path": "/runs/gateway-commands/routine.json",
      "latest_robo_loop_path": "/runs/robo-loops/loop.json",
      "next_route": "/api/moonrobo/executions",
      "checks": [],
      "message": "after message",
    },
    "message": "Moonrobo prove-loop advanced to 5/6.",
  }).unwrap()
  inspect(parsed.status, content="operational-unproven")
  inspect(parsed.completed_count, content="5")
  inspect(parsed.percent, content="83")
  inspect(parsed.message, content="Moonrobo prove-loop advanced to 5/6.")
  inspect(parsed.auto_feedback_attempted, content="true")
  inspect(parsed.auto_feedback_status, content="200")
  inspect(parsed.auto_feedback_message, content="Physical feedback verified.")
  inspect(prove_loop_body(init_model()).stringify().contains("\"bootstrap\":true"), content="true")
  inspect(prove_loop_body(init_model()).stringify().contains("allow_dispatch"), content="false")
}

///|
#warnings("-alert_unstable")
test "rendered loop proof exposes auto feedback binding" {
  let proof : PlatformLoopProofResult = {
    message: "Moonrobo prove-loop attempted physical feedback binding.",
    status: "complete",
    ready: "true",
    completed_count: "6",
    total_count: "6",
    percent: "100",
    robot_id: "noetix-e1-lab-01",
    readiness_status: "ready-for-execution",
    readiness_pass_count: "8",
    readiness_fail_count: "0",
    latest_task_execution_path: "/runs/task-executions/task-execution.json",
    latest_gateway_command_path: "/runs/gateway-commands/routine.json",
    latest_robo_loop_path: "/runs/robo-loops/loop.json",
    next_route: "/api/moonrobo/ask",
    auto_feedback_attempted: "true",
    auto_feedback_status: "200",
    auto_feedback_message: "Physical feedback verified.",
    checks: [],
  }
  let model = {
    ..init_model(),
    latest_platform_loop_proof: Some(proof),
    platform_loop_proof_status: "Loop proof complete; 6 / 6 checks; 100%",
  }
  let page = @rabbita.simple_cell(
    model~,
    update=(_ : Msg, model) => model,
    view=(_dispatch, model) => render_loop_proof(model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("Auto Feedback"), content="true")
  inspect(html.contains("Feedback Status"), content="true")
  inspect(html.contains("Physical feedback verified."), content="true")
}

///|
test "platform proof-session parser extracts sustained proof result" {
  let parsed = parse_platform_proof_session_payload({
    "session_id": "cockpit-proof-session-42",
    "session_path": "runs/proof-sessions/cockpit-proof-session-42.json",
    "persisted": true,
    "status": "pending",
    "ready": false,
    "attempted_count": 3,
    "requested_iterations": 3,
    "stop_reason": "max-iterations",
    "latest_proof_path": "runs/prove-loop/proof-3.json",
    "next_route": "/api/moonrobo/executions",
    "auto_feedback_attempted_count": 2,
    "auto_feedback_success_count": 1,
    "latest_auto_feedback_status": 200,
    "latest_auto_feedback_message": "Physical feedback verified.",
    "attempts": [],
    "message": "Moonrobo proof session attempted 3 time(s).",
  }).unwrap()
  inspect(parsed.session_id, content="cockpit-proof-session-42")
  inspect(parsed.persisted, content="true")
  inspect(parsed.ready, content="false")
  inspect(parsed.attempted_count, content="3")
  inspect(parsed.requested_iterations, content="3")
  inspect(parsed.next_route, content="/api/moonrobo/executions")
  inspect(parsed.auto_feedback_attempted_count, content="2")
  inspect(parsed.auto_feedback_success_count, content="1")
  inspect(parsed.latest_auto_feedback_status, content="200")
  inspect(parsed.latest_auto_feedback_message, content="Physical feedback verified.")
  let body = proof_session_body(init_model()).stringify()
  inspect(body.contains("\"iterations\":3"), content="true")
  inspect(body.contains("allow_dispatch"), content="false")
  inspect(body.contains("\"stop_when_ready\":true"), content="true")
}

///|
test "live exercise parser extracts aggregate physical-world result" {
  let parsed = parse_live_exercise_payload({
    "exercise_id": "cockpit-live-exercise-42",
    "exercise_path": "runs/live-exercises/cockpit-live-exercise-42.json",
    "persisted": true,
    "status": "verified",
    "validation": { "status": "healthy" },
    "routine": {
      "status": "accepted",
      "command_id": "routine-42",
      "command_path": "runs/gateway-commands/routine-42.json",
    },
    "proof_session": {
      "session_id": "live-exercise-proof-42",
      "session_path": "runs/proof-sessions/live-exercise-proof-42.json",
      "persisted": true,
      "status": "complete",
      "ready": true,
      "attempted_count": 1,
      "requested_iterations": 3,
      "stop_reason": "ready",
      "latest_proof_path": "runs/prove-loop/proof-ready.json",
      "next_route": "/api/moonrobo/ask",
      "auto_feedback_attempted_count": 1,
      "auto_feedback_success_count": 1,
      "latest_auto_feedback_status": 200,
      "latest_auto_feedback_message": "Physical feedback verified.",
      "attempts": [],
      "message": "Moonrobo proof session completed after 1 attempt.",
    },
    "readiness": { "status": "verified" },
    "memory": {
      "persisted": true,
      "memory_path": "moonbook/memory/moonbook-memory-noetix-e1-lab-01-42.json",
      "pack": { "cards": [] },
    },
    "next_route": "/api/moonrobo/ask",
    "message": "Moonrobo live exercise verified.",
  }).unwrap()
  inspect(parsed.exercise_id, content="cockpit-live-exercise-42")
  inspect(parsed.persisted, content="true")
  inspect(parsed.status, content="verified")
  inspect(parsed.command_status, content="accepted")
  inspect(parsed.proof_session_id, content="live-exercise-proof-42")
  inspect(parsed.proof_status, content="complete")
  inspect(parsed.readiness_status, content="verified")
  inspect(parsed.next_route, content="/api/moonrobo/ask")
}

///|
test "live closure parser extracts missing physical gates" {
  let parsed = parse_live_closure_payload({
    "exercise_count": 0,
    "has_exercise": false,
    "exercise_id": "",
    "exercise_path": "",
    "closure": {
      "closed": false,
      "status": "missing",
      "missing_count": 1,
      "missing": ["moonclaw-policy-turn"],
    },
    "next_route": "/api/moonclaw/context",
    "message": "No live exercise audit has been recorded.",
  }).unwrap()
  inspect(parsed.has_exercise, content="false")
  inspect(parsed.closed, content="false")
  inspect(parsed.status, content="missing")
  inspect(parsed.missing_count, content="1")
  inspect(parsed.missing.length(), content="1")
  inspect(parsed.missing[0], content="moonclaw-policy-turn")
  inspect(parsed.next_route, content="/api/moonclaw/context")
}

///|
test "live exercise history parser extracts persisted runs" {
  let parsed = parse_live_exercises_payload({
    "exercise_count": 1,
    "exercises": [
      {
        "exercise_id": "cockpit-live-exercise-42",
        "exercise_path": "runs/live-exercises/cockpit-live-exercise-42.json",
        "persisted": true,
        "status": "verified",
        "routine": { "status": "accepted" },
        "proof_session": {
          "session_id": "live-exercise-proof-42",
          "session_path": "runs/proof-sessions/live-exercise-proof-42.json",
          "persisted": true,
          "status": "complete",
          "ready": true,
          "attempted_count": 1,
          "requested_iterations": 3,
          "stop_reason": "ready",
          "latest_proof_path": "runs/prove-loop/proof-ready.json",
          "next_route": "/api/moonrobo/ask",
          "auto_feedback_attempted_count": 1,
          "auto_feedback_success_count": 1,
          "latest_auto_feedback_status": 200,
          "latest_auto_feedback_message": "Physical feedback verified.",
          "attempts": [],
          "message": "Moonrobo proof session completed after 1 attempt.",
        },
        "readiness": { "status": "verified" },
        "memory": {
          "memory_path": "moonbook/memory/moonbook-memory-noetix-e1-lab-01-42.json",
        },
        "next_route": "/api/moonrobo/ask",
        "message": "Moonrobo live exercise verified.",
      },
    ],
  }).unwrap()
  inspect(parsed.message, content="Loaded 1 live exercise(s)")
  inspect(parsed.exercise_count, content="1")
  inspect(parsed.exercises.length(), content="1")
  inspect(parsed.exercises[0].exercise_id, content="cockpit-live-exercise-42")
  inspect(parsed.exercises[0].status, content="verified")
}

///|
test "platform proof-session list parser extracts persisted history" {
  let parsed = parse_platform_proof_sessions_payload({
    "session_count": 1,
    "sessions": [
      {
        "session_id": "proof-session-history",
        "session_path": "runs/proof-sessions/proof-session-history.json",
        "persisted": true,
        "status": "complete",
        "ready": true,
        "attempted_count": 1,
        "requested_iterations": 3,
        "stop_reason": "ready",
        "latest_proof_path": "runs/prove-loop/proof-ready.json",
        "next_route": "/api/moonrobo/ask",
        "auto_feedback_attempted_count": 1,
        "auto_feedback_success_count": 1,
        "latest_auto_feedback_status": 200,
        "latest_auto_feedback_message": "Physical feedback verified.",
        "attempts": [],
        "message": "Moonrobo proof session completed after 1 attempt.",
      },
    ],
  }).unwrap()
  inspect(parsed.message, content="Loaded 1 proof session(s)")
  inspect(parsed.session_count, content="1")
  inspect(parsed.sessions.length(), content="1")
  inspect(parsed.sessions[0].status, content="complete")
  inspect(parsed.sessions[0].ready, content="true")
  inspect(parsed.sessions[0].auto_feedback_success_count, content="1")
}

///|
test "platform bootstrap parser summarizes before and after readiness" {
  let parsed = parse_platform_bootstrap_payload({
    "persisted": true,
    "status": "blocked",
    "after": {
      "status": "blocked",
      "pass_count": 4,
      "fail_count": 2,
    },
    "steps": [
      { "step_id": "persist-bounded-tool-registry" },
      { "step_id": "persist-first-task-message" },
      { "step_id": "persist-moonbook-robot-memory" },
    ],
  }).unwrap()
  inspect(
    parsed.message,
    content="Platform bootstrap blocked; 4 pass / 2 fail; 3 step(s)",
  )
}

///|
test "platform advance parser summarizes gate result" {
  let parsed = parse_platform_advance_payload({
    "advanced": true,
    "blocked": false,
    "reason": "advanced evaluate-command-message",
    "downstream_status": 200,
    "task_status": {
      "stage": "needs-dry-run",
    },
  }).unwrap()
  inspect(
    parsed.message,
    content="Platform advance advanced; needs-dry-run; downstream 200: advanced evaluate-command-message",
  )
}

test "Robo session parser extracts current handoff" {
  let parsed = parse_robo_session_payload({
    "status": "mapped",
    "has_task_message": false,
    "loop_count": 0,
    "turn_count": 0,
    "session": {
      "session_id": "robo-session:robot:noetix-e1-lab-01",
      "thread_id": "moonbook-task-messages",
      "resident_id": "robot:noetix-e1-lab-01",
      "mapping_id": "mapping:noetix-e1-lab-01",
      "robot_id": "noetix-e1-lab-01",
      "bridge_id": "sdk-e1",
      "task_id": "",
      "latest_user_text": "",
      "latest_robo_text": "No MoonBook task message has been submitted.",
      "stage": "no-task",
      "continuation_route": "/api/moonrobo/gateway/command",
      "dispatch_requested": false,
      "dispatch_ready": false,
      "execution_verified": false,
      "recovery_kind": "",
      "recovery_path": "",
    },
    "mapping": {
      "mapping_id": "mapping:noetix-e1-lab-01",
      "robot_id": "noetix-e1-lab-01",
      "resident_id": "robot:noetix-e1-lab-01",
      "bridge_id": "sdk-e1",
      "runtime_status": "missing",
      "availability": "bridge-missing",
      "mapped": true,
      "reachable": false,
      "latest_task_id": "",
      "latest_execution_status": "missing",
      "latest_feedback_status": "missing",
      "latest_command_outcome_status": "missing",
      "verified_execution_count": 0,
    },
    "execution_proof": {
      "execution_count": 0,
      "verified_count": 0,
      "latest_snapshot_id": "",
      "latest": null,
    },
    "handoff": {
      "status": "needs-operator",
      "can_act": false,
      "needs_operator": true,
      "needs_moonclaw": false,
      "accepts_task_messages": false,
      "physical_execution_allowed": false,
      "next_owner": "operator",
      "next_method": "POST",
      "next_route": "/api/runtime/supervisor/start",
      "target_route": "/api/runtime/supervisor/start",
      "next_kind": "start-runtime",
      "next_title": "Start supervised runtime",
      "queue_count": 1,
      "readiness_status": "blocked",
      "loop_status": "incomplete",
      "loop_percent": 33,
    },
    "message": "Robo session is projected from current state.",
  }).unwrap()
  inspect(parsed.session.session_id, content="robo-session:robot:noetix-e1-lab-01")
  inspect(parsed.handoff.next_owner, content="operator")
  inspect(parsed.handoff.next_route, content="/api/runtime/supervisor/start")
  inspect(parsed.handoff.queue_count, content="1")
  inspect(parsed.loop_count, content="0")
  inspect(parsed.handoff.accepts_task_messages, content="false")
}

///|
test "Robo loop parser extracts canonical turn and handoff evidence" {
  let parsed = parse_robo_loop_payload({
    "message": "Moonrobo loop stopped at an operator-owned handoff.",
    "loop_id": "rabbita-robo-loop-3000",
    "loop_path": "/tmp/robobook/runs/robo-loops/rabbita-robo-loop-3000.json",
    "status": "needs-operator",
    "accepted": true,
    "turn": {
      "message": "Robo accepted the task message and returned the next handoff.",
      "turn_id": "robo-turn-message-cockpit-3000",
      "turn_path": "/tmp/robobook/runs/robo-turns/robo-turn-message-cockpit-3000.json",
      "status": "waiting-operator",
      "accepted": true,
      "moonclaw_handoff": false,
      "ask": { "task_id": "message-cockpit" },
      "handoff": {
        "next_owner": "operator",
        "next_kind": "start-runtime",
        "next_route": "/api/runtime/supervisor/start",
        "can_act": false,
        "needs_moonclaw": false,
      },
    },
    "handoff": {
      "next_owner": "operator",
      "next_kind": "start-runtime",
      "next_route": "/api/runtime/supervisor/start",
    },
  }).unwrap()
  inspect(parsed.loop_id, content="rabbita-robo-loop-3000")
  inspect(parsed.accepted, content="true")
  inspect(parsed.turn is Some({ task_id: "message-cockpit", .. }), content="true")
  inspect(parsed.final_owner, content="operator")
}

test "task execution proof parser summarizes latest proof" {
  let empty = parse_task_execution_proof_payload({
    "execution_count": 0,
    "verified_count": 0,
    "latest_snapshot_id": "",
    "latest": null,
    "executions": [],
  }).unwrap()
  inspect(empty.message, content="No task execution proof snapshots")
  let parsed = parse_task_execution_proof_payload({
    "execution_count": 2,
    "verified_count": 1,
    "latest_snapshot_id": "task-execution-message-walk-3000",
    "latest": {
      "status": "verified",
      "snapshot": {
        "task_id": "message-walk",
        "bridge_status": "Accepted",
        "runtime_status": "healthy",
        "runtime_health_persisted": true,
      },
    },
  }).unwrap()
  inspect(
    parsed.message,
    content="Execution proof verified: task-execution-message-walk-3000; 1 verified / 2 total",
  )
  inspect(parsed.latest_task_id, content="message-walk")
}

///|
test "platform runtime proof parser summarizes proof and readiness" {
  let parsed = parse_platform_runtime_proof_payload({
    "persisted": true,
    "status": "healthy",
    "runtime_ready": true,
    "record": { "telemetry_frame_id": "frame-proof" },
    "readiness": {
      "status": "blocked",
      "pass_count": 5,
      "fail_count": 1,
    },
  }).unwrap()
  inspect(
    parsed.message,
    content="Runtime proof healthy; ready true; frame frame-proof; readiness blocked 5 pass / 1 fail",
  )
  let body = platform_runtime_proof_body(init_model())
  inspect(body.stringify().contains("\"telemetry\""), content="true")
}

///|
test "receipt labels expose sidecar bridge errors" {
  let snapshot = {
    ..sample_snapshot(),
    latest_receipt: Some({
      receipt_id: "receipt-sidecar-rejected",
      status: "failed",
      capability: "control.high.walk",
      started_at_ms: 42L,
      bridge_error: Some("SDK E1 bridge scaffold is read-only"),
    }),
  }
  inspect(
    receipt_bridge_error_label(snapshot.latest_receipt),
    content="SDK E1 bridge scaffold is read-only",
  )
  inspect(receipt_bridge_error_label(None), content="-")
}

///|
test "update handles loaded and failed snapshots" {
  let model = init_model()
  let (_, loaded) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Ok(sample_snapshot())),
    model,
  )
  inspect(loaded.loading, content="false")
  inspect(loaded.error is None, content="true")
  let (_, runtime_loaded) = update(
    _ => @rabbita.none,
    RuntimeSupervisorLoaded(Ok({
      ..sample_runtime_supervisor_status(),
      status: "bridge-ready",
      snapshot_ready: true,
    })),
    loaded,
  )
  inspect(runtime_loaded.runtime_supervisor_status.status, content="bridge-ready")
  let (_, polling) = update(_ => @rabbita.none, PollRuntimeHealth, runtime_loaded)
  inspect(polling.runtime_health_status, content="Polling runtime health")
  let (_, health_loaded) = update(
    _ => @rabbita.none,
    RuntimeHealthLoaded(Ok({
      status: "healthy",
      persisted: "true",
      runtime_health_path: "examples/noetix-e1/runs/runtime-health/health-sample.json",
      latest_runtime_health_path: "examples/noetix-e1/runs/runtime-health/latest.json",
      telemetry_ok: "true",
      telemetry_status: "ok",
      telemetry_message: "telemetry accepted",
      telemetry_frame_id: "frame-healthy",
    })),
    polling,
  )
  inspect(health_loaded.latest_runtime_health is Some({ status: "healthy", .. }), content="true")
  inspect(
    health_loaded.runtime_health_status,
    content="Runtime health healthy; telemetry ok",
  )
  let (_, log_loaded) = update(
    _ => @rabbita.none,
    RuntimeLogLoaded(Ok({
      active: "true",
      running: "true",
      status: "running",
      log_path: "examples/noetix-e1/runs/runtime-supervisor/run.log",
      exists: "true",
      truncated: "false",
      line_count: "2",
      max_lines: "80",
      tail: "starting bridge\nready",
    })),
    health_loaded,
  )
  inspect(log_loaded.latest_runtime_log is Some({ status: "running", .. }), content="true")
  inspect(log_loaded.runtime_log_status, content="Runtime log running; 2 lines")
  let (_, validation_loaded) = update(
    _ => @rabbita.none,
    RuntimeValidationLoaded(Ok({
      status: "blocked",
      ready_for_live_sdk: "false",
      persisted: "true",
      report_path: "examples/noetix-e1/runs/runtime-validation/report.json",
      latest_report_path: "examples/noetix-e1/runs/runtime-validation/latest.json",
      calibration_path: "examples/noetix-e1/runs/runtime-calibration/report.json",
      latest_calibration_path: "examples/noetix-e1/runs/runtime-calibration/latest.json",
      pass_count: "5",
      fail_count: "4",
      check_count: "12",
    })),
    log_loaded,
  )
  inspect(validation_loaded.latest_runtime_validation is Some({ status: "blocked", .. }), content="true")
  inspect(
    validation_loaded.runtime_validation_status,
    content="Runtime validation blocked; failures 4",
  )
  let (_, validating_session) = update(
    _ => @rabbita.none,
    ValidateRuntimeSession,
    validation_loaded,
  )
  inspect(validating_session.validating_runtime_session, content="true")
  inspect(
    validating_session.runtime_validation_session_status,
    content="Running runtime validation session",
  )
  let (_, session_loaded) = update(
    _ => @rabbita.none,
    RuntimeValidationSessionLoaded(Ok({
      message: "Validation session blocked; 1 ready / 3 sample(s)",
      persisted: "true",
      sample_count: "3",
      session_path: "examples/noetix-e1/runs/runtime-validation/sessions/session.json",
      latest_session_path: "examples/noetix-e1/runs/runtime-validation/latest-session.json",
      calibration_path: "examples/noetix-e1/runs/runtime-calibration/session.json",
      latest_calibration_path: "examples/noetix-e1/runs/runtime-calibration/latest.json",
      status: "blocked",
      ready_for_live_sdk: "false",
      required_sample_count: "3",
      ready_sample_count: "1",
      blocked_sample_count: "2",
      first_blocker_code: "runtime-active",
      mapping_status: "mismatch",
      mapping_stable: "false",
      mapping_matching_sample_count: "1",
      mapping_mismatch_sample_count: "2",
      mapping_message: "2 validation sample(s) did not match RoboBook robot noetix-e1-lab-01 and bridge sdk-e1",
      calibration_status: "needs-calibration",
      calibration_action_count: "2",
      calibration_blocking_action_count: "1",
    })),
    validating_session,
  )
  inspect(session_loaded.validating_runtime_session, content="false")
  inspect(session_loaded.latest_runtime_validation_session is Some({ status: "blocked", .. }), content="true")
  inspect(
    session_loaded.runtime_validation_session_status,
    content="Validation session blocked; 1 ready / 3 sample(s)",
  )
  let report : @readiness.PlatformReadinessReport = {
    report_id: "moonrobo-readiness-noetix-e1-lab-01",
    root: "examples/noetix-e1",
    robot_id: "noetix-e1-lab-01",
    ready: false,
    status: "blocked",
    check_count: 6,
    pass_count: 4,
    fail_count: 2,
    conversation_turn_count: 1,
    memory_card_count: 1,
    registered_capability_count: 13,
    task_execution_count: 0,
    latest_runtime_status: "healthy",
    checks: [
      {
        code: "task-execution-ready",
        status: "fail",
        path: "runs/task-executions",
        message: "no task execution evidence is persisted",
      },
    ],
  }
  let (_, readiness_loaded) = update(
    _ => @rabbita.none,
    PlatformReadinessLoaded(
      Ok({ report, plan: Some(@readiness.plan(report)) }),
    ),
    validation_loaded,
  )
  inspect(readiness_loaded.latest_platform_readiness is Some(_), content="true")
  inspect(
    readiness_loaded.latest_platform_readiness_plan is Some({ action_count: 1, .. }),
    content="true",
  )
  inspect(
    readiness_loaded.platform_readiness_status,
    content="Platform readiness blocked; 4 pass / 2 fail",
  )
  let loop_proof : PlatformLoopProofResult = {
    message: "Moonrobo loop is 4/6 proven.",
    status: "operational-unproven",
    ready: "false",
    completed_count: "4",
    total_count: "6",
    percent: "66",
    robot_id: "noetix-e1-lab-01",
    readiness_status: "blocked",
    readiness_pass_count: "6",
    readiness_fail_count: "2",
    latest_task_execution_path: "/runs/task-executions/task-execution-message-walk.json",
    latest_gateway_command_path: "/runs/gateway-commands/routine-walk.json",
    latest_robo_loop_path: "/runs/robo-loops/loop-walk.json",
    next_route: "/api/moonrobo/executions",
    auto_feedback_attempted: "",
    auto_feedback_status: "",
    auto_feedback_message: "",
    checks: [
      {
        code: "physical-feedback-verified",
        label: "Physical execution feedback is verified",
        ready: "false",
        evidence_route: "/api/moonrobo/executions",
        evidence_path: "",
        message: "capture feedback",
      },
    ],
  }
  let (_, loop_proof_loaded) = update(
    _ => @rabbita.none,
    PlatformLoopProofLoaded(Ok(loop_proof)),
    readiness_loaded,
  )
  inspect(loop_proof_loaded.latest_platform_loop_proof is Some(_), content="true")
  inspect(
    loop_proof_loaded.platform_loop_proof_status,
    content="Loop proof operational-unproven; 4 / 6 checks; 66%",
  )
  let live_readiness : MoonroboLiveReadinessResult = {
    message: "Live SDK readiness is proven.",
    status: "ready-for-proof-session",
    ready_for_live_sdk: "true",
    can_run_proof_session: "true",
    can_submit_gateway_command: "true",
    physical_execution_allowed: "false",
    robot_id: "noetix-e1-lab-01",
    bridge_id: "sdk-e1",
    runtime_status: "healthy",
    runtime_bridge_base_url: "http://127.0.0.1:5391",
    runtime_health_path: "runs/runtime-health/latest.json",
    runtime_validation_session_path: "runs/runtime-validation/latest-session.json",
    calibration_status: "clear",
    calibration_path: "runs/runtime-calibration/latest.json",
    calibration_pending_revalidation: "false",
    proof_session_count: "1",
    latest_proof_session_path: "runs/proof-sessions/proof-session-ready.json",
    proof_session_auto_feedback_attempted_count: "2",
    proof_session_auto_feedback_success_count: "1",
    proof_session_feedback_closed: "true",
    proof_session_latest_feedback_status: "200",
    proof_session_latest_feedback_message: "Physical feedback verified.",
    next_method: "POST",
    next_route: "/api/moonrobo/proof-session",
    next_title: "Run a bounded proof session against the live-ready runtime",
  }
  let (_, live_readiness_loaded) = update(
    _ => @rabbita.none,
    MoonroboLiveReadinessLoaded(Ok(live_readiness)),
    loop_proof_loaded,
  )
  inspect(
    live_readiness_loaded.latest_moonrobo_live_readiness is Some(_),
    content="true",
  )
  inspect(
    live_readiness_loaded.moonrobo_live_readiness_status,
    content="Live readiness ready-for-proof-session; next POST /api/moonrobo/proof-session",
  )
  let live_exercise : MoonroboLiveExerciseResult = {
    message: "Moonrobo live exercise verified.",
    exercise_id: "cockpit-live-exercise-42",
    exercise_path: "runs/live-exercises/cockpit-live-exercise-42.json",
    persisted: "true",
    status: "verified",
    command_status: "accepted",
    proof_session_id: "live-exercise-proof-42",
    proof_status: "complete",
    readiness_status: "verified",
    memory_path: "moonbook/memory/moonbook-memory-noetix-e1-lab-01-42.json",
    next_route: "/api/moonrobo/ask",
  }
  let live_closure : MoonroboLiveClosureResult = {
    message: "Live exercise closure is verified.",
    exercise_count: "1",
    has_exercise: "true",
    exercise_id: "cockpit-live-exercise-42",
    exercise_path: "runs/live-exercises/cockpit-live-exercise-42.json",
    closed: "true",
    status: "verified",
    missing_count: "0",
    missing: [],
    next_route: "/api/moonrobo/ask",
  }
  let (_, closure_loaded) = update(
    _ => @rabbita.none,
    LiveClosureLoaded(Ok(live_closure)),
    live_readiness_loaded,
  )
  inspect(closure_loaded.latest_live_closure is Some(_), content="true")
  inspect(
    closure_loaded.live_closure_status,
    content="Live closure verified; missing 0; next /api/moonrobo/ask",
  )
  let (_, history_loaded) = update(
    _ => @rabbita.none,
    LiveExercisesLoaded(Ok({
      message: "Loaded 1 live exercise(s)",
      exercise_count: "1",
      exercises: [live_exercise],
    })),
    closure_loaded,
  )
  inspect(
    history_loaded.latest_live_exercise_history is Some({ exercise_count: "1", .. }),
    content="true",
  )
  inspect(
    history_loaded.live_exercise_history_status,
    content="Loaded 1 live exercise(s)",
  )
  let (_, running_session) = update(
    _ => @rabbita.none,
    RunProofSession,
    history_loaded,
  )
  inspect(running_session.running_proof_session, content="true")
  inspect(
    running_session.platform_proof_session_status,
    content="Running sustained proof session",
  )
  let proof_session : PlatformProofSessionResult = {
    message: "Moonrobo proof session attempted 2 time(s).",
    session_id: "cockpit-proof-session-42",
    session_path: "runs/proof-sessions/cockpit-proof-session-42.json",
    persisted: "true",
    status: "pending",
    ready: "false",
    attempted_count: "2",
    requested_iterations: "3",
    stop_reason: "max-iterations",
    latest_proof_path: "runs/prove-loop/proof-2.json",
    next_route: "/api/moonrobo/executions",
    auto_feedback_attempted_count: "2",
    auto_feedback_success_count: "1",
    latest_auto_feedback_status: "200",
    latest_auto_feedback_message: "Physical feedback verified.",
  }
  let (_, session_ran) = update(
    _ => @rabbita.none,
    ProofSessionRan(Ok(proof_session)),
    running_session,
  )
  inspect(session_ran.running_proof_session, content="false")
  inspect(session_ran.latest_platform_proof_session is Some(_), content="true")
  inspect(
    session_ran.platform_proof_session_status,
    content="Proof session pending; 2 / 3 attempt(s)",
  )
  let (_, history_loaded) = update(
    _ => @rabbita.none,
    ProofSessionsLoaded(Ok({
      message: "Loaded 1 proof session(s)",
      session_count: "1",
      sessions: [proof_session],
    })),
    session_ran,
  )
  inspect(history_loaded.latest_platform_proof_sessions is Some(_), content="true")
  inspect(
    history_loaded.platform_proof_sessions_status,
    content="Loaded 1 proof session(s)",
  )
  let (_, proving_loop) = update(
    _ => @rabbita.none,
    ProveLoop,
    history_loaded,
  )
  inspect(proving_loop.proving_loop, content="true")
  inspect(proving_loop.platform_loop_proof_status, content="Proving closed loop")
  let proven_loop = {
    ..loop_proof,
    message: "Moonrobo prove-loop advanced to 5/6.",
    completed_count: "5",
    percent: "83",
    auto_feedback_attempted: "true",
    auto_feedback_status: "200",
    auto_feedback_message: "Physical feedback verified.",
  }
  let (_, proved_loop) = update(
    _ => @rabbita.none,
    LoopProven(Ok(proven_loop)),
    proving_loop,
  )
  inspect(proved_loop.proving_loop, content="false")
  inspect(
    proved_loop.platform_loop_proof_status,
    content="Loop proof operational-unproven; 5 / 6 checks; 83%",
  )
  let (_, status_loaded) = update(
    _ => @rabbita.none,
    MoonstatLoaded(Ok(sample_moonstat_status())),
    runtime_loaded,
  )
  inspect(
    status_loaded.platform_queue_status,
    content="Refreshing Moonrobo platform queue",
  )
  let queue = {
    ..sample_platform_queue(),
    item_count: 2,
    high_priority_count: 1,
  }
  let (_, action_loaded) = update(
    _ => @rabbita.none,
    WorkQueueLoaded(Ok(queue)),
    status_loaded,
  )
  inspect(action_loaded.platform_queue.item_count, content="2")
  inspect(action_loaded.platform_queue.next_item is Some(_), content="true")
  inspect(action_loaded.platform_queue_status, content="Loaded 2 work item(s)")
  let review_item : @platform_queue.RobotPlatformWorkItem = {
    work_id: "work-message-walk-now-review",
    kind: "review-command-message",
    priority: 88,
    title: "Review command task message",
    summary: "Command language requires gated review",
    target_id: "message-walk-now",
    target_path: "/api/moonbook/task-messages/message-walk-now",
    reason: "review the command plan",
  }
  let review_model = {
    ..action_loaded,
    platform_queue: {
      queue_id: "queue-review",
      robot_id: "noetix-e1-lab-01",
      resident_id: "robot:noetix-e1-lab-01",
      generated_at_ms: 0L,
      item_count: 1,
      high_priority_count: 1,
      next_item: Some(review_item),
      items: [review_item],
    },
  }
  inspect(can_open_task_message_review(review_model), content="true")
  let (_, opening_review) = update(
    _ => @rabbita.none,
    OpenTaskMessageReview,
    review_model,
  )
  inspect(opening_review.loading_task_message_review, content="true")
  inspect(opening_review.task_message_review_status, content="Loading task-message review")
  let (_, opening_ledger_review) = update(
    _ => @rabbita.none,
    OpenTaskMessageReviewRoute("/api/moonbook/task-messages/message-walk-now"),
    review_model,
  )
  inspect(opening_ledger_review.loading_task_message_review, content="true")
  inspect(
    opening_ledger_review.task_message_review_status,
    content="Loading task-message review",
  )
  let review_result : TaskMessageReviewResult = {
    message: "Loaded task-message review message-walk-now (command-intent-review)",
    task_id: "message-walk-now",
    classification: "command-intent-review",
    route: "/api/intents/evaluate",
    reason: "operator review required",
    physical_execution_allowed: "false",
    requires_review: "true",
    suggested_capability: "control.high.walk",
    goal: "walk forward",
    intent_draft: Some({
      intent_id: "intent-message-walk-now",
      robot_id: "noetix-e1-lab-01",
      capability: "control.high.walk",
      parameters: { "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
      requester: { "kind": "operator", "id": "cockpit" },
      receipt_id: "receipt-message-walk-now-review",
      now_ms: 3000,
      telemetry_age_ms: 0,
      developer_gate: false,
    }),
  }
  let (_, loaded_review) = update(
    _ => @rabbita.none,
    TaskMessageReviewLoaded(Ok(review_result)),
    opening_review,
  )
  inspect(loaded_review.loading_task_message_review, content="false")
  inspect(loaded_review.latest_task_message_review is Some(_), content="true")
  inspect(can_evaluate_reviewed_intent(loaded_review), content="true")
  let status_result : TaskMessageStatusResult = {
    message: "needs-evaluation: Evaluate the message-derived intent through the safety pipeline.",
    task_id: "message-walk-now",
    stage: "needs-evaluation",
    summary: "Evaluate the message-derived intent through the safety pipeline.",
    next_route: "/api/moonbook/task-messages/message-walk-now/evaluate",
    runtime_status: "not-running",
    receipt_status: "missing",
    bridge_status: "missing",
    evaluated: "false",
    dry_run_collected: "false",
    approved: "false",
    executed: "false",
    runtime_required: "false",
  }
  let (_, status_loaded) = update(
    _ => @rabbita.none,
    TaskMessageStatusLoaded(Ok(status_result)),
    loaded_review,
  )
  inspect(status_loaded.latest_task_message_status is Some(_), content="true")
  inspect(
    status_loaded.task_message_review_status.contains("needs-evaluation"),
    content="true",
  )
  let (_, continue_pending) = update(
    _ => @rabbita.none,
    ContinueTaskMessage("message-walk-now", "needs-evaluation"),
    loaded_review,
  )
  inspect(continue_pending.pending_task_message_task_id, content="message-walk-now")
  inspect(continue_pending.pending_task_message_stage, content="needs-evaluation")
  inspect(
    continue_pending.task_message_review_status,
    content="Checking task-message next step",
  )
  let (_, continue_evaluating) = update(
    _ => @rabbita.none,
    TaskMessageStatusLoaded(Ok(status_result)),
    continue_pending,
  )
  inspect(continue_evaluating.evaluating, content="true")
  inspect(continue_evaluating.active_reviewed_intent is Some(_), content="true")
  inspect(continue_evaluating.pending_task_message_task_id, content="")
  inspect(
    continue_evaluating.intent_status,
    content="Evaluating reviewed task intent",
  )
  let (_, evaluating_reviewed) = update(
    _ => @rabbita.none,
    EvaluateReviewedIntent,
    status_loaded,
  )
  inspect(evaluating_reviewed.evaluating, content="true")
  inspect(evaluating_reviewed.active_reviewed_intent is Some(_), content="true")
  inspect(evaluating_reviewed.intent_status, content="Evaluating reviewed task intent")
  inspect(
    active_intent_route(evaluating_reviewed, default_dry_run_url(), "dry-run"),
    content="/api/moonbook/task-messages/message-walk-now/dry-run",
  )
  inspect(
    active_intent_route(evaluating_reviewed, default_approval_url(), "approve"),
    content="/api/moonbook/task-messages/message-walk-now/approve",
  )
  inspect(
    active_intent_route(evaluating_reviewed, default_execute_url(), "execute"),
    content="/api/moonbook/task-messages/message-walk-now/execute-sidecar",
  )
  let status_fixture = #|{
      #|  "status": {
      #|    "task_id": "message-walk-now",
      #|    "stage": "runtime-required",
      #|    "summary": "Start the matching physical runtime supervisor before sidecar execution.",
      #|    "next_route": "/api/runtime/supervisor/start",
      #|    "runtime_status": "not-running",
      #|    "receipt_status": "ready-for-execution",
      #|    "bridge_status": "missing",
      #|    "evaluated": true,
      #|    "dry_run_collected": true,
      #|    "approved": true,
      #|    "executed": false,
      #|    "runtime_required": true
      #|  }
      #|}
  let status_json = @json.parse(status_fixture) catch {
    _ => fail("failed to parse task-message status fixture")
  }
  let parsed_status = parse_task_message_status_payload(status_json).unwrap()
  inspect(parsed_status.stage, content="runtime-required")
  inspect(parsed_status.runtime_required, content="true")
  inspect(task_message_waits_on_runtime(parsed_status), content="true")
  let ready_status : TaskMessageStatusResult = {
    message: "ready-to-dispatch: Dispatch through supervised sidecar.",
    task_id: "message-walk-now",
    stage: "ready-to-dispatch",
    summary: "Dispatch through supervised sidecar.",
    next_route: "/api/moonbook/task-messages/message-walk-now/execute-sidecar",
    runtime_status: "healthy",
    receipt_status: "ready-for-execution",
    bridge_status: "healthy",
    evaluated: "true",
    dry_run_collected: "true",
    approved: "true",
    executed: "false",
    runtime_required: "false",
  }
  inspect(should_auto_dispatch_task_message(evaluating_reviewed, ready_status), content="true")
  let (_, auto_dispatching) = update(
    _ => @rabbita.none,
    TaskMessageStatusLoaded(Ok(ready_status)),
    evaluating_reviewed,
  )
  inspect(auto_dispatching.executing, content="true")
  inspect(
    auto_dispatching.intent_status,
    content="Dispatching reviewed task through healthy runtime",
  )
  let (_, failed) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Err("boom")),
    auto_dispatching,
  )
  inspect(failed.loading, content="false")
  inspect(failed.error is Some("boom"), content="true")
  let (_, status_failed) = update(
    _ => @rabbita.none,
    MoonstatLoaded(Err("status unavailable")),
    failed,
  )
  inspect(
    status_failed.platform_queue_status.contains("Moonstat status rejected"),
    content="true",
  )
  let (_, queue_failed) = update(
    _ => @rabbita.none,
    WorkQueueLoaded(Err("queue unavailable")),
    status_failed,
  )
  inspect(
    queue_failed.platform_queue_status.contains("Platform queue rejected"),
    content="true",
  )
}

///|
test "update tracks intent evaluation lifecycle" {
  let model = init_model()
  let (_, edited_x) = update(_ => @rabbita.none, UpdateWalkX("0.25"), model)
  inspect(edited_x.walk_x, content="0.25")
  let (_, edited_yaw) = update(_ => @rabbita.none, UpdateWalkYaw("-0.10"), edited_x)
  inspect(edited_yaw.walk_yaw, content="-0.10")
  let (_, edited_duration) = update(
    _ => @rabbita.none,
    UpdateWalkDuration("1500"),
    edited_yaw,
  )
  inspect(edited_duration.walk_duration_ms, content="1500")
  let (_, evaluating) = update(_ => @rabbita.none, EvaluateWalk, model)
  inspect(evaluating.evaluating, content="true")
  inspect(evaluating.intent_status, content="Evaluating walk intent")
  let (_, accepted) = update(
    _ => @rabbita.none,
    IntentEvaluated(Ok({
      message: "CollectDryRun: WaitingForDryRun receipt receipt-cockpit-walk",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    evaluating,
  )
  inspect(accepted.evaluating, content="false")
  inspect(accepted.loading, content="true")
  inspect(accepted.intent_status.contains("CollectDryRun"), content="true")
  let (_, collecting) = update(_ => @rabbita.none, CollectDryRun, accepted)
  inspect(collecting.collecting_dry_run, content="true")
  let (_, dry_run) = update(
    _ => @rabbita.none,
    DryRunCollected(Ok({
      message: "CollectDryRun: WaitingForDryRun dry run dry-run-cockpit",
      dry_run_receipt_id: "dry-run-cockpit",
      approval_id: "",
    })),
    collecting,
  )
  inspect(dry_run.collecting_dry_run, content="false")
  inspect(dry_run.dry_run_receipt_id, content="dry-run-cockpit")
  let (_, approving) = update(_ => @rabbita.none, ApproveWalk, dry_run)
  inspect(approving.approving, content="true")
  let (_, approved) = update(
    _ => @rabbita.none,
    ApprovalRecorded(Ok({
      message: "RequestApproval: WaitingForApproval approval approval-cockpit",
      dry_run_receipt_id: "dry-run-cockpit",
      approval_id: "approval-cockpit",
    })),
    approving,
  )
  inspect(approved.approving, content="false")
  inspect(approved.approval_id, content="approval-cockpit")
  let (_, executing) = update(_ => @rabbita.none, ExecuteWalk, approved)
  inspect(executing.executing, content="true")
  let (_, executed) = update(
    _ => @rabbita.none,
    ExecutionRecorded(Ok({
      message: "Accepted: Executed receipt receipt-cockpit-walk-executed",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    executing,
  )
  inspect(executed.executing, content="false")
  inspect(executed.intent_status.contains("Executed"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    IntentEvaluated(Err("parse-intent-submission: bad input")),
    accepted,
  )
  inspect(rejected.evaluating, content="false")
  inspect(rejected.intent_status.contains("Intent rejected"), content="true")
}

///|
test "update tracks observation run lifecycle" {
  let model = init_model()
  let (_, task_id) = update(
    _ => @rabbita.none,
    UpdateObservationTaskId("inspection-pass-cockpit"),
    model,
  )
  inspect(task_id.observation_task_id, content="inspection-pass-cockpit")
  let (_, frame_count) = update(
    _ => @rabbita.none,
    UpdateObservationFrameCount("5"),
    task_id,
  )
  inspect(frame_count.observation_frame_count, content="5")
  let (_, running) = update(_ => @rabbita.none, RunObservation, frame_count)
  inspect(running.running_observation, content="true")
  inspect(running.observation_status, content="Running observation pipeline")
  let (_, completed) = update(
    _ => @rabbita.none,
    ObservationRunCompleted(Ok({
      message: "Stopped: 5 frames in task-inspection-pass-cockpit-observe",
      session_id: "task-inspection-pass-cockpit-observe",
      status: "Stopped",
      frame_count: "5",
      latest_frame_id: "sdk-task-inspection-pass-cockpit-observe-4",
      resident_availability: "bridge-missing",
    })),
    running,
  )
  inspect(completed.running_observation, content="false")
  inspect(completed.loading, content="true")
  inspect(completed.observation_status.contains("Stopped"), content="true")
  inspect(completed.latest_observation_run is Some(_), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    ObservationRunCompleted(Err("robot profile missing")),
    completed,
  )
  inspect(rejected.running_observation, content="false")
  inspect(
    rejected.observation_status.contains("Observation run rejected"),
    content="true",
  )
}

///|
test "update tracks task message lifecycle" {
  let model = init_model()
  let (_, edited) = update(
    _ => @rabbita.none,
    UpdateTaskMessage("inspect the desk"),
    model,
  )
  inspect(edited.task_message, content="inspect the desk")
  let (_, submitting) = update(_ => @rabbita.none, SubmitTaskMessage, edited)
  inspect(submitting.submitting_task_message, content="true")
  inspect(submitting.task_message_status, content="Asking Robo")
  let (_, asking) = update(_ => @rabbita.none, RunTaskLoop, edited)
  inspect(asking.submitting_task_message, content="true")
  inspect(asking.task_message_status, content="Running Robo loop")
  let (_, asked) = update(
    _ => @rabbita.none,
    RoboLoopRan(Ok({
      message: "Moonrobo loop stopped at an operator-owned handoff.",
      loop_id: "rabbita-robo-loop-3000",
      loop_path: "/tmp/robobook/runs/robo-loops/rabbita-robo-loop-3000.json",
      status: "needs-operator",
      accepted: "true",
      turn: Some({
        message: "Robo accepted the task message and returned the next handoff.",
        turn_id: "robo-turn-message-cockpit-3000",
        turn_path: "/tmp/robobook/runs/robo-turns/robo-turn-message-cockpit-3000.json",
        status: "waiting-operator",
        accepted: "true",
        moonclaw_handoff: "false",
        task_id: "message-cockpit",
        next_owner: "operator",
        next_kind: "start-runtime",
        next_route: "/api/runtime/supervisor/start",
        can_act: "false",
        needs_moonclaw: "false",
      }),
      final_owner: "operator",
      final_kind: "start-runtime",
      final_route: "/api/runtime/supervisor/start",
    })),
    asking,
  )
  inspect(asked.submitting_task_message, content="false")
  inspect(
    asked.task_message_status,
    content="Moonrobo loop stopped at an operator-owned handoff.",
  )
  inspect(asked.latest_robo_loop is Some({ loop_id: "rabbita-robo-loop-3000", .. }), content="true")
  inspect(
    asked.latest_robo_turn is Some({ task_id: "message-cockpit", .. }),
    content="true",
  )
  inspect(asked.focused_task_message_task_id, content="message-cockpit")
  let result : TaskMessageResult = {
    message: "Accepted message-cockpit; observing task-message-cockpit-observe; remembered 3 card(s)",
    task_id: "message-cockpit",
    session_id: "task-message-cockpit-observe",
    classification: "observation",
    next_route: "/api/moontown/tasks/observe",
    requires_review: "false",
    memory_path: "/tmp/moonbook/memory/moonbook-memory-noetix-e1-lab-01-0.json",
    card_count: "3",
    resident_availability: "observing",
    inline_conversation: None,
    inline_loop_proof: None,
    inline_live_readiness: None,
    inline_handoff: None,
  }
  let (_, accepted) = update(
    _ => @rabbita.none,
    TaskMessageSubmitted(Ok(result)),
    submitting,
  )
  inspect(accepted.submitting_task_message, content="false")
  inspect(accepted.loading, content="true")
  inspect(accepted.task_message_status.contains("Accepted"), content="true")
  inspect(accepted.latest_task_message is Some(_), content="true")
  inspect(accepted.focused_task_message_task_id, content="message-cockpit")
  inspect(accepted.loading_task_message_review, content="false")
  let (_, refreshing) = update(_ => @rabbita.none, RefreshTaskMessages, accepted)
  inspect(refreshing.loading_task_messages, content="true")
  inspect(refreshing.loading_task_conversation, content="true")
  inspect(refreshing.task_message_ledger_status, content="Loading task-message ledger")
  inspect(refreshing.task_conversation_status, content="Loading Robo conversation")
  inspect(refreshing.robo_loop_history_status, content="Loading Robo loop history")
  inspect(refreshing.robo_turn_history_status, content="Loading Robo turn history")
  let loop_history : RoboLoopHistoryResult = {
    message: "Loaded 1 Robo loop(s)",
    loop_count: "1",
    loops: [
      {
        message: "Moonrobo loop stopped at an operator-owned handoff.",
        loop_id: "rabbita-robo-loop-3000",
        loop_path: "/tmp/robobook/runs/robo-loops/rabbita-robo-loop-3000.json",
        status: "needs-operator",
        accepted: "true",
        turn: None,
        final_owner: "operator",
        final_kind: "start-runtime",
        final_route: "/api/runtime/supervisor/start",
      },
    ],
  }
  let (_, loop_history_loaded) = update(
    _ => @rabbita.none,
    RoboLoopHistoryLoaded(Ok(loop_history)),
    refreshing,
  )
  inspect(
    loop_history_loaded.latest_robo_loop_history is Some({ loop_count: "1", .. }),
    content="true",
  )
  inspect(loop_history_loaded.robo_loop_history_status, content="Loaded 1 Robo loop(s)")
  let history : RoboTurnHistoryResult = {
    message: "Loaded 1 Robo turn(s)",
    turn_count: "1",
    turns: [
      {
        message: "Robo accepted the task message and returned the next handoff.",
        turn_id: "robo-turn-message-cockpit-3000",
        turn_path: "/tmp/robobook/runs/robo-turns/robo-turn-message-cockpit-3000.json",
        status: "waiting-operator",
        accepted: "true",
        moonclaw_handoff: "false",
        task_id: "message-cockpit",
        next_owner: "operator",
        next_kind: "start-runtime",
        next_route: "/api/runtime/supervisor/start",
        can_act: "false",
        needs_moonclaw: "false",
      },
    ],
  }
  let (_, history_loaded) = update(
    _ => @rabbita.none,
    RoboTurnHistoryLoaded(Ok(history)),
    loop_history_loaded,
  )
  inspect(
    history_loaded.latest_robo_turn_history is Some({ turn_count: "1", .. }),
    content="true",
  )
  inspect(history_loaded.robo_turn_history_status, content="Loaded 1 Robo turn(s)")
  let ledger : TaskMessageLedgerResult = {
    message: "Loaded 1 task message(s)",
    message_count: "1",
    messages: [
      {
        task_id: "message-cockpit",
        goal: "inspect the desk",
        classification: "observation",
        stage: "completed",
        route: "/api/moontown/tasks/observe",
        next_route: "/api/moonbook/task-messages/message-cockpit/status",
        evaluated: "false",
        dry_run_collected: "false",
        approved: "false",
        executed: "false",
        requires_review: "false",
        physical_execution_allowed: "false",
        message_path: "/tmp/robobook/moonbook/task-messages/message-cockpit.json",
      },
    ],
  }
  let (_, ledger_loaded) = update(
    _ => @rabbita.none,
    TaskMessagesLoaded(Ok(ledger)),
    step_history_loaded,
  )
  inspect(ledger_loaded.loading_task_messages, content="false")
  inspect(ledger_loaded.latest_task_message_ledger is Some(_), content="true")
  let conversation : TaskConversationResult = {
    message: "Loaded 1 Robo conversation turn(s)",
    turn_count: "1",
    latest_task_id: "message-cockpit",
    turns: [
      {
        turn_id: "cockpit-3000",
        task_id: "message-cockpit",
        created_at_ms: "3000",
        user_text: "inspect the desk",
        robo_text: "completed: Observation evidence captured.",
        classification: "observation",
        stage: "completed",
        next_route: "/api/moonbook/task-messages/message-cockpit/status",
        requires_review: "false",
        physical_execution_allowed: "false",
      },
    ],
  }
  let (_, conversation_loaded) = update(
    _ => @rabbita.none,
    TaskConversationLoaded(Ok(conversation)),
    ledger_loaded,
  )
  inspect(conversation_loaded.loading_task_conversation, content="false")
  inspect(
    conversation_loaded.latest_task_conversation is Some({ turn_count: "1", .. }),
    content="true",
  )
  inspect(
    conversation_loaded.task_conversation_status,
    content="Loaded 1 Robo conversation turn(s)",
  )
  let ask_result : TaskMessageResult = {
    message: "Accepted message-inline; Robo handoff needs-operator; next operator /api/runtime/supervisor/start; loop incomplete 50%",
    task_id: "message-inline",
    session_id: "-",
    classification: "command-intent-review",
    next_route: "/api/intents/evaluate",
    requires_review: "true",
    memory_path: "/tmp/moonbook/memory/moonbook-memory-inline.json",
    card_count: "4",
    resident_availability: "bridge-missing",
    inline_conversation: Some({
      message: "Loaded 1 Robo conversation turn(s)",
      turn_count: "1",
      latest_task_id: "message-inline",
      turns: [],
    }),
    inline_loop_proof: None,
    inline_live_readiness: None,
    inline_handoff: None,
  }
  let (_, inline_loaded) = update(
    _ => @rabbita.none,
    TaskMessageSubmitted(Ok(ask_result)),
    submitting,
  )
  inspect(inline_loaded.loading_task_conversation, content="false")
  inspect(
    inline_loaded.latest_task_conversation is Some({ latest_task_id: "message-inline", .. }),
    content="true",
  )
  let review_result : TaskMessageResult = {
    message: "Accepted message-walk-now; command-intent-review via /api/intents/evaluate; remembered 3 card(s)",
    task_id: "message-walk-now",
    session_id: "-",
    classification: "command-intent-review",
    next_route: "/api/intents/evaluate",
    requires_review: "true",
    memory_path: "/tmp/moonbook/memory/moonbook-memory-noetix-e1-lab-01-1.json",
    card_count: "3",
    resident_availability: "bridge-missing",
    inline_conversation: None,
    inline_loop_proof: None,
    inline_live_readiness: None,
    inline_handoff: None,
  }
  let (_, opening_review) = update(
    _ => @rabbita.none,
    TaskMessageSubmitted(Ok(review_result)),
    submitting,
  )
  inspect(opening_review.submitting_task_message, content="false")
  inspect(opening_review.loading_task_message_review, content="true")
  inspect(opening_review.focused_task_message_task_id, content="message-walk-now")
  inspect(
    opening_review.task_message_review_status,
    content="Opening submitted task-message review",
  )
  let (_, rejected) = update(
    _ => @rabbita.none,
    TaskMessageSubmitted(Err("physical-action-message: blocked")),
    accepted,
  )
  inspect(rejected.submitting_task_message, content="false")
  inspect(
    rejected.task_message_status.contains("Task message rejected"),
    content="true",
  )
  let (_, conversation_rejected) = update(
    _ => @rabbita.none,
    TaskConversationLoaded(Err("conversation unavailable")),
    conversation_loaded,
  )
  inspect(conversation_rejected.loading_task_conversation, content="false")
  inspect(
    conversation_rejected.task_conversation_status.contains("Robo conversation rejected"),
    content="true",
  )
}

///|
test "update tracks MoonClaw context lifecycle" {
  let model = init_model()
  let (_, refreshing) = update(_ => @rabbita.none, RefreshMoonClawContext, model)
  inspect(refreshing.refreshing_moonclaw_context, content="true")
  inspect(refreshing.moonclaw_context_status, content="Refreshing MoonClaw context")
  let (_, loaded) = update(
    _ => @rabbita.none,
    MoonClawContextLoaded(Ok({
      surface: "Context",
      summary: "MoonClaw context for cockpit-test",
      review_count: "1",
      needs_human_count: "1",
      latest_review_id: "review-cockpit",
      latest_review_summary: "needs review",
      next_label: "Open review queue",
      next_route: "/api/reviews",
    })),
    refreshing,
  )
  inspect(loaded.refreshing_moonclaw_context, content="false")
  inspect(loaded.moonclaw_context_status.contains("MoonClaw context"), content="true")
  inspect(loaded.latest_moonclaw_context is Some(_), content="true")
  let (_, accepting) = update(_ => @rabbita.none, AcceptLatestReview, loaded)
  inspect(accepting.resolving_review, content="true")
  inspect(accepting.moonclaw_context_status.contains("review-cockpit"), content="true")
  let (_, accepted) = update(
    _ => @rabbita.none,
    ReviewAccepted(Ok({
      message: "Accepted: review-cockpit Review accepted",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    accepting,
  )
  inspect(accepted.resolving_review, content="false")
  inspect(accepted.moonclaw_context_status.contains("Accepted"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    MoonClawContextLoaded(Err("context unavailable")),
    loaded,
  )
  inspect(rejected.refreshing_moonclaw_context, content="false")
  inspect(
    rejected.moonclaw_context_status.contains("MoonClaw context rejected"),
    content="true",
  )
}

test "task message parser extracts task, session, and memory" {
  let fixture = #|{
                #|  "persisted": true,
                #|  "message_plan": {
                #|    "classification": "observation",
                #|    "route": "/api/moontown/tasks/observe",
                #|    "requires_review": false,
                #|    "task": {
                #|      "task_id": "message-cockpit-0"
                #|    }
                #|  },
                #|  "plan": {
                #|    "session_id": "task-message-cockpit-0-observe"
                #|  },
                #|  "resident": {
                #|    "availability": "observing"
                #|  },
                #|  "memory": {
                #|    "memory_path": "/tmp/moonbook/memory/moonbook-memory-noetix-e1-lab-01-0.json",
                #|    "pack": {
                #|      "card_count": 3
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse task message fixture")
  }
  let parsed = parse_task_message_payload(json).unwrap()
  inspect(parsed.task_id, content="message-cockpit-0")
  inspect(parsed.session_id, content="task-message-cockpit-0-observe")
  inspect(parsed.classification, content="observation")
  inspect(parsed.next_route, content="/api/moontown/tasks/observe")
  inspect(parsed.requires_review, content="false")
  inspect(parsed.card_count, content="3")
  inspect(parsed.resident_availability, content="observing")
  inspect(parsed.memory_path.contains("moonbook-memory"), content="true")
}

///|
test "task message parser accepts full Robo ask response" {
  let fixture = #|{
                #|  "accepted": true,
                #|  "task_id": "message-cockpit-ask",
                #|  "submitted": {
                #|    "persisted": true,
                #|    "message_plan": {
                #|      "classification": "command-intent-review",
                #|      "route": "/api/intents/evaluate",
                #|      "requires_review": true,
                #|      "task": { "task_id": "message-cockpit-ask" }
                #|    },
                #|    "resident": { "availability": "bridge-missing" },
                #|    "memory": {
                #|      "memory_path": "/tmp/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
                #|      "pack": { "card_count": 4 }
                #|    }
                #|  },
                #|  "conversation": {
                #|    "conversation": {
                #|      "thread_id": "moonbook-task-messages",
                #|      "turn_count": 1,
                #|      "latest_task_id": "message-cockpit-ask",
                #|      "turns": [
                #|        {
                #|          "turn_id": "cockpit-3000",
                #|          "task_id": "message-cockpit-ask",
                #|          "created_at_ms": "3000",
                #|          "user_text": "walk forward",
                #|          "robo_text": "needs-evaluation: review required",
                #|          "classification": "command-intent-review",
                #|          "stage": "needs-evaluation",
                #|          "next_route": "/api/moonbook/task-messages/message-cockpit-ask/evaluate",
                #|          "requires_review": true,
                #|          "physical_execution_allowed": false
                #|        }
                #|      ]
                #|    }
                #|  },
                #|  "loop_proof": {
                #|    "status": "incomplete",
                #|    "ready": false,
                #|    "completed_count": 3,
                #|    "total_count": 6,
                #|    "percent": 50,
                #|    "robot_id": "noetix-e1-lab-01",
                #|    "readiness_status": "blocked",
                #|    "readiness_pass_count": 4,
                #|    "readiness_fail_count": 2,
                #|    "latest_task_execution_path": "",
                #|    "latest_gateway_command_path": "",
                #|    "latest_robo_loop_path": "",
                #|    "next_route": "/api/runtime/supervisor/start",
                #|    "checks": [
                #|      {
                #|        "code": "user-message-ledger",
                #|        "label": "User task messages persist through MoonBook",
                #|        "ready": true,
                #|        "evidence_route": "/api/moonbook/task-messages",
                #|        "evidence_path": "/tmp/message.json",
                #|        "message": "persisted"
                #|      }
                #|    ],
                #|    "message": "Moonrobo loop is 3/6 proven"
                #|  },
                #|  "live_readiness": {
                #|    "status": "needs-runtime-validation",
                #|    "ready_for_live_sdk": false,
                #|    "can_run_proof_session": false,
                #|    "can_submit_gateway_command": false,
                #|    "physical_execution_allowed": false,
                #|    "robot_id": "noetix-e1-lab-01",
                #|    "bridge_id": "sdk-e1",
                #|    "runtime_status": "missing",
                #|    "runtime_bridge_base_url": "",
                #|    "runtime_health_path": "",
                #|    "runtime_validation_session_path": "",
                #|    "calibration_status": "missing",
                #|    "calibration_path": "",
                #|    "calibration_pending_revalidation": false,
                #|    "proof_session_count": 0,
                #|    "latest_proof_session_path": "",
                #|    "proof_session_auto_feedback_attempted_count": 0,
                #|    "proof_session_auto_feedback_success_count": 0,
                #|    "proof_session_feedback_closed": false,
                #|    "proof_session_latest_feedback_status": 0,
                #|    "proof_session_latest_feedback_message": "",
                #|    "next_method": "POST",
                #|    "next_route": "/api/runtime/validation/session",
                #|    "next_title": "Run runtime validation",
                #|    "message": "Run validation"
                #|  },
                #|  "handoff": {
                #|    "status": "needs-operator",
                #|    "can_act": false,
                #|    "needs_operator": true,
                #|    "needs_moonclaw": false,
                #|    "accepts_task_messages": false,
                #|    "physical_execution_allowed": false,
                #|    "next_owner": "operator",
                #|    "next_method": "POST",
                #|    "next_route": "/api/runtime/supervisor/start",
                #|    "target_route": "/api/runtime/supervisor/start",
                #|    "next_kind": "start-runtime",
                #|    "next_title": "Start runtime",
                #|    "queue_count": 1,
                #|    "readiness_status": "blocked",
                #|    "loop_status": "incomplete",
                #|    "loop_percent": 50
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse Robo ask fixture")
  }
  let parsed = parse_task_message_payload(json).unwrap()
  inspect(parsed.task_id, content="message-cockpit-ask")
  inspect(parsed.message.contains("Robo handoff needs-operator"), content="true")
  inspect(parsed.inline_conversation is Some({ turn_count: "1", .. }), content="true")
  inspect(parsed.inline_loop_proof is Some({ percent: "50", .. }), content="true")
  inspect(
    parsed.inline_live_readiness is Some({ status: "needs-runtime-validation", .. }),
    content="true",
  )
  inspect(parsed.inline_handoff is Some({ next_kind: "start-runtime", .. }), content="true")
}

///|
test "task message parser accepts command review response without session" {
  let fixture = #|{
                #|  "persisted": true,
                #|  "message_plan": {
                #|    "classification": "command-intent-review",
                #|    "route": "/api/intents/evaluate",
                #|    "requires_review": true,
                #|    "task": {
                #|      "task_id": "message-walk-now"
                #|    }
                #|  },
                #|  "resident": {
                #|    "availability": "bridge-missing"
                #|  },
                #|  "memory": {
                #|    "memory_path": "/tmp/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
                #|    "pack": {
                #|      "card_count": 2
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse task message review fixture")
  }
  let parsed = parse_task_message_payload(json).unwrap()
  inspect(parsed.task_id, content="message-walk-now")
  inspect(parsed.session_id, content="-")
  inspect(parsed.classification, content="command-intent-review")
  inspect(parsed.next_route, content="/api/intents/evaluate")
  inspect(parsed.requires_review, content="true")
  inspect(parsed.message.contains("command-intent-review"), content="true")
}

///|
test "task message ledger parser extracts persisted MoonBook messages" {
  let fixture = #|{
                #|  "message_count": 2,
                #|  "messages": [
                #|    {
                #|      "message_path": "/tmp/robobook/moonbook/task-messages/message-status.json",
                #|      "plan": {
                #|        "classification": "observation",
                #|        "route": "/api/moontown/tasks/observe",
                #|        "requires_review": false,
                #|        "physical_execution_allowed": false,
                #|        "task": {
                #|          "task_id": "message-status",
                #|          "goal": "inspect robot status"
                #|        }
                #|      },
                #|      "status": {
                #|        "stage": "completed",
                #|        "next_route": "/api/moonbook/task-messages/message-status/status",
                #|        "evaluated": false,
                #|        "dry_run_collected": false,
                #|        "approved": false,
                #|        "executed": false
                #|      }
                #|    },
                #|    {
                #|      "message_path": "/tmp/robobook/moonbook/task-messages/message-walk.json",
                #|      "plan": {
                #|        "classification": "command-intent-review",
                #|        "route": "/api/intents/evaluate",
                #|        "requires_review": true,
                #|        "physical_execution_allowed": false,
                #|        "task": {
                #|          "task_id": "message-walk",
                #|          "goal": "walk forward"
                #|        }
                #|      },
                #|      "status": {
                #|        "stage": "needs-evaluation",
                #|        "next_route": "/api/moonbook/task-messages/message-walk/evaluate",
                #|        "evaluated": false,
                #|        "dry_run_collected": false,
                #|        "approved": false,
                #|        "executed": false
                #|      }
                #|    }
                #|  ]
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse task-message ledger fixture")
  }
  let parsed = parse_task_message_ledger_payload(json).unwrap()
  inspect(parsed.message_count, content="2")
  inspect(parsed.messages.length(), content="2")
  inspect(parsed.messages[0].task_id, content="message-status")
  inspect(parsed.messages[1].classification, content="command-intent-review")
  inspect(parsed.messages[1].stage, content="needs-evaluation")
  inspect(parsed.messages[1].next_route, content="/api/moonbook/task-messages/message-walk/evaluate")
  inspect(parsed.messages[1].requires_review, content="true")
}

///|
test "task conversation parser extracts persisted user and robo turns" {
  let fixture = #|{
                #|  "conversation": {
                #|    "thread_id": "moonbook-task-messages",
                #|    "turn_count": 1,
                #|    "latest_task_id": "message-walk",
                #|    "turns": [
                #|      {
                #|        "turn_id": "operator-3000",
                #|        "message_id": "operator-3000",
                #|        "task_id": "message-walk",
                #|        "created_at_ms": 3000,
                #|        "user_text": "walk forward",
                #|        "robo_text": "needs-evaluation: Evaluate the message-derived intent through the safety pipeline.",
                #|        "classification": "command-intent-review",
                #|        "stage": "needs-evaluation",
                #|        "next_route": "/api/moonbook/task-messages/message-walk/evaluate",
                #|        "requires_review": true,
                #|        "physical_execution_allowed": false,
                #|        "message_path": "/tmp/robobook/moonbook/task-messages/message-walk.json",
                #|        "evidence_paths": []
                #|      }
                #|    ]
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse task conversation fixture")
  }
  let parsed = parse_task_conversation_payload(json).unwrap()
  inspect(parsed.message, content="Loaded 1 Robo conversation turn(s)")
  inspect(parsed.turn_count, content="1")
  inspect(parsed.latest_task_id, content="message-walk")
  inspect(parsed.turns.length(), content="1")
  inspect(parsed.turns[0].user_text, content="walk forward")
  inspect(parsed.turns[0].stage, content="needs-evaluation")
  inspect(parsed.turns[0].requires_review, content="true")
  inspect(parsed.turns[0].physical_execution_allowed, content="false")
}

///|
test "task message review parser extracts gated robot route" {
  let fixture = #|{
                #|  "message_path": "/tmp/moonbook/task-messages/task-message-message-walk-now.json",
                #|  "plan": {
                #|    "message_id": "operator-3000",
                #|    "robot_id": "noetix-e1-lab-01",
                #|    "task": {
                #|      "task_id": "message-walk-now",
                #|      "robot_id": "noetix-e1-lab-01",
                #|      "requested_by": {
                #|        "kind": "operator",
                #|        "id": "cockpit"
                #|      },
                #|      "goal": "walk forward now",
                #|      "now_ms": 3000
                #|    },
                #|    "classification": "command-intent-review",
                #|    "route": "/api/intents/evaluate",
                #|    "reason": "Physical command language requires explicit intent review",
                #|    "physical_execution_allowed": false,
                #|    "requires_review": true,
                #|    "suggested_capability": "control.high.walk",
                #|    "intent_draft": {
                #|      "intent_id": "intent-message-walk-now",
                #|      "receipt_id": "receipt-message-walk-now-review",
                #|      "capability": "control.high.walk",
                #|      "parameters": {
                #|        "x": "0.10",
                #|        "yaw": "0.00",
                #|        "duration_ms": "1000"
                #|      },
                #|      "telemetry_age_ms": 0,
                #|      "developer_gate": false
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse task message review detail fixture")
  }
  let parsed = parse_task_message_review_payload(json).unwrap()
  inspect(parsed.task_id, content="message-walk-now")
  inspect(parsed.classification, content="command-intent-review")
  inspect(parsed.route, content="/api/intents/evaluate")
  inspect(parsed.physical_execution_allowed, content="false")
  inspect(parsed.requires_review, content="true")
  inspect(parsed.suggested_capability, content="control.high.walk")
  inspect(parsed.goal, content="walk forward now")
  match parsed.intent_draft {
    Some(draft) => {
      inspect(draft.intent_id, content="intent-message-walk-now")
      inspect(draft.capability, content="control.high.walk")
      inspect(draft.parameters.stringify().contains("\"x\":\"0.10\""), content="true")
    }
    None => fail("expected parsed task message review to include intent draft")
  }
}

///|
test "MoonClaw context parser extracts gateway and review pressure" {
  let fixture = #|{
                #|  "context": {
                #|    "robot_id": "noetix-e1-lab-01",
                #|    "review_count": 1,
                #|    "needs_human_count": 1,
                #|    "latest_review": {
                #|      "review_id": "review-task-observe",
                #|      "summary": "needs review"
                #|    },
                #|    "memory": {
                #|      "card_count": 2
                #|    },
                #|    "tool_registry": {
                #|      "capability_count": 12
                #|    },
                #|    "gateway": {
                #|      "status": "mapped-needs-evidence",
                #|      "next_title": "Open review queue",
                #|      "next_route": "/api/reviews"
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse MoonClaw context fixture")
  }
  let parsed = parse_moonclaw_context_payload(json).unwrap()
  inspect(parsed.surface, content="Context")
  inspect(parsed.review_count, content="1")
  inspect(parsed.needs_human_count, content="1")
  inspect(parsed.latest_review_id, content="review-task-observe")
  inspect(parsed.next_route, content="/api/reviews")
}

test "Moonstat parser extracts policy ledger fields" {
  let fixture = #|{
                #|  "service": "moonrobo",
                #|  "robobook_root": "examples/noetix-e1",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "ready": true,
                #|  "status": "degraded",
                #|  "bridge_state": "missing-command",
                #|  "availability": "idle",
                #|  "safety_state": "waiting-for-dry-run",
                #|  "receipt_count": 3,
                #|  "observation_count": 1,
                #|  "process_review_count": 0,
                #|  "pending_review_count": 0,
                #|  "latest_session_id": "session-cockpit",
                #|  "latest_review_id": "-",
                #|  "latest_replay_path": "/api/replays/session-cockpit",
                #|  "generated_at_ms": "42"
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse Moonstat fixture")
  }
  let parsed = parse_moonstat_payload(json).unwrap()
  inspect(parsed.process_review_count, content="0")
  inspect(parsed.latest_replay_path, content="/api/replays/session-cockpit")
}

///|
test "next action parser extracts queue and action" {
  let fixture = #|{
                #|  "queue_id": "platform-queue-noetix-e1-lab-01-0",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "resident_id": "robot:noetix-e1-lab-01",
                #|  "generated_at_ms": "0",
                #|  "item_count": 1,
                #|  "high_priority_count": 1,
                #|  "next_item": {
                #|    "work_id": "work-noetix-e1-lab-01-start-runtime",
                #|    "kind": "start-runtime",
                #|    "priority": 100,
                #|    "title": "Start supervised runtime",
                #|    "summary": "Robot resident needs its supervised runtime before bridge validation",
                #|    "target_id": "noetix-e1-lab-01",
                #|    "target_path": "/api/runtime/supervisor/start",
                #|    "reason": "Physical-world agents need supervised runtime health"
                #|  },
                #|  "items": [
                #|    {
                #|      "work_id": "work-noetix-e1-lab-01-start-runtime",
                #|      "kind": "start-runtime",
                #|      "priority": 100,
                #|      "title": "Start supervised runtime",
                #|      "summary": "Robot resident needs its supervised runtime before bridge validation",
                #|      "target_id": "noetix-e1-lab-01",
                #|      "target_path": "/api/runtime/supervisor/start",
                #|      "reason": "Physical-world agents need supervised runtime health"
                #|    }
                #|  ]
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse platform queue fixture")
  }
  let queue : @platform_queue.RobotPlatformQueue = @json.from_json(json) catch {
    _ => fail("failed to decode platform queue fixture")
  }
  let parsed = parse_platform_queue_payload(queue.to_json()).unwrap()
  inspect(parsed.item_count, content="1")
  inspect(parsed.next_item is Some({ kind: "start-runtime", .. }), content="true")
}

///|
test "runtime calibration parser and queue state expose blockers" {
  let fixture = #|{
                #|  "plan_id": "runtime-calibration-cockpit",
                #|  "generated_at_ms": 42,
                #|  "session_id": "runtime-validation-session-cockpit",
                #|  "runtime_id": "runtime-cockpit",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "bridge_id": "sdk-e1",
                #|  "status": "needs-calibration",
                #|  "action_count": 2,
                #|  "blocking_action_count": 1,
                #|  "actions": [
                #|    {
                #|      "action_id": "calibrate-runtime-process",
                #|      "blocker_code": "runtime-active",
                #|      "severity": "blocker",
                #|      "owner": "operator",
                #|      "evidence_path": "/api/runtime/supervisor",
                #|      "summary": "Start the runtime supervisor",
                #|      "next_step": "Start runtime and rerun validation"
                #|    }
                #|  ]
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse runtime calibration fixture")
  }
  let parsed = parse_runtime_calibration_payload(json).unwrap()
  inspect(parsed.status, content="needs-calibration")
  inspect(parsed.blocking_action_count, content="1")
  inspect(parsed.actions.length(), content="1")
  inspect(parsed.actions[0].blocker_code, content="runtime-active")
  let item : @platform_queue.RobotPlatformWorkItem = {
    work_id: "work-runtime-calibration-cockpit",
    kind: "calibrate-runtime",
    priority: 95,
    title: "Resolve runtime calibration blockers",
    summary: "Runtime validation has blockers",
    target_id: "runtime-calibration-cockpit",
    target_path: "/api/moonclaw/runtime-calibration/latest",
    reason: "runtime validation failed",
  }
  let queue : @platform_queue.RobotPlatformQueue = {
    queue_id: "platform-queue-calibration",
    robot_id: "noetix-e1-lab-01",
    resident_id: "robot:noetix-e1-lab-01",
    generated_at_ms: 42L,
    item_count: 1,
    high_priority_count: 1,
    next_item: Some(item),
    items: [item],
  }
  let (_, loading) = update(
    _ => @rabbita.none,
    WorkQueueLoaded(Ok(queue)),
    init_model(),
  )
  inspect(loading.platform_queue.next_item is Some({ kind: "calibrate-runtime", .. }), content="true")
  inspect(
    loading.runtime_calibration_status,
    content="Loading runtime calibration plan",
  )
  let (_, loaded) = update(
    _ => @rabbita.none,
    RuntimeCalibrationLoaded(Ok(parsed)),
    loading,
  )
  inspect(loaded.latest_runtime_calibration is Some(_), content="true")
  inspect(
    loaded.runtime_calibration_status,
    content="Runtime calibration needs-calibration: 1 blocker(s) / 2 action(s)",
  )
  let resolution_body = runtime_calibration_resolution_body(loaded).stringify()
  inspect(
    resolution_body.contains("\"action_id\":\"calibrate-runtime-process\""),
    content="true",
  )
  let (_, resolving) = update(
    _ => @rabbita.none,
    ResolveRuntimeCalibration,
    loaded,
  )
  inspect(resolving.resolving_runtime_calibration, content="true")
  inspect(
    resolving.runtime_calibration_status,
    content="Persisting runtime calibration resolution",
  )
  let resolution_fixture = #|{
                           #|  "persisted": true,
                           #|  "resolution_path": "/tmp/robobook/runs/runtime-calibration/resolutions/runtime-calibration-resolution-calibrate-runtime-process-42.json",
                           #|  "latest_resolution_path": "/tmp/robobook/runs/runtime-calibration/resolutions/latest.json",
                           #|  "resolution": {
                           #|    "resolution_id": "runtime-calibration-resolution-calibrate-runtime-process-42",
                           #|    "plan_id": "runtime-calibration-cockpit",
                           #|    "action_id": "calibrate-runtime-process",
                           #|    "blocker_code": "runtime-active",
                           #|    "owner": "operator",
                           #|    "resolved_by": "rabbita",
                           #|    "resolved_at_ms": 42,
                           #|    "note": "operator marked runtime calibration action resolved",
                           #|    "evidence_path": "/api/runtime/supervisor",
                           #|    "next_validation_route": "/api/runtime/validation/session",
                           #|    "status": "resolved-pending-validation"
                           #|  }
                           #|}
  let resolution_json = @json.parse(resolution_fixture) catch {
    _ => fail("failed to parse runtime calibration resolution fixture")
  }
  let parsed_resolution = parse_runtime_calibration_resolution_payload(
    resolution_json,
  ).unwrap()
  inspect(parsed_resolution.blocker_code, content="runtime-active")
  let (_, resolved) = update(
    _ => @rabbita.none,
    RuntimeCalibrationResolved(Ok(parsed_resolution)),
    resolving,
  )
  inspect(resolved.resolving_runtime_calibration, content="false")
  inspect(resolved.validating_runtime_session, content="true")
  inspect(
    resolved.runtime_calibration_status,
    content="Runtime calibration resolved-pending-validation: runtime-active",
  )
}

///|
test "review resolution parser accepts resolved review payload" {
  let fixture = #|{
                #|  "persisted": true,
                #|  "review": {
                #|    "review_id": "review-cockpit",
                #|    "disposition": "Accepted",
                #|    "summary": "Review accepted: cockpit accepted review evidence"
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse review resolution fixture")
  }
  let parsed = parse_review_resolution_payload(json).unwrap()
  inspect(parsed.message.contains("Accepted: review-cockpit"), content="true")
  inspect(parsed.message.contains("cockpit accepted"), content="true")
}

///|
test "walk intent body uses editable command parameters" {
  let model = {
    ..init_model(),
    walk_x: "0.25",
    walk_yaw: "-0.10",
    walk_duration_ms: "1500",
    dry_run_receipt_id: "dry-run-body",
    approval_id: "approval-body",
  }
  let text = walk_intent_body(model).stringify()
  inspect(text.contains("\"x\":\"0.25\""), content="true")
  inspect(text.contains("\"yaw\":\"-0.10\""), content="true")
  inspect(text.contains("\"duration_ms\":\"1500\""), content="true")
  inspect(text.contains("\"dry_run_receipt_id\":\"dry-run-body\""), content="true")
  inspect(text.contains("\"approval_id\":\"approval-body\""), content="true")
}

///|
test "observation run body uses bounded task parameters" {
  let model = {
    ..init_model(),
    observation_task_id: "inspection-pass-cockpit",
    observation_frame_count: "5",
  }
  let text = observation_run_body(model).stringify()
  inspect(text.contains("\"task_id\":\"inspection-pass-cockpit\""), content="true")
  inspect(text.contains("\"robot_id\":\"noetix-e1-lab-01\""), content="true")
  inspect(text.contains("\"frame_count\":5"), content="true")
  let clamped = { ..model, observation_frame_count: "50" }
  inspect(
    observation_run_body(clamped).stringify().contains("\"frame_count\":20"),
    content="true",
  )
}

///|
test "task message body uses operator message and robot id" {
  let model = { ..init_model(), task_message: "inspect the desk" }
  let text = task_message_body(model).stringify()
  inspect(text.contains("\"message\":\"inspect the desk\""), content="true")
  inspect(text.contains("\"robot_id\":\"noetix-e1-lab-01\""), content="true")
  inspect(text.contains("\"requested_by\":{\"kind\":\"operator\",\"id\":\"cockpit\"}"), content="true")
}

///|
test "URDF import body activates selected source folder" {
  let model = {
    ..init_model(),
    urdf_import_source: "/tmp/moonrobo-e1-import/e1_asm_251028",
  }
  let text = urdf_import_body(model).stringify()
  inspect(text.contains("\"source_path\":\"/tmp/moonrobo-e1-import/e1_asm_251028\""), content="true")
  inspect(text.contains("\"activate\":true"), content="true")
  inspect(text.contains("\"import_id\":\"\""), content="true")
}

///|
test "update tracks URDF import lifecycle" {
  let model = init_model()
  let (_, missing) = update(_ => @rabbita.none, ImportUrdfModel, model)
  inspect(missing.urdf_import_status.contains("required"), content="true")
  let (_, sourced) = update(
    _ => @rabbita.none,
    UpdateUrdfImportSource("/tmp/moonrobo-e1-import/e1_asm_251028"),
    model,
  )
  inspect(sourced.urdf_import_source.contains("e1_asm_251028"), content="true")
  let (_, importing) = update(_ => @rabbita.none, ImportUrdfModel, sourced)
  inspect(importing.importing_urdf_model, content="true")
  let result : UrdfImportResult = {
    imported: true,
    activated: true,
    source_path: "/tmp/moonrobo-e1-import/e1_asm_251028",
    import_id: "e1_asm",
    import_root: "examples/noetix-e1/model/imports/e1_asm",
    urdf_source_path: "/tmp/moonrobo-e1-import/e1_asm_251028/urdf/e1_asm.urdf",
    urdf_path: "examples/noetix-e1/model/imports/e1_asm/robot.urdf",
    model_primary: "model/imports/e1_asm/robot.urdf",
    mesh_count: 24,
    copied_file_count: 25,
    joint_count: 12,
    link_count: 13,
    visual_count: 13,
    robot_name: "e1_asm",
    profile_path: "examples/noetix-e1/robot.json",
    message: "Imported URDF `e1_asm` with 13 links and 12 joints",
  }
  let (_, imported) = update(_ => @rabbita.none, UrdfModelImported(Ok(result)), importing)
  inspect(imported.importing_urdf_model, content="false")
  inspect(imported.loading, content="true")
  inspect(imported.urdf_import_status.contains("model/imports/e1_asm/robot.urdf"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    UrdfModelImported(Err("missing-urdf-file")),
    importing,
  )
  inspect(rejected.importing_urdf_model, content="false")
  inspect(rejected.urdf_import_status.contains("rejected"), content="true")
}

///|
test "intent submission classifier recognizes task-message action routes" {
  inspect(intent_submission_action(default_intent_url()), content="evaluate")
  inspect(intent_submission_action(default_dry_run_url()), content="dry-run")
  inspect(intent_submission_action(default_approval_url()), content="approve")
  inspect(intent_submission_action(default_execute_url()), content="execute")
  inspect(
    intent_submission_action("/api/moonbook/task-messages/message-walk/dry-run"),
    content="dry-run",
  )
  inspect(
    intent_submission_action("/api/moonbook/task-messages/message-walk/approve"),
    content="approve",
  )
  inspect(
    intent_submission_action("/api/moonbook/task-messages/message-walk/execute-sidecar"),
    content="execute",
  )
}

///|
test "review resolution body records operator note and capture time" {
  let text = review_resolution_body(init_model()).stringify()
  inspect(text.contains("\"note\":\"cockpit accepted review evidence\""), content="true")
  inspect(text.contains("\"resolved_at_ms\":\"0\""), content="true")
}

///|
test "runtime launch parser reports persisted script and receipt" {
  let parsed = parse_runtime_launch_payload({
    "persisted": true,
    "script_path": "/tmp/moonrobo-launch.sh",
    "receipt_path": "/tmp/moonrobo-launch.json",
    "receipt": { "status": "prepared" },
  }).unwrap()
  inspect(parsed.message.contains("Runtime launch prepared"), content="true")
  inspect(parsed.message.contains("/tmp/moonrobo-launch.sh"), content="true")
  inspect(parsed.message.contains("/tmp/moonrobo-launch.json"), content="true")
}

///|
test "runtime process parsers report start and stop status" {
  let started = parse_runtime_start_payload({
    "pid": 1234,
    "status": "running",
    "script_path": "/tmp/moonrobo-runtime.sh",
  }).unwrap()
  inspect(started.message.contains("pid 1234"), content="true")
  inspect(started.message.contains("running"), content="true")
  let stopped = parse_runtime_stop_payload({
    "pid": 1234,
    "status": "stopped",
    "stopped": true,
  }).unwrap()
  inspect(stopped.message.contains("stopped"), content="true")
  inspect(stopped.message.contains("true"), content="true")
}

///|
test "runtime emergency stop parser reports receipt evidence" {
  let parsed = parse_runtime_emergency_stop_payload({
    "persisted": true,
    "event": { "request_id": "request-emergency-stop-9100", "now_ms": 9100 },
    "receipt_path": "/tmp/robobook/runs/receipts/receipt-emergency.json",
    "dispatch_path": "/tmp/robobook/runs/bridge-dispatches/dispatch-emergency.json",
    "receipt": {
      "receipt_id": "receipt-emergency-stop",
      "status": "Executed",
    },
  }).unwrap()
  inspect(parsed.message.contains("Emergency stop Executed"), content="true")
  inspect(parsed.message.contains("request-emergency-stop-9100"), content="true")
  inspect(parsed.message.contains("receipt-emergency-stop"), content="true")
  inspect(parsed.message.contains("dispatch-emergency.json"), content="true")
}

///|
test "runtime emergency stop update records send and completion status" {
  let (_, sending) = update(_ => @rabbita.none, EmergencyStopRuntime, init_model())
  inspect(sending.stopping_emergency, content="true")
  inspect(sending.runtime_launch_status, content="Sending emergency stop")
  let (_, stopped) = update(
    _ => @rabbita.none,
    RuntimeEmergencyStopped(Ok(command_result("Emergency stop Executed"))),
    sending,
  )
  inspect(stopped.stopping_emergency, content="false")
  inspect(stopped.runtime_launch_status, content="Emergency stop Executed")
}

///|
test "execution parser reports persisted task memory" {
  let parsed = parse_execution_result_payload({
    "persisted": true,
    "execution_snapshot_path": "/tmp/robobook/runs/task-executions/task-execution-message-walk-now-3000.json",
    "memory": {
      "memory_path": "/tmp/robobook/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
    },
    "runtime_health": {
      "runtime_health_path": "/tmp/robobook/runs/runtime-health/runtime-health-3000.json",
    },
    "bridge_response": { "status": "Accepted" },
    "receipt": {
      "receipt_id": "receipt-intent-message-walk-executed",
      "status": "Executed",
    },
  }).unwrap()
  inspect(parsed.message.contains("Accepted"), content="true")
  inspect(parsed.message.contains("Executed"), content="true")
  inspect(parsed.message.contains("moonbook-memory"), content="true")
  inspect(parsed.message.contains("runtime-health-3000"), content="true")
  inspect(parsed.message.contains("task-execution-message-walk-now"), content="true")
  let without_health = parse_execution_result_payload({
    "persisted": true,
    "execution_snapshot_path": "/tmp/robobook/runs/task-executions/task-execution-message-walk-now-3000.json",
    "memory": {
      "memory_path": "/tmp/robobook/moonbook/memory/moonbook-memory-noetix-e1-lab-01-3000.json",
    },
    "bridge_response": { "status": "Accepted" },
    "receipt": {
      "receipt_id": "receipt-intent-message-walk-executed",
      "status": "Executed",
    },
  }).unwrap()
  inspect(without_health.message.contains("task-execution-message-walk-now"), content="true")
}

///|
#warnings("-alert_unstable")
test "rendered task message panel includes persisted ledger" {
  let model = {
    ..init_model(),
    focused_task_message_task_id: "message-render-ledger",
    latest_task_message_status: Some({
      message: "needs-evaluation: Evaluate the message-derived intent through the safety pipeline.",
      task_id: "message-render-ledger",
      stage: "needs-evaluation",
      summary: "Evaluate the message-derived intent through the safety pipeline.",
      next_route: "/api/moonbook/task-messages/message-render-ledger/evaluate",
      runtime_status: "not-running",
      receipt_status: "missing",
      bridge_status: "missing",
      evaluated: "false",
      dry_run_collected: "false",
      approved: "false",
      executed: "false",
      runtime_required: "false",
    }),
    latest_task_message_ledger: Some({
      message: "Loaded 1 task message(s)",
      message_count: "1",
      messages: [
        {
          task_id: "message-render-ledger",
          goal: "inspect robot status",
          classification: "command-intent-review",
          stage: "needs-evaluation",
          route: "/api/intents/evaluate",
          next_route: "/api/moonbook/task-messages/message-render-ledger/evaluate",
          evaluated: "false",
          dry_run_collected: "false",
          approved: "false",
          executed: "false",
          requires_review: "false",
          physical_execution_allowed: "false",
          message_path: "/tmp/robobook/moonbook/task-messages/message-render-ledger.json",
        },
      ],
    }),
    task_message_ledger_status: "Loaded 1 task message(s)",
    latest_task_conversation: Some({
      message: "Loaded 1 Robo conversation turn(s)",
      turn_count: "1",
      latest_task_id: "message-render-ledger",
      turns: [
        {
          turn_id: "operator-render",
          task_id: "message-render-ledger",
          created_at_ms: "3000",
          user_text: "persisted user message",
          robo_text: "needs-evaluation: persisted Robo reply",
          classification: "command-intent-review",
          stage: "needs-evaluation",
          next_route: "/api/moonbook/task-messages/message-render-ledger/evaluate",
          requires_review: "true",
          physical_execution_allowed: "false",
        },
      ],
    }),
    task_conversation_status: "Loaded 1 Robo conversation turn(s)",
  }
  let page = @rabbita.simple_cell(
    model~,
    update=(_ : Msg, model) => model,
    view=(dispatch, model) => render_task_message(dispatch, model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("message-render-ledger"), content="true")
  inspect(html.contains("You"), content="true")
  inspect(html.contains("Robo"), content="true")
  inspect(html.contains("persisted user message"), content="true")
  inspect(html.contains("persisted Robo reply"), content="true")
  inspect(html.contains("task-message-row focused"), content="true")
  inspect(html.contains("inspect robot status"), content="true")
  inspect(html.contains("needs-evaluation"), content="true")
  inspect(html.contains("Refresh Ledger"), content="true")
  inspect(html.contains("Evaluate"), content="true")
  inspect(html.contains("Open Message"), content="true")
}

///|
#warnings("-alert_unstable")
test "rendered platform queue includes task-message execution status" {
  let model = {
    ..init_model(),
    latest_task_message_review: Some({
      message: "Loaded task-message review message-render (command-intent-review)",
      task_id: "message-render",
      classification: "command-intent-review",
      route: "/api/intents/evaluate",
      reason: "operator review required",
      physical_execution_allowed: "false",
      requires_review: "true",
      suggested_capability: "control.high.walk",
      goal: "walk forward",
      intent_draft: None,
    }),
    latest_task_message_status: Some({
      message: "runtime-required: Start runtime",
      task_id: "message-render",
      stage: "runtime-required",
      summary: "Start runtime",
      next_route: "/api/runtime/supervisor/start",
      runtime_status: "not-running",
      receipt_status: "ready-for-execution",
      bridge_status: "missing",
      evaluated: "true",
      dry_run_collected: "true",
      approved: "true",
      executed: "false",
      runtime_required: "true",
    }),
  }
  let page = @rabbita.simple_cell(
    model~,
    update=(_ : Msg, model) => model,
    view=(dispatch, model) => render_platform_queue(dispatch, model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("Stage"), content="true")
  inspect(html.contains("runtime-required"), content="true")
  inspect(html.contains("Runtime Required"), content="true")
  inspect(html.contains("ready-for-execution"), content="true")
}

///|
#warnings("-alert_unstable")
test "rendered cockpit includes safety and receipt signals" {
  let page = @rabbita.simple_cell(
    model=init_model(),
    update=(_ : Msg, model) => model,
    view=(dispatch, model) => render_app(dispatch, model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("Moonrobo Cockpit"), content="true")
  inspect(html.contains("Safety Gate"), content="true")
  inspect(html.contains("moonrobo-sdk-e1-bridge"), content="true")
  inspect(html.contains("missing-command"), content="true")
  inspect(html.contains("Runtime"), content="true")
  inspect(html.contains("collector-ready"), content="true")
  inspect(html.contains("http://127.0.0.1:5391"), content="true")
  inspect(html.contains("Prepare Launch"), content="true")
  inspect(html.contains("Start Runtime"), content="true")
  inspect(html.contains("Stop Runtime"), content="true")
  inspect(html.contains("Emergency Stop"), content="true")
  inspect(html.contains("Evaluate Walk"), content="true")
  inspect(html.contains("Collect Dry Run"), content="true")
  inspect(html.contains("Approve"), content="true")
  inspect(html.contains("Execute"), content="true")
  inspect(html.contains("Duration ms"), content="true")
  inspect(html.contains("Observation Run"), content="true")
  inspect(html.contains("Run Observation"), content="true")
  inspect(html.contains("Context"), content="true")
  inspect(html.contains("Suite Status"), content="true")
  inspect(html.contains("Platform Queue"), content="true")
  inspect(html.contains("Ask Robo"), content="true")
  inspect(html.contains("Run Routine"), content="false")
  inspect(html.contains("inspect robot status"), content="true")
  inspect(html.contains("Start supervised runtime"), content="true")
  inspect(html.contains("/api/runtime/supervisor/start"), content="true")
  inspect(html.contains("Physical"), content="true")
  inspect(html.contains("Policy Evals"), content="false")
  inspect(html.contains("Run Loop"), content="true")
  inspect(html.contains("Prove Runtime"), content="true")
  inspect(html.contains("Live Readiness"), content="true")
  inspect(html.contains("Live Exercise"), content="true")
  inspect(html.contains("Live Closure"), content="true")
  inspect(html.contains("Proof Session"), content="true")
  inspect(html.contains("Proof History"), content="true")
  inspect(html.contains("Refresh Context"), content="true")
  inspect(html.contains("Accept Review"), content="true")
  inspect(html.contains("Next Route"), content="true")
  inspect(html.contains("No MoonClaw context loaded"), content="true")
  inspect(html.contains("standing-goal-cockpit"), content="true")
  inspect(html.contains("0.10"), content="true")
  inspect(html.contains("No command submitted"), content="true")
  inspect(html.contains("No observation run submitted"), content="true")
  inspect(html.contains("receipt-cli-plan-walk"), content="true")
  inspect(html.contains("Bridge Error"), content="true")
  inspect(html.contains("Health"), content="true")
  inspect(html.contains("Runtime health not polled"), content="true")
  inspect(html.contains("Runtime log not polled"), content="true")
  inspect(html.contains("Log Path"), content="true")
  inspect(html.contains("Health Path"), content="true")
  inspect(html.contains("Refresh"), content="true")
}
