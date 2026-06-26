///|
test "host api emits cockpit snapshot response" {
  let response = @host_api.snapshot_response("examples/noetix-e1")
  assert_eq(response.status, 200)
  assert_eq(response.content_type, "application/json")
  assert_true(response.body.contains("\"robot_id\": \"noetix-e1-lab-01\""))
  assert_true(response.body.contains("\"product_status\""))
  assert_true(response.body.contains("\"service\": \"moonrobo\""))
  assert_true(response.body.contains("\"total_count\": 7"))
  assert_true(response.body.contains("\"live-exercise-closure\""))
  assert_true(response.body.contains("\"model_joints\": 24"))
  assert_true(response.body.contains("\"model_mapped_joints\": 24"))
  assert_true(response.body.contains("\"limit_state\": \"ok\""))
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
  assert_eq(registry.capability_count, 42)
  assert_true(
    response.body.contains("\"route\": \"/api/moonbook/conversation\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/session\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/ask\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/live-exercise\""),
  )
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/live-exercises\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/loop\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/turn\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/step\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/loops\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/loops/{loop_id}\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/turns\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/turns/{turn_id}\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/steps\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/steps/{step_id}\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/decision\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/gateway/command\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/loop-proof\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/prove-loop\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/proof-sessions\""),
  )
  assert_true(
    response.body.contains(
      "\"route\": \"/api/moonrobo/proof-sessions/{session_id}\"",
    ),
  )
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/executions/feedback\""),
  )
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/live-readiness\""),
  )
  assert_true(
    response.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/policies/evaluate\""))
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
test "host api projects empty Robo session over selected mapping" {
  let root = "/tmp/moonrobo-host-api-session-empty-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.robo_session_path())
  assert_eq(response.status, 200)
  let session : @host_api.RoboSessionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(session.status, "mapped")
  assert_true(!session.has_task_message)
  assert_eq(session.session.session_id, "robo-session:robot:noetix-e1-lab-01")
  assert_eq(session.session.stage, "no-task")
  assert_eq(
    session.session.continuation_route,
    @host_api.moonrobo_gateway_command_path(),
  )
  assert_eq(session.conversation.turn_count, 0)
  assert_eq(session.loop_count, 0)
  assert_eq(session.turn_count, 0)
  assert_eq(session.step_count, 0)
  assert_true(session.latest_loop is None)
  assert_true(session.mapping.mapped)
  assert_eq(session.memory.robot_id, "noetix-e1-lab-01")
  assert_eq(session.decision.next_owner, "operator")
  assert_eq(
    session.decision.next_route,
    @host_api.runtime_supervisor_start_path(),
  )
  assert_true(!session.decision.accepts_task_messages)
}

///|
test "host api projects Robo session after one user turn" {
  let root = "/tmp/moonrobo-host-api-session-turn-test"
  prepare_submission_root(root)
  let turn = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_turn_path(),
    @host_api.RoboTurnRequest::{
      task_message: @task.task_message_request(
        "session-turn",
        "",
        @core.operator_requester("rabbita"),
        "walk forward",
        4110L,
      ),
      run_agent: false,
      max_steps: 1,
      now_ms: 4110L,
      remember: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(turn.status, 200)
  let response = @host_api.route(root, "GET", @host_api.robo_session_path())
  assert_eq(response.status, 200)
  let session : @host_api.RoboSessionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(session.status, "active")
  assert_true(session.has_task_message)
  assert_eq(session.session.task_id, "message-session-turn")
  assert_eq(session.session.latest_user_text, "walk forward")
  assert_eq(session.conversation.turn_count, 1)
  assert_eq(session.loop_count, 0)
  assert_eq(session.turn_count, 1)
  assert_eq(session.step_count, 0)
  assert_true(session.latest_loop is None)
  assert_eq(session.decision.next_owner, "operator")
  assert_eq(
    session.decision.next_route,
    @host_api.runtime_supervisor_start_path(),
  )
  assert_true(!session.decision.accepts_task_messages)
  assert_true(
    session.latest_turn
    is Some({ turn_id: "robo-turn-message-session-turn-4110", .. }),
  )
  assert_eq(session.session.thread_id, "moonbook-task-messages")
  assert_eq(session.session.mapping_id, session.mapping.mapping_id)
}

///|
test "host api decision routes operator-bound blockers explicitly" {
  let root = "/tmp/moonrobo-host-api-decision-operator-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.robo_decision_path())
  assert_eq(response.status, 200)
  let decision : @host_api.RoboDecisionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(decision.status, "needs-operator")
  assert_true(!decision.can_act)
  assert_true(decision.needs_operator)
  assert_true(!decision.needs_agent)
  assert_eq(decision.next_owner, "operator")
  assert_eq(decision.next_route, @host_api.runtime_supervisor_start_path())
  assert_eq(decision.target_route, @host_api.runtime_supervisor_start_path())
  assert_eq(decision.next_kind, "start-runtime")
  assert_true(decision.queue_count > 0)
  assert_eq(decision.loop_status, "incomplete")
}

///|
test "host api decision exposes safe evidence work to MoonClaw" {
  let root = "/tmp/moonrobo-host-api-decision-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route(root, "GET", @host_api.robo_decision_path())
  assert_eq(response.status, 200)
  let decision : @host_api.RoboDecisionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(decision.status, "agent-work-ready")
  assert_true(decision.can_act)
  assert_true(!decision.needs_operator)
  assert_true(decision.needs_agent)
  assert_eq(decision.next_owner, "moonclaw")
  assert_eq(decision.next_route, @host_api.runtime_validation_session_path())
  assert_eq(decision.target_route, @host_api.runtime_validation_session_path())
  assert_eq(decision.next_kind, "validate-runtime")
  assert_true(!decision.physical_execution_allowed)
}

///|
test "host api ask persists MoonBook task message and returns decision" {
  let root = "/tmp/moonrobo-host-api-ask-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_ask_path(),
    task_message_json("ask-walk-now", "walk forward"),
  )
  assert_eq(response.status, 200)
  let ask : @host_api.RoboAskResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(ask.accepted)
  assert_eq(ask.task_id, "message-ask-walk-now")
  assert_eq(
    ask.message_path,
    root + "/moonbook/task-messages/message-ask-walk-now.json",
  )
  assert_eq(ask.conversation_route, @host_api.moonbook_conversation_path())
  assert_eq(
    ask.status_route,
    @host_api.moonbook_task_message_status_path("message-ask-walk-now"),
  )
  assert_eq(ask.submitted.message_plan.classification, "command-intent-review")
  assert_true(ask.memory.persisted)
  assert_eq(ask.memory.memory_path, ask.submitted.memory.memory_path)
  assert_eq(ask.conversation.conversation.turn_count, 1)
  assert_eq(
    ask.conversation.conversation.latest_task_id,
    "message-ask-walk-now",
  )
  assert_true(
    ask.loop_proof.checks.any(check => {
      check.code == "user-message-ledger" && check.ready
    }),
  )
  assert_true(ask.live_readiness.loop_proof == ask.loop_proof)
  assert_eq(ask.live_readiness.loop_proof.percent, ask.decision.loop_percent)
  assert_eq(ask.decision.status, "needs-operator")
  assert_eq(ask.decision.next_route, @host_api.runtime_supervisor_start_path())
  assert_true(@fsx.path_exists(ask.message_path))
  let conversation = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_conversation_path(),
  )
  assert_eq(conversation.status, 200)
  assert_true(conversation.body.contains("\"message_id\": \"ask-walk-now\""))
}

///|
test "host api turn leaves agent-ready work for MoonClaw" {
  let root = "/tmp/moonrobo-host-api-turn-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let request : @host_api.RoboTurnRequest = {
    task_message: @task.task_message_request(
      "turn-runtime-validation",
      "",
      @core.operator_requester("rabbita"),
      "walk forward",
      4100L,
    ),
    run_agent: true,
    max_steps: 2,
    now_ms: 4100L,
    remember: true,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_turn_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 200)
  let turn : @host_api.RoboTurnResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(turn.accepted)
  assert_true(turn.persisted)
  assert_true(!turn.agent_ran)
  assert_eq(turn.turn_id, "robo-turn-message-turn-runtime-validation-4100")
  assert_eq(turn.ask.decision.status, "agent-work-ready")
  assert_eq(
    turn.ask.decision.next_route,
    @host_api.runtime_validation_session_path(),
  )
  assert_eq(
    turn.ask.decision.target_route,
    @host_api.runtime_validation_session_path(),
  )
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-turn-runtime-validation.json",
    ),
  )
  assert_true(@fsx.path_exists(turn.turn_path))
  let turn_text = @fsx.read_file_to_string(turn.turn_path) catch {
    _ => fail("failed to read persisted Robo turn")
  }
  assert_true(turn_text.contains("\"agent_ran\": false"))
  assert_true(!turn_text.contains("\"work_run\""))
  let turns = @host_api.route(root, "GET", @host_api.robo_turns_path())
  assert_eq(turns.status, 200)
  assert_true(turns.body.contains("\"turn_count\": 1"))
  assert_true(
    turns.body.contains(
      "\"turn_id\": \"robo-turn-message-turn-runtime-validation-4100\"",
    ),
  )
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.robo_turn_detail_path(turn.turn_id),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"turn_path\": \"\{turn.turn_path}\""))
}

///|
test "host api loop persists current session without a separate task message" {
  let root = "/tmp/moonrobo-host-api-loop-current-test"
  prepare_submission_root(root)
  let request : @host_api.RoboLoopRequest = {
    loop_id: "current-loop",
    turn: None,
    max_steps: 2,
    now_ms: 4110L,
    remember: true,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_loop_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 200)
  let loop_run : @host_api.RoboLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(loop_run.loop_id, "current-loop")
  assert_true(loop_run.persisted)
  assert_true(!loop_run.accepted)
  assert_eq(loop_run.advanced_count, 0)
  assert_eq(loop_run.steps.length(), 0)
  assert_eq(loop_run.status, "needs-operator")
  assert_true(loop_run.turn is None)
  assert_eq(loop_run.session.step_count, 0)
  assert_true(@fsx.path_exists(loop_run.loop_path))
  let loops = @host_api.route(root, "GET", @host_api.robo_loops_path())
  assert_eq(loops.status, 200)
  assert_true(loops.body.contains("\"loop_count\": 1"))
  assert_true(loops.body.contains("\"loop_id\": \"current-loop\""))
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.robo_loop_detail_path(loop_run.loop_id),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"loop_path\": \"\{loop_run.loop_path}\""))
}

///|
test "host api loop accepts a user task and leaves MoonClaw work pending" {
  let root = "/tmp/moonrobo-host-api-loop-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let request : @host_api.RoboLoopRequest = {
    loop_id: "agent-loop",
    turn: Some({
      task_message: @task.task_message_request(
        "loop-runtime-validation",
        "",
        @core.operator_requester("rabbita"),
        "walk forward",
        4115L,
      ),
      run_agent: true,
      max_steps: 12,
      now_ms: 4115L,
      remember: true,
    }),
    max_steps: 2,
    now_ms: 4115L,
    remember: true,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_loop_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 200)
  let loop_run : @host_api.RoboLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(loop_run.loop_id, "agent-loop")
  assert_true(loop_run.persisted)
  assert_true(loop_run.accepted)
  assert_true(loop_run.turn is Some({ agent_ran: false, .. }))
  assert_eq(loop_run.status, "agent-ready")
  assert_eq(loop_run.steps.length(), 0)
  assert_eq(loop_run.advanced_count, 0)
  assert_true(loop_run.session.turn_count >= 1)
  assert_eq(loop_run.session.step_count, 0)
  assert_true(@fsx.path_exists(loop_run.loop_path))
  let loops = @host_api.route(root, "GET", @host_api.robo_loops_path())
  assert_eq(loops.status, 200)
  assert_true(loops.body.contains("\"loop_count\": 1"))
  assert_true(loops.body.contains("\"loop_id\": \"agent-loop\""))
  let session_response = @host_api.route(
    root,
    "GET",
    @host_api.robo_session_path(),
  )
  assert_eq(session_response.status, 200)
  let session : @host_api.RoboSessionResponse = @json.from_json(
    @json.parse(session_response.body),
  )
  assert_eq(session.loop_count, 1)
  assert_true(session.latest_loop is Some({ loop_id: "agent-loop", .. }))
  assert_true(
    session.latest_loop is Some({ final_route: route, .. }) &&
    route == loop_run.decision.next_route,
  )
}

///|
test "host api step stops when current decision belongs to operator" {
  let root = "/tmp/moonrobo-host-api-step-operator-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_step_path(),
    @host_api.RoboStepRequest::{
      run_id: "operator-step",
      max_steps: 2,
      now_ms: 4120L,
      remember: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let step : @host_api.RoboStepResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(step.step_id, "operator-step")
  assert_true(step.persisted)
  assert_true(!step.advanced)
  assert_eq(step.status, "needs-operator")
  assert_eq(step.decision_before.next_owner, "operator")
  assert_eq(step.decision_after.next_owner, "operator")
  assert_true(@fsx.path_exists(step.step_path))
  let steps = @host_api.route(root, "GET", @host_api.robo_steps_path())
  assert_eq(steps.status, 200)
  assert_true(steps.body.contains("\"step_count\": 1"))
  assert_true(steps.body.contains("\"step_id\": \"operator-step\""))
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.robo_step_detail_path(step.step_id),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"step_path\": \"\{step.step_path}\""))
}

///|
test "host api step records MoonClaw-owned work without running it" {
  let root = "/tmp/moonrobo-host-api-step-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robo_step_path(),
    @host_api.RoboStepRequest::{
      run_id: "agent-step",
      max_steps: 2,
      now_ms: 4130L,
      remember: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let step : @host_api.RoboStepResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(step.step_id, "agent-step")
  assert_true(step.persisted)
  assert_eq(step.status, "agent-ready")
  assert_true(!step.advanced)
  assert_eq(step.decision_before.next_owner, "moonclaw")
  assert_eq(
    step.decision_before.next_route,
    @host_api.runtime_validation_session_path(),
  )
  assert_true(@fsx.path_exists(step.step_path))
  let text = @fsx.read_file_to_string(step.step_path) catch {
    _ => fail("failed to read persisted Robo step")
  }
  assert_true(text.contains("\"advanced\": false"))
  assert_true(text.contains("\"decision_before\""))
  assert_true(text.contains("\"decision_after\""))
  let session_response = @host_api.route(
    root,
    "GET",
    @host_api.robo_session_path(),
  )
  assert_eq(session_response.status, 200)
  let session : @host_api.RoboSessionResponse = @json.from_json(
    @json.parse(session_response.body),
  )
  assert_eq(session.step_count, 1)
  assert_true(session.latest_step is Some({ step_id: "agent-step", .. }))
}

///|
test "host api summarizes closed loop proof gaps" {
  let root = "/tmp/moonrobo-host-api-loop-proof-partial-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let response = @host_api.route(
    root,
    "GET",
    @host_api.platform_loop_proof_path(),
  )
  assert_eq(response.status, 200)
  let proof : @host_api.PlatformLoopProofResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(proof.status, "incomplete")
  assert_true(!proof.ready)
  assert_eq(proof.completed_count, 1)
  assert_eq(proof.total_count, 6)
  assert_eq(proof.percent, 16)
  assert_eq(proof.next_route, @host_api.moonbook_memory_path())
  assert_true(
    response.body.contains("\"code\": \"physical-feedback-verified\""),
  )
}

///|
test "host api prove-loop bootstraps and attempts routine safely" {
  let root = "/tmp/moonrobo-host-api-prove-loop-partial-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_prove_loop_path(),
    @host_api.PlatformProveLoopRequest::{
      task_message: @task.task_message_request(
        "prove-loop-partial",
        "",
        @core.operator_requester("test"),
        "walk forward",
        3300L,
      ),
      max_steps: 8,
      bootstrap: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let proof : @host_api.PlatformProveLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(proof.advanced)
  assert_true(proof.bootstrap_applied)
  assert_true(proof.command_attempted)
  assert_true(!proof.ready)
  assert_true(proof.after.completed_count > proof.before.completed_count)
  assert_eq(proof.after.next_route, @host_api.robo_loop_path())
  assert_true(@fsx.path_exists(proof.proof_path))
  assert_true(@fsx.path_exists(proof.memory_path))
  assert_true(proof.bootstrap is Some(_))
  assert_true(proof.command is Some(_))
  let record_text = @fsx.read_file_to_string(proof.proof_path) catch {
    _ => fail("failed to read prove-loop record")
  }
  assert_true(
    record_text.contains("\"proof_id\": \"prove-loop-prove-loop-partial-3300\""),
  )
  assert_true(record_text.contains("\"completed_after\": 4"))
  let memory_text = @fsx.read_file_to_string(proof.memory_path) catch {
    _ => fail("failed to read prove-loop memory")
  }
  assert_true(memory_text.contains("\"kind\": \"closed-loop-proof\""))
  assert_true(memory_text.contains(proof.proof_path))
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-prove-loop-partial.json",
    ),
  )
}

///|
test "host api proof-session repeats prove-loop and stops on blocker" {
  let root = "/tmp/moonrobo-host-api-proof-session-blocked-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_proof_session_path(),
    @host_api.PlatformProofSessionRequest::{
      session_id: "proof-session-blocked",
      task_message: @task.task_message_request(
        "proof-session-blocked",
        "",
        @core.operator_requester("test"),
        "walk forward",
        3310L,
      ),
      iterations: 3,
      max_steps: 8,
      bootstrap: true,
      stop_when_ready: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let session : @host_api.PlatformProofSessionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(session.session_id, "proof-session-blocked")
  assert_eq(session.status, "blocked")
  assert_true(!session.ready)
  assert_eq(session.requested_iterations, 3)
  assert_eq(session.attempted_count, 2)
  assert_eq(session.stop_reason, "stalled")
  assert_eq(session.next_route, @host_api.robo_loop_path())
  assert_true(@fsx.path_exists(session.session_path))
  assert_true(@fsx.path_exists(session.latest_proof_path))
  assert_eq(session.attempts.length(), 2)
  assert_true(session.attempts[0].advanced)
  assert_true(!session.attempts[1].advanced)
  let persisted = @fsx.read_file_to_string(session.session_path) catch {
    _ => fail("failed to read proof-session record")
  }
  assert_true(persisted.contains("\"stop_reason\": \"stalled\""))
  assert_true(
    @fsx.path_exists(
      root +
      "/moonbook/task-messages/message-proof-session-blocked-attempt-1.json",
    ),
  )
  let list = @host_api.route(
    root,
    "GET",
    @host_api.platform_proof_sessions_path(),
  )
  assert_eq(list.status, 200)
  let listed : @host_api.PlatformProofSessionListResponse = @json.from_json(
    @json.parse(list.body),
  )
  assert_eq(listed.session_count, 1)
  assert_eq(listed.sessions[0].session_id, "proof-session-blocked")
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.platform_proof_session_detail_path("proof-session-blocked"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"session_id\": \"proof-session-blocked\""))
  assert_true(detail.body.contains("\"stop_reason\": \"stalled\""))
}

///|
test "host api proof-session blocks until external loop evidence exists" {
  let root = "/tmp/moonrobo-host-api-proof-session-complete-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  write_healthy_runtime(
    root,
    3400L,
    command_intent_id="intent-message-proof-session-complete-attempt-1",
  )
  write_verified_execution_snapshot(
    root, "proof-session-complete-attempt-1", 3400L,
  )
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_proof_session_path(),
    @host_api.PlatformProofSessionRequest::{
      session_id: "proof-session-complete",
      task_message: @task.task_message_request(
        "proof-session-complete",
        "",
        @core.operator_requester("test"),
        "walk forward",
        3400L,
      ),
      iterations: 4,
      max_steps: 8,
      bootstrap: true,
      stop_when_ready: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let session : @host_api.PlatformProofSessionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(session.session_id, "proof-session-complete")
  assert_eq(session.status, "blocked")
  assert_true(!session.ready)
  assert_eq(session.requested_iterations, 4)
  assert_eq(session.attempted_count, 2)
  assert_eq(session.stop_reason, "stalled")
  assert_eq(session.next_route, @host_api.robo_loop_path())
  assert_eq(session.attempts.length(), 2)
  assert_true(!session.attempts[0].ready)
  assert_true(@fsx.path_exists(session.session_path))
  assert_true(@fsx.path_exists(session.latest_proof_path))
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
  assert_true(before.body.contains("\"fail_count\": 6"))
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
  assert_true(after.body.contains("\"fail_count\": 3"))
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
  assert_true(readiness.body.contains("\"fail_count\": 3"))
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
test "host api runtime supervisor start requires native desktop host" {
  let root = "/tmp/moonrobo-host-api-runtime-start-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.runtime_supervisor_start_path(),
    "{}",
  )
  assert_eq(response.status, 501)
  assert_true(response.body.contains("native-runtime-required"))
  assert_true(!@fsx.path_exists(root + "/runs/runtime-health/latest.json"))
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
  assert_true(response.body.contains("\"gateway\""))
  assert_true(response.body.contains("\"service\": \"moonrobo-gateway\""))
  assert_true(response.body.contains("\"live_readiness\""))
  assert_true(response.body.contains("\"needs-runtime-validation\""))
  assert_true(response.body.contains("\"live_closure\""))
  assert_true(response.body.contains("\"has_exercise\": false"))
  let decoded : @host_api.MoonClawContextResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(decoded.live_closure.closure.missing.length(), 1)
  assert_eq(decoded.live_closure.closure.missing[0], "live-exercise")
  assert_true(response.body.contains("\"proof_sessions\""))
  assert_true(response.body.contains("\"session_count\": 0"))
  assert_true(response.body.contains("\"live_exercises\""))
  assert_true(response.body.contains("\"exercise_count\": 0"))
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
  assert_true(response.body.contains("\"mapping_stable\": true"))
  assert_true(response.body.contains("\"mapping_status\": \"stable\""))
  assert_true(response.body.contains("\"mapping_matching_sample_count\": 3"))
  assert_true(response.body.contains("\"mapping_mismatch_sample_count\": 0"))
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_calibration_plan_path(root)),
  )
  let context = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(context.status, 200)
  assert_true(context.body.contains("\"action\": \"RunRobotRoutine\""))
  assert_true(context.body.contains("\"gateway\""))
  assert_true(context.body.contains("\"live_readiness\""))
  assert_true(context.body.contains("\"ready-for-proof-session\""))
  assert_true(context.body.contains("\"live_exercises\""))
  assert_true(
    context.body.contains("\"route\": \"/api/moonrobo/gateway/command\""),
  )
}

///|
test "host api projects live readiness after runtime validation" {
  let root = "/tmp/moonrobo-host-api-live-readiness-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8155L)
  write_pending_runtime_revalidation(root)
  let validation = @host_api.route_with_body(
    root,
    "POST",
    @host_api.runtime_validation_session_path(),
    "",
  )
  assert_eq(validation.status, 200)
  assert_true(validation.body.contains("\"calibration_path\""))
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_calibration_plan_path(root)),
  )
  let response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_readiness_path(),
  )
  assert_eq(response.status, 200)
  let readiness : @host_api.MoonroboLiveReadinessResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(readiness.status, "ready-for-proof-session")
  assert_eq(readiness.calibration_status, "clear")
  assert_true(readiness.ready_for_live_sdk)
  assert_true(readiness.can_run_proof_session)
  assert_true(readiness.can_submit_gateway_command)
  assert_true(!readiness.physical_execution_allowed)
  assert_eq(readiness.proof_session_auto_feedback_attempted_count, 0)
  assert_eq(readiness.proof_session_auto_feedback_success_count, 0)
  assert_true(!readiness.proof_session_feedback_closed)
  assert_eq(readiness.next_method, "POST")
  assert_eq(readiness.next_route, @host_api.platform_proof_session_path())
  assert_true(readiness.runtime_validation_session is Some(_))
  assert_true(readiness.calibration is Some(_))
}

///|
test "host api reports missing live exercise closure compactly" {
  let root = "/tmp/moonrobo-host-api-live-closure-missing-test"
  prepare_submission_root(root)
  let response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_exercise_closure_path(),
  )
  assert_eq(response.status, 200)
  let closure : @host_api.MoonroboLiveExerciseClosureResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(!closure.has_exercise)
  assert_eq(closure.exercise_count, 0)
  assert_eq(closure.closure.status, "missing")
  assert_eq(closure.closure.missing.length(), 1)
  assert_eq(closure.closure.missing[0], "live-exercise")
  assert_eq(closure.next_route, @host_api.moonrobo_live_exercise_path())
}

///|
test "host api live exercise persists validation routine proof and memory" {
  let root = "/tmp/moonrobo-host-api-live-exercise-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8160L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonrobo_live_exercise_path(),
    @host_api.MoonroboLiveExerciseRequest::{
      exercise_id: "live-exercise-host",
      task_message: @task.task_message_request(
        "live-exercise-host",
        "",
        @core.operator_requester("rabbita"),
        "walk forward",
        8161L,
      ),
      validation_sample_count: 2,
      proof_iterations: 2,
      proof_max_steps: 4,
      bootstrap: true,
      stop_when_ready: true,
      remember: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let exercise : @host_api.MoonroboLiveExerciseResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(exercise.exercise_id, "live-exercise-host")
  assert_true(exercise.persisted)
  assert_true(@fsx.path_exists(exercise.exercise_path))
  assert_true(exercise.gateway_command.command.accepted)
  assert_true(exercise.proof_session.persisted)
  assert_true(exercise.readiness.runtime_validation_session is Some(_))
  assert_eq(exercise.closure.status, exercise.status)
  assert_eq(exercise.closure.requested_validation_sample_count, 2)
  assert_eq(exercise.closure.missing_count, exercise.closure.missing.length())
  assert_eq(exercise.closure.memory_persisted, exercise.memory.persisted)
  assert_eq(exercise.closure.next_route, exercise.next_route)
  if exercise.closure.missing_count == 0 {
    assert_true(exercise.closure.closed)
  } else {
    assert_true(!exercise.closure.closed)
  }
  assert_true(exercise.memory.persisted)
  assert_true(
    exercise.memory.pack.cards.any(card => card.kind == "live-exercise"),
  )
  assert_true(
    @fsx.path_exists(
      root + "/runs/proof-sessions/proof-session-live-exercise-host.json",
    ),
  )
  let listed = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_exercises_path(),
  )
  assert_eq(listed.status, 200)
  let history : @host_api.MoonroboLiveExerciseListResponse = @json.from_json(
    @json.parse(listed.body),
  )
  assert_eq(history.exercise_count, 1)
  assert_eq(history.exercises[0].exercise_id, "live-exercise-host")
  assert_eq(history.exercises[0].exercise_path, exercise.exercise_path)
  assert_eq(history.exercises[0].closure.status, exercise.closure.status)
  let closure_response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_exercise_closure_path(),
  )
  assert_eq(closure_response.status, 200)
  let closure : @host_api.MoonroboLiveExerciseClosureResponse = @json.from_json(
    @json.parse(closure_response.body),
  )
  assert_true(closure.has_exercise)
  assert_eq(closure.exercise_count, 1)
  assert_eq(closure.exercise_id, exercise.exercise_id)
  assert_eq(closure.exercise_path, exercise.exercise_path)
  assert_eq(closure.closure.status, exercise.closure.status)
  assert_eq(closure.next_route, exercise.closure.next_route)
  assert_true(closure.closure.missing.contains("physical-feedback"))
  let feedback_session = {
    ..exercise.proof_session,
    ready: true,
    status: "complete",
    auto_feedback_attempted_count: 1,
    auto_feedback_success_count: 1,
    latest_auto_feedback_status: 200,
    latest_auto_feedback_message: "Physical feedback verified after live exercise.",
  }
  @fsx.write_string_to_file(
    feedback_session.session_path,
    feedback_session.to_json().stringify(indent=2),
  ) catch {
    _ => fail("failed to write refreshed proof-session evidence")
  }
  let refreshed_closure_response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_exercise_closure_path(),
  )
  assert_eq(refreshed_closure_response.status, 200)
  let refreshed_closure : @host_api.MoonroboLiveExerciseClosureResponse = @json.from_json(
    @json.parse(refreshed_closure_response.body),
  )
  assert_true(refreshed_closure.has_exercise)
  assert_true(refreshed_closure.closure.feedback_closed)
  assert_true(!refreshed_closure.closure.missing.contains("physical-feedback"))
  let product = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_product_status_path(),
  )
  assert_eq(product.status, 200)
  let product_status : @product_status.MoonroboProductStatus = @json.from_json(
    @json.parse(product.body),
  )
  assert_true(
    product_status.capabilities.any(item => {
      item.code == "live-exercise-closure" &&
      item.ready == exercise.closure.closed &&
      item.evidence_path == exercise.exercise_path
    }),
  )
  let context = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(context.status, 200)
  assert_true(context.body.contains("\"live_closure\""))
  assert_true(context.body.contains("\"has_exercise\": true"))
  assert_true(context.body.contains("\"live_exercises\""))
  assert_true(context.body.contains("\"exercise_count\": 1"))
  assert_true(context.body.contains("\"exercise_id\": \"live-exercise-host\""))
  assert_true(context.body.contains("\"closure\""))
  let detail = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_exercise_detail_path("live-exercise-host"),
  )
  assert_eq(detail.status, 200)
  assert_true(detail.body.contains("\"exercise_id\": \"live-exercise-host\""))
  assert_true(detail.body.contains("\"closure\""))
  assert_true(detail.body.contains("\"gateway_command\""))
  assert_true(detail.body.contains("\"proof_session\""))
  let projected_memory = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_memory_path(),
  )
  assert_eq(projected_memory.status, 200)
  assert_true(
    projected_memory.body.contains("\"kind\": \"live-exercise-closure\""),
  )
  assert_true(projected_memory.body.contains(exercise.exercise_path))
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
  assert_true(response.body.contains("\"kind\": \"start-runtime\""))
  assert_true(response.body.contains("\"kind\": \"annotate-replay\""))
  assert_true(
    response.body.contains(
      "\"target_path\": \"/api/replays/task-work-queue-host-run-observe/annotations\"",
    ),
  )
  let next = @host_api.route(root, "GET", @host_api.agent_next_action_path())
  assert_eq(next.status, 200)
  assert_true(next.body.contains("\"action\""))
  assert_true(next.body.contains("\"kind\": \"start-runtime\""))
  assert_true(next.body.contains("\"http_method\": \"POST\""))
  assert_true(
    next.body.contains("\"route\": \"/api/runtime/supervisor/start\""),
  )
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
fn test_resident(availability : String) -> @resident.ResidentRobotAgent {
  {
    resident_id: "robot:noetix-e1-lab-01",
    robot_id: "noetix-e1-lab-01",
    label: "Noetix E1 Lab 01",
    platform: "noetix-e1",
    role: "physical-robot",
    availability,
    safety_state: "clear",
    bridge_state: if availability == "ready" {
      "launchable"
    } else {
      "missing-command"
    },
    active_observation: None,
    latest_observation: None,
    latest_receipt: None,
    latest_execution: None,
    latest_proof_session: None,
    execution_count: 0,
    verified_execution_count: 0,
    proof_session_count: 0,
    capability_count: 3,
    review_count: 0,
    command_path: "moonrobo-sdk-e1-bridge",
    town_route: "/town/residents/robot:noetix-e1-lab-01",
  }
}

///|
test "host api turns missing bridge contract into validation work" {
  let root = "/tmp/moonrobo-host-api-bridge-contract-work-test"
  prepare_submission_root(root)
  let book = @runtime.load_robobook(root).unwrap()
  let blocked = @host_api.bridge_contract_validation_work(
    root,
    book,
    test_resident("bridge-missing"),
  )
  assert_true(blocked is None)
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        7100L, "running-unprobed", true, true, 42, "launch-bridge-contract", "noetix-e1-lab-01:sdk-e1",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", false, "unknown",
        "runtime process is running; telemetry has not been probed", "", "", 0L,
      ),
    ),
  )
  let runtime_work = @host_api.bridge_contract_validation_work(
    root,
    book,
    test_resident("bridge-missing"),
  )
  assert_true(runtime_work is Some(_))
  let work = @host_api.bridge_contract_validation_work(
    root,
    book,
    test_resident("ready"),
  )
  let evidence = work.unwrap()
  assert_eq(evidence.plan_id, "readiness-noetix-e1-lab-01-bridge-contract")
  assert_eq(evidence.first_blocker_code, "bridge-contract-ready")
  assert_true(evidence.pending_revalidation)
  assert_eq(evidence.validation_path, "/api/runtime/validation/session")
}

///|
test "host api advances from started runtime to validation work" {
  let root = "/tmp/moonrobo-host-api-runtime-started-work-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        7200L, "running-unprobed", true, true, 42, "launch-runtime-started-work",
        "noetix-e1-lab-01:sdk-e1", "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391",
        false, "unknown", "runtime process is running; telemetry has not been probed",
        "", "", 0L,
      ),
    ),
  )
  let next = @host_api.route(root, "GET", @host_api.agent_next_action_path())
  assert_eq(next.status, 200)
  assert_true(next.body.contains("\"kind\": \"validate-runtime\""))
  assert_true(
    next.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  assert_true(!next.body.contains("\"kind\": \"start-runtime\""))
}

///|
test "host api dispatches proof-session work through agent rail" {
  let root = "/tmp/moonrobo-host-api-proof-session-work-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let queue = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"run-proof-session\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/moonrobo/proof-session\""),
  )
  let next = @host_api.route(root, "GET", @host_api.agent_next_action_path())
  assert_eq(next.status, 200)
  assert_true(next.body.contains("\"kind\": \"start-runtime\""))
  assert_true(
    next.body.contains("\"route\": \"/api/runtime/supervisor/start\""),
  )
  assert_true(next.body.contains("\"physical_execution_allowed\": false"))
  let dispatched = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    @host_api.AgentDispatchRequest::{
      work_id: "work-noetix-e1-lab-01-proof-session",
      body: None,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(dispatched.status, 200)
  assert_true(dispatched.body.contains("\"dispatched\": true"))
  assert_true(dispatched.body.contains("\"kind\": \"run-proof-session\""))
  assert_true(dispatched.body.contains("\"downstream_status\": 200"))
  assert_true(dispatched.body.contains("\"stop_reason\": \"stalled\""))
  assert_true(
    @fsx.path_exists(
      root + "/runs/proof-sessions/proof-session-noetix-e1-lab-01.json",
    ),
  )
  let resident = @host_api.route(root, "GET", @host_api.resident_path())
  assert_eq(resident.status, 200)
  assert_true(resident.body.contains("\"latest_proof_session\""))
  assert_true(resident.body.contains("\"proof_session_count\": 1"))
  assert_true(
    resident.body.contains("\"session_id\": \"proof-session-noetix-e1-lab-01\""),
  )
  let memory = @host_api.route(root, "GET", @host_api.moonbook_memory_path())
  assert_eq(memory.status, 200)
  assert_true(memory.body.contains("\"kind\": \"latest-proof-session\""))
  assert_true(
    memory.body.contains(
      "/runs/proof-sessions/proof-session-noetix-e1-lab-01.json",
    ),
  )
  let context = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(context.status, 200)
  assert_true(context.body.contains("\"live_readiness\""))
  assert_true(context.body.contains("\"proof_sessions\""))
  assert_true(context.body.contains("\"live_exercises\""))
  assert_true(context.body.contains("\"session_count\": 1"))
  assert_true(
    context.body.contains("\"session_id\": \"proof-session-noetix-e1-lab-01\""),
  )
}

///|
test "host api exposes gateway command work without recursive agent dispatch" {
  let root = "/tmp/moonrobo-host-api-gateway-command-work-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  write_healthy_runtime(root, 8185L)
  write_pending_runtime_revalidation(root)
  let validation = @host_api.route_with_body(
    root,
    "POST",
    @host_api.runtime_validation_session_path(),
    "",
  )
  assert_eq(validation.status, 200)
  let queue = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"run-live-exercise\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/moonrobo/live-exercise\""),
  )
  assert_true(queue.body.contains("\"kind\": \"submit-gateway-command\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/moonrobo/gateway/command\""),
  )
  let next = @host_api.route(root, "GET", @host_api.agent_next_action_path())
  assert_eq(next.status, 200)
  assert_true(next.body.contains("\"kind\": \"run-live-exercise\""))
  assert_true(next.body.contains("\"route\": \"/api/moonrobo/live-exercise\""))
  let blocked = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    @host_api.AgentDispatchRequest::{
      work_id: "work-noetix-e1-lab-01-gateway-command",
      body: None,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(blocked.status, 409)
  assert_true(blocked.body.contains("agent-action-not-dispatchable"))
  assert_true(blocked.body.contains("/api/moonrobo/gateway/command"))
  let dispatched = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    @host_api.AgentDispatchRequest::{
      work_id: "work-noetix-e1-lab-01-live-exercise",
      body: None,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(dispatched.status, 200)
  assert_true(dispatched.body.contains("\"dispatched\": true"))
  assert_true(dispatched.body.contains("\"kind\": \"run-live-exercise\""))
  assert_true(dispatched.body.contains("\"downstream_status\": 200"))
  assert_true(
    @fsx.path_exists(
      root + "/runs/live-exercises/live-exercise-noetix-e1-lab-01.json",
    ),
  )
}

///|
test "host api dispatches runtime validation through agent rail" {
  let root = "/tmp/moonrobo-host-api-runtime-validation-dispatch-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8175L)
  write_pending_runtime_revalidation(root)
  let dispatched = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    "",
  )
  assert_eq(dispatched.status, 200)
  assert_true(dispatched.body.contains("\"dispatched\": true"))
  assert_true(dispatched.body.contains("\"kind\": \"validate-runtime\""))
  assert_true(dispatched.body.contains("\"downstream_status\": 200"))
  assert_true(
    dispatched.body.contains("\"route\": \"/api/runtime/validation/session\""),
  )
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
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
fn write_healthy_runtime(
  root : String,
  recorded_at_ms : Int64,
  command_intent_id? : String = "",
  command_bridge_request_id? : String = "",
  command_receipt_id? : String = "",
) -> Unit {
  let bridge_request_id = if command_bridge_request_id == "" {
    "request-execute-\{command_intent_id}-\{recorded_at_ms}"
  } else {
    command_bridge_request_id
  }
  let receipt_id = if command_receipt_id == "" {
    "receipt-\{command_intent_id}-executed"
  } else {
    command_receipt_id
  }
  let frame = {
    ..@core.empty_telemetry_frame(
      "frame-gateway-command-dispatch", "noetix-e1-lab-01", "sdk-e1", recorded_at_ms,
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
        "command_bridge_request_id": bridge_request_id,
        "command_receipt_id": receipt_id,
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
        recorded_at_ms, "healthy", true, true, 42, "launch-gateway-command-dispatch",
        "runtime-gateway-command-dispatch", "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391",
        true, "ok", "telemetry healthy", telemetry_path, "frame-gateway-command-dispatch",
        recorded_at_ms,
      ),
    ).unwrap(),
  )
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  ignore(
    @runtime.write_bridge_contract(
      root,
      "bridge-contract-\{recorded_at_ms}",
      @bridge_protocol.bridge_contract(profile, false, operations=[
        Contract,
        LatestTelemetry,
        ExecuteIntent,
        EmergencyStop,
      ])
      .to_json()
      .stringify(indent=2),
    ),
  )
}

///|
fn write_verified_execution_snapshot(
  root : String,
  base_id : String,
  recorded_at_ms : Int64,
) -> Unit {
  let intent_id = "intent-message-\{base_id}"
  let receipt_id = "receipt-\{intent_id}-executed"
  let request_id = "request-execute-\{intent_id}-\{recorded_at_ms}"
  let intent = @core.command_intent(
    intent_id,
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("test"),
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "verified execution fixture",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-\{intent_id}-ready",
    "sdk-e1",
    intent,
    verdict,
    recorded_at_ms,
  )
  let receipt = @core.executed_receipt(receipt_id, ready, recorded_at_ms + 1L)
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-\{base_id}",
    request_id,
    "sdk-e1",
    "noetix-e1-lab-01",
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    recorded_at_ms + 1L,
  )
  let feedback_path = @runtime.write_telemetry_frame(
    root,
    "runtime-\{base_id}",
    {
      ..@core.empty_telemetry_frame(
        "frame-\{base_id}",
        "noetix-e1-lab-01",
        "sdk-e1",
        recorded_at_ms + 2L,
      ),
      imu: Some({
        orientation: [1.0, 0.0, 0.0, 0.0],
        angular_velocity: [0.0, 0.0, 0.0],
        linear_acceleration: [0.0, 0.0, 9.8],
      }),
      operator_input: {
        "source": "sdk-e1",
        "command_intent_id": intent.intent_id,
        "command_capability": intent.capability,
        "command_bridge_request_id": dispatch.request_id,
        "command_receipt_id": receipt.receipt_id,
      },
    },
  ).unwrap()
  let snapshot = @core.task_execution_snapshot(
    "task-execution-\{base_id}",
    "message-\{base_id}",
    root + "/moonbook/task-messages/message-\{base_id}.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    recorded_at_ms + 1L,
    runtime_health_path=root + "/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/moonrobo.log",
    telemetry_frame_id="frame-\{base_id}",
    telemetry_captured_at_ms=recorded_at_ms + 2L,
    physical_feedback_path=feedback_path,
    checked_command_outcome_status="motion-feedback-checked",
    checked_command_outcome_verified=true,
  )
  ignore(@runtime.write_run_receipt(root, receipt).unwrap())
  ignore(@runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap())
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
}

///|
fn write_pending_runtime_revalidation(root : String) -> Unit {
  ignore(
    @runtime.write_runtime_calibration_plan(
      root,
      "runtime-calibration-gateway-command",
      (
        #|{
        #|  "plan_id": "runtime-calibration-gateway-command",
        #|  "generated_at_ms": "3000",
        #|  "session_id": "runtime-validation-session-gateway-command",
        #|  "runtime_id": "runtime-noetix-e1-lab-01:sdk-e1",
        #|  "robot_id": "noetix-e1-lab-01",
        #|  "bridge_id": "sdk-e1",
        #|  "status": "needs-calibration",
        #|  "action_count": 1,
        #|  "blocking_action_count": 1,
        #|  "actions": [
        #|    {
        #|      "action_id": "calibrate-runtime-gateway-command",
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
      "runtime-calibration-resolution-gateway-command",
      (
        #|{
        #|  "resolution_id": "runtime-calibration-resolution-gateway-command",
        #|  "plan_id": "runtime-calibration-gateway-command",
        #|  "action_id": "calibrate-runtime-gateway-command",
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
test "host api gateway command persists MoonClaw-authored task ingress" {
  let command_root = "/tmp/moonrobo-host-api-gateway-command-test"
  prepare_submission_root(command_root)
  complete_required_paths(command_root)
  write_healthy_runtime(
    command_root,
    3180L,
    command_intent_id="intent-message-gateway-command-now",
  )
  write_pending_runtime_revalidation(command_root)
  let command = @host_api.route_with_body(
    command_root,
    "POST",
    @host_api.moonrobo_gateway_command_path(),
    @host_api.MoonroboGatewayCommandRequest::{
      command_id: "gateway-command-now",
      robot_id: "",
      requested_by: @core.moontown_requester("moonclaw"),
      goal: "walk forward",
      now_ms: 3180L,
      remember: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(command.status, 200)
  assert_true(command.body.contains("\"gateway\""))
  assert_true(command.body.contains("\"ask\""))
  let command_decoded : @host_api.MoonroboGatewayCommandResponse = @json.from_json(
    @json.parse(command.body),
  )
  assert_true(command_decoded.command.accepted)
  assert_eq(command_decoded.command.command_id, "gateway-command-now")
  assert_eq(command_decoded.command.robot_id, "noetix-e1-lab-01")
  assert_eq(command_decoded.command.status, "accepted")
  assert_true(
    command_decoded.message.contains(
      "policy execution remains outside Moonrobo",
    ),
  )
  assert_eq(
    command_decoded.command.next_route,
    command_decoded.ask.unwrap().decision.next_route,
  )
  assert_true(@fsx.path_exists(command_decoded.command.command_path))
  assert_true(@fsx.path_exists(command_decoded.command.message_path))
  let prove_root = "/tmp/moonrobo-host-api-prove-loop-complete-test"
  prepare_submission_root(prove_root)
  complete_required_paths(prove_root)
  write_healthy_runtime(
    prove_root,
    3190L,
    command_intent_id="intent-message-prove-loop-complete",
  )
  write_verified_execution_snapshot(prove_root, "prove-loop-complete", 3190L)
  write_pending_runtime_revalidation(prove_root)
  let prove = @host_api.route_with_body(
    prove_root,
    "POST",
    @host_api.platform_prove_loop_path(),
    @host_api.PlatformProveLoopRequest::{
      task_message: @task.task_message_request(
        "prove-loop-complete",
        "",
        @core.operator_requester("test"),
        "walk forward",
        3190L,
      ),
      max_steps: 8,
      bootstrap: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(prove.status, 200)
  let prove_decoded : @host_api.PlatformProveLoopResponse = @json.from_json(
    @json.parse(prove.body),
  )
  assert_true(!prove_decoded.ready)
  assert_eq(prove_decoded.status, "operational-unproven")
  assert_eq(prove_decoded.after.completed_count, 5)
  assert_eq(prove_decoded.after.percent, 83)
  assert_true(prove_decoded.bootstrap_applied)
  assert_true(prove_decoded.command_attempted)
  assert_eq(prove_decoded.command_http_status, 200)
  assert_eq(prove_decoded.next_route, @host_api.robo_loop_path())
  assert_true(@fsx.path_exists(prove_decoded.proof_path))
  assert_true(@fsx.path_exists(prove_decoded.memory_path))
  match prove_decoded.command {
    Some(command) => {
      let record_text = @fsx.read_file_to_string(prove_decoded.proof_path) catch {
        _ => fail("failed to read prove-loop record")
      }
      let record : @host_api.PlatformProveLoopRecord = @json.from_json(
        @json.parse(record_text),
      )
      assert_eq(record.command_path, command.command.command_path)
      assert_eq(record.message_path, command.command.message_path)
    }
    None => fail("prove-loop did not include command response")
  }
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
        "command_bridge_request_id": dispatch.request_id,
        "command_receipt_id": receipt.receipt_id,
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
    checked_command_outcome_status="motion-feedback-checked",
    checked_command_outcome_verified=true,
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
test "host api binds execution feedback and refreshes proof" {
  let root = "/tmp/moonrobo-host-api-task-execution-feedback-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-feedback-bind",
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("rabbita"),
    parameters={ "x": "0.4", "yaw": "0.0", "duration_ms": "700" },
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "feedback binding intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-feedback-ready", "sdk-e1", intent, verdict, 4000L,
  )
  let receipt = @core.executed_receipt(
    "receipt-feedback-executed", ready, 4001L,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-request-feedback-bind",
    "request-feedback-bind",
    "sdk-e1",
    "noetix-e1-lab-01",
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    4001L,
  )
  ignore(@runtime.write_run_receipt(root, receipt).unwrap())
  ignore(@runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap())
  let snapshot = @core.task_execution_snapshot(
    "task-execution-feedback-bind",
    "message-feedback-bind",
    root + "/moonbook/task-messages/message-feedback-bind.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    4001L,
    runtime_health_path=root + "/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/moonrobo.log",
  )
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
  let feedback = {
    ..@core.empty_telemetry_frame(
      "frame-feedback-bind", "noetix-e1-lab-01", "sdk-e1", 4002L,
    ),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": intent.capability,
      "command_bridge_request_id": dispatch.request_id,
      "command_receipt_id": receipt.receipt_id,
      "command_x": "0.4",
      "command_yaw": "0.0",
      "command_duration_ms": "700",
    },
  }
  let feedback_path = @runtime.write_telemetry_frame(
    root, "agent-feedback-bind", feedback,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        4002L, "healthy", true, true, 42, "launch-feedback-bind", "runtime-feedback-bind",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        feedback_path, "frame-feedback-bind", 4002L,
      ),
    ).unwrap(),
  )
  let queue = @host_api.route(root, "GET", @host_api.agent_work_queue_path())
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"bind-execution-feedback\""))
  assert_true(
    queue.body.contains(
      "\"target_path\": \"/api/moonrobo/executions/feedback\"",
    ),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.agent_dispatch_next_path(),
    @host_api.AgentDispatchRequest::{
      work_id: "work-task-execution-feedback-bind-bind-feedback",
      body: None,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"dispatched\": true"))
  assert_true(response.body.contains("\"kind\": \"bind-execution-feedback\""))
  assert_true(response.body.contains("\"downstream_status\": 200"))
  assert_true(response.body.contains("\"verified\": true"))
  let bound = @runtime.read_task_execution_snapshot(
    root, "task-execution-feedback-bind",
  ).unwrap()
  assert_eq(bound.telemetry_frame_id, "frame-feedback-bind")
  assert_eq(bound.physical_feedback_status, "matched")
  assert_eq(bound.command_outcome_status, "motion-feedback-checked")
  let report_response = @host_api.route(
    root,
    "GET",
    @host_api.task_executions_path(),
  )
  assert_eq(report_response.status, 200)
  let report : @host_api.TaskExecutionProofReport = @json.from_json(
    @json.parse(report_response.body),
  )
  assert_eq(report.verified_count, 1)
  let loop_response = @host_api.route(
    root,
    "GET",
    @host_api.platform_loop_proof_path(),
  )
  assert_eq(loop_response.status, 200)
  assert_true(
    loop_response.body.contains("\"code\": \"physical-feedback-verified\""),
  )
  assert_true(loop_response.body.contains("\"ready\": true"))
}

///|
test "host api prove-loop auto binds queued execution feedback" {
  let root = "/tmp/moonrobo-host-api-prove-loop-auto-feedback-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-auto-feedback",
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("rabbita"),
    parameters={ "x": "0.2", "yaw": "0.0", "duration_ms": "600" },
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "auto feedback proof intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-auto-feedback-ready", "sdk-e1", intent, verdict, 4100L,
  )
  let receipt = @core.executed_receipt(
    "receipt-auto-feedback-executed", ready, 4101L,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-request-auto-feedback",
    "request-auto-feedback",
    "sdk-e1",
    "noetix-e1-lab-01",
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    4101L,
  )
  ignore(@runtime.write_run_receipt(root, receipt).unwrap())
  ignore(@runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap())
  let snapshot = @core.task_execution_snapshot(
    "task-execution-auto-feedback",
    "message-auto-feedback",
    root + "/moonbook/task-messages/message-auto-feedback.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    4101L,
    runtime_health_path=root + "/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/moonrobo.log",
  )
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
  let feedback = {
    ..@core.empty_telemetry_frame(
      "frame-auto-feedback", "noetix-e1-lab-01", "sdk-e1", 4102L,
    ),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": intent.capability,
      "command_bridge_request_id": dispatch.request_id,
      "command_receipt_id": receipt.receipt_id,
      "command_x": "0.2",
      "command_yaw": "0.0",
      "command_duration_ms": "600",
    },
  }
  let feedback_path = @runtime.write_telemetry_frame(
    root, "runtime-auto-feedback", feedback,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        4102L, "healthy", true, true, 42, "launch-auto-feedback", "runtime-auto-feedback",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        feedback_path, "frame-auto-feedback", 4102L,
      ),
    ).unwrap(),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_prove_loop_path(),
    @host_api.PlatformProveLoopRequest::{
      task_message: @task.task_message_request(
        "prove-loop-auto-feedback",
        "",
        @core.operator_requester("rabbita"),
        "walk forward",
        4103L,
      ),
      max_steps: 6,
      bootstrap: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"auto_feedback_attempted\": true"))
  assert_true(response.body.contains("\"auto_feedback_status\": 200"))
  assert_true(response.body.contains("\"downstream_status\": 200"))
  let proof : @host_api.PlatformProveLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(!proof.ready)
  assert_true(!proof.after.ready)
  assert_eq(proof.after.next_route, @host_api.robo_loop_path())
  let bound = @runtime.read_task_execution_snapshot(
    root, "task-execution-auto-feedback",
  ).unwrap()
  assert_eq(bound.telemetry_frame_id, "frame-auto-feedback")
  assert_eq(bound.physical_feedback_status, "matched")
  assert_eq(bound.command_outcome_status, "motion-feedback-checked")
}

///|
test "host api proof-session rolls up automatic feedback binding" {
  let root = "/tmp/moonrobo-host-api-proof-session-auto-feedback-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-proof-session-auto-feedback",
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("rabbita"),
    parameters={ "x": "0.2", "yaw": "0.0", "duration_ms": "600" },
  )
  let verdict : @core.SafetyVerdict = {
    intent_id: intent.intent_id,
    robot_id: intent.robot_id,
    capability: intent.capability,
    decision: Allow,
    reason: Safe,
    detail: "proof session auto feedback intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-proof-session-auto-feedback-ready", "sdk-e1", intent, verdict, 4200L,
  )
  let receipt = @core.executed_receipt(
    "receipt-proof-session-auto-feedback-executed", ready, 4201L,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-request-proof-session-auto-feedback",
    "request-proof-session-auto-feedback",
    "sdk-e1",
    "noetix-e1-lab-01",
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    receipt.receipt_id,
    "Accepted",
    "bridge receipt",
    4201L,
  )
  ignore(@runtime.write_run_receipt(root, receipt).unwrap())
  ignore(@runtime.write_bridge_dispatch_evidence(root, dispatch).unwrap())
  let snapshot = @core.task_execution_snapshot(
    "task-execution-proof-session-auto-feedback",
    "message-proof-session-auto-feedback",
    root + "/moonbook/task-messages/message-proof-session-auto-feedback.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    4201L,
    runtime_health_path=root + "/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root + "/runs/runtime-supervisor/moonrobo.log",
  )
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
  let feedback = {
    ..@core.empty_telemetry_frame(
      "frame-proof-session-auto-feedback", "noetix-e1-lab-01", "sdk-e1", 4202L,
    ),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": intent.capability,
      "command_bridge_request_id": dispatch.request_id,
      "command_receipt_id": receipt.receipt_id,
      "command_x": "0.2",
      "command_yaw": "0.0",
      "command_duration_ms": "600",
    },
  }
  let feedback_path = @runtime.write_telemetry_frame(
    root, "runtime-proof-session-auto-feedback", feedback,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        4202L, "healthy", true, true, 42, "launch-proof-session-auto-feedback", "runtime-proof-session-auto-feedback",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        feedback_path, "frame-proof-session-auto-feedback", 4202L,
      ),
    ).unwrap(),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_proof_session_path(),
    @host_api.PlatformProofSessionRequest::{
      session_id: "proof-session-auto-feedback",
      task_message: @task.task_message_request(
        "proof-session-auto-feedback",
        "",
        @core.operator_requester("rabbita"),
        "walk forward",
        4203L,
      ),
      iterations: 2,
      max_steps: 6,
      bootstrap: true,
      stop_when_ready: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  let session : @host_api.PlatformProofSessionResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(!session.ready)
  assert_eq(session.auto_feedback_attempted_count, 1)
  assert_eq(session.auto_feedback_success_count, 1)
  assert_eq(session.latest_auto_feedback_status, 200)
  assert_true(session.latest_auto_feedback_message.contains("verified"))
  assert_true(response.body.contains("\"auto_feedback_success_count\": 1"))
  let readiness_response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_readiness_path(),
  )
  assert_eq(readiness_response.status, 200)
  let readiness : @host_api.MoonroboLiveReadinessResponse = @json.from_json(
    @json.parse(readiness_response.body),
  )
  assert_true(readiness.proof_session_feedback_closed)
  assert_eq(readiness.proof_session_auto_feedback_success_count, 1)
  assert_eq(readiness.proof_session_latest_feedback_status, 200)
  let product_response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_product_status_path(),
  )
  assert_eq(product_response.status, 200)
  let product : @product_status.MoonroboProductStatus = @json.from_json(
    @json.parse(product_response.body),
  )
  assert_true(!product.ready)
  assert_true(
    product.capabilities.any(item => {
      item.code == "physical-feedback-verified" &&
      !item.ready &&
      item.evidence_path == session.session_path
    }),
  )
  assert_true(
    product.capabilities.any(item => {
      item.code == "live-exercise-closure" && !item.ready
    }),
  )
  let resident_response = @host_api.route(
    root,
    "GET",
    @host_api.resident_path(),
  )
  assert_eq(resident_response.status, 200)
  assert_true(resident_response.body.contains("\"feedback_closed\": true"))
  assert_true(
    resident_response.body.contains("\"latest_feedback_status\": 200"),
  )
  let memory_response = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_memory_path(),
  )
  assert_eq(memory_response.status, 200)
  assert_true(
    memory_response.body.contains("\"kind\": \"latest-proof-session\""),
  )
  assert_true(memory_response.body.contains("feedback 1/1"))
  assert_true(memory_response.body.contains("feedback_closed true"))
  let bound = @runtime.read_task_execution_snapshot(
    root, "task-execution-proof-session-auto-feedback",
  ).unwrap()
  assert_eq(bound.physical_feedback_status, "matched")
  clear_json_files(root + "/runs/task-executions")
  let durable_response = @host_api.route(
    root,
    "GET",
    @host_api.platform_loop_proof_path(),
  )
  assert_eq(durable_response.status, 200)
  let durable : @host_api.PlatformLoopProofResponse = @json.from_json(
    @json.parse(durable_response.body),
  )
  assert_true(!durable.ready)
  assert_eq(durable.next_route, @host_api.robo_loop_path())
  assert_true(
    durable.checks.any(item => {
      item.code == "physical-feedback-verified" &&
      item.ready &&
      item.evidence_path == session.session_path &&
      item.evidence_route == @host_api.platform_proof_sessions_path()
    }),
  )
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
test "host api does not expose MoonClaw work-step runner" {
  let root = "/tmp/moonrobo-host-api-moonclaw-work-step-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8350L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root, "POST", "/api/moonclaw/work-step", "{\"work_id\":\"\",\"now_ms\":8400,\"remember\":true}",
  )
  assert_eq(response.status, 404)
  assert_true(response.body.contains("No Moonrobo host API route"))
}

///|
test "host api does not expose MoonClaw work-run runner" {
  let root = "/tmp/moonrobo-host-api-moonclaw-work-run-test"
  prepare_submission_root(root)
  ensure_dir(root + "/runs/proof-sessions")
  ensure_dir(root + "/runs/prove-loop")
  ensure_dir(root + "/runs/moonclaw-work-runs")
  ensure_dir(root + "/runs/moonclaw-work-steps")
  clear_json_files(root + "/runs/proof-sessions")
  clear_json_files(root + "/runs/prove-loop")
  clear_json_files(root + "/runs/moonclaw-work-runs")
  clear_json_files(root + "/runs/moonclaw-work-steps")
  write_healthy_runtime(root, 8450L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root, "POST", "/api/moonclaw/work-run", "{\"run_id\":\"\",\"max_steps\":4,\"now_ms\":8500,\"remember\":true}",
  )
  assert_eq(response.status, 404)
  assert_true(response.body.contains("No Moonrobo host API route"))
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
  ensure_dir(root + "/runs/bridge-contracts")
  ensure_dir(root + "/runs/task-executions")
  ensure_dir(root + "/runs/runtime-health")
  ensure_dir(root + "/runs/runtime-validation")
  ensure_dir(root + "/runs/runtime-validation/sessions")
  ensure_dir(root + "/runs/runtime-calibration")
  ensure_dir(root + "/runs/runtime-calibration/resolutions")
  ensure_dir(root + "/runs/prove-loop")
  ensure_dir(root + "/runs/proof-sessions")
  ensure_dir(root + "/runs/gateway-commands")
  ensure_dir(root + "/runs/agent-process")
  ensure_dir(root + "/runs/robo-turns")
  ensure_dir(root + "/runs/robo-steps")
  ensure_dir(root + "/runs/robo-loops")
  ensure_dir(root + "/runs/observations")
  ensure_dir(root + "/runs/reviews")
  ensure_dir(root + "/runs/policy-evals")
  ensure_dir(root + "/moonbook")
  ensure_dir(root + "/moonbook/memory")
  ensure_dir(root + "/moonbook/task-messages")
  ensure_dir(root + "/agents")
  ensure_dir(root + "/model")
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/dry-runs")
  clear_json_files(root + "/runs/approvals")
  clear_json_files(root + "/runs/bridge-dispatches")
  clear_json_files(root + "/runs/bridge-contracts")
  clear_json_files(root + "/runs/task-executions")
  clear_json_files(root + "/runs/runtime-health")
  clear_json_files(root + "/runs/runtime-validation")
  clear_json_files(root + "/runs/runtime-validation/sessions")
  clear_json_files(root + "/runs/runtime-calibration")
  clear_json_files(root + "/runs/runtime-calibration/resolutions")
  clear_json_files(root + "/runs/prove-loop")
  clear_json_files(root + "/runs/proof-sessions")
  clear_json_files(root + "/runs/gateway-commands")
  clear_json_files(root + "/runs/agent-process")
  clear_json_files(root + "/runs/robo-turns")
  clear_json_files(root + "/runs/robo-steps")
  clear_json_files(root + "/runs/robo-loops")
  clear_json_files(root + "/runs/observations")
  clear_json_files(root + "/runs/reviews")
  clear_json_files(root + "/runs/policy-evals")
  clear_json_files(root + "/moonbook/memory")
  clear_json_files(root + "/moonbook/task-messages")
  clear_json_files(root + "/agents")
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write test profile")
  }
  let model = @fsx.read_file_to_string("examples/noetix-e1/model/robot.urdf") catch {
    _ => fail("failed to read example model")
  }
  @fsx.write_string_to_file(root + "/model/robot.urdf", model) catch {
    _ => fail("failed to write test model")
  }
}

///|
test "host API imports URDF folder and activates profile" {
  let root = "/tmp/moonrobo-host-urdf-import-root"
  let source = "/tmp/moonrobo-host-urdf-import-source"
  prepare_submission_root(root)
  ensure_dir(source)
  ensure_dir(source + "/urdf")
  ensure_dir(source + "/meshes")
  @fsx.write_string_to_file(
    source + "/meshes/base.STL",
    "solid base\nendsolid base\n",
  ) catch {
    _ => fail("failed to write host import mesh fixture")
  }
  @fsx.write_string_to_file(
    source + "/urdf/host.urdf",
    (
      #|<robot name="host_import_bot">
      #|  <link name="base_link">
      #|    <visual><geometry><mesh filename="package://host_import_bot/meshes/base.STL"/></geometry></visual>
      #|  </link>
      #|  <link name="head_link"/>
      #|  <joint name="head_joint" type="continuous">
      #|    <parent link="base_link"/>
      #|    <child link="head_link"/>
      #|  </joint>
      #|</robot>
    ),
  ) catch {
    _ => fail("failed to write host import URDF fixture")
  }
  let request : @runtime.UrdfImportRequest = {
    source_path: source,
    import_id: "host-import",
    activate: true,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_import_urdf_path(),
    request.to_json().stringify(),
  )
  inspect(response.status, content="200")
  assert_true(response.body.contains("\"robot_name\": \"host_import_bot\""))
  assert_true(
    response.body.contains(
      "\"model_primary\": \"model/imports/host-import/robot.urdf\"",
    ),
  )
  let profile = @fsx.read_file_to_string(root + "/robot.json") catch {
    _ => fail("failed to read imported host profile")
  }
  assert_true(
    profile.contains("\"primary\": \"model/imports/host-import/robot.urdf\""),
  )
  let imported = @fsx.read_file_to_string(
    root + "/model/imports/host-import/robot.urdf",
  ) catch {
    _ => fail("failed to read imported host URDF")
  }
  assert_true(imported.contains("filename=\"meshes/base.STL\""))
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
