///|
test "host api emits cockpit snapshot response" {
  let response = @host_api.snapshot_response("examples/noetix-e1")
  assert_eq(response.status, 200)
  assert_eq(response.content_type, "application/json")
  assert_true(response.body.contains("\"robot_id\": \"noetix-e1-lab-01\""))
  assert_true(response.body.contains("\"product_status\""))
  assert_true(response.body.contains("\"service\": \"moonrobo\""))
  assert_true(response.body.contains("\"total_count\": 6"))
  assert_true(response.body.contains("\"model_joints\": 24"))
  if response.body.contains(
      "\"source_path\": \"e1_asm_251028/urdf/e1_asm.urdf\"",
    ) {
    assert_true(response.body.contains("\"visual_geometries\": 25"))
    assert_true(response.body.contains("\"resolved_meshes\": 25"))
    assert_true(response.body.contains("\"model_mapped_joints\": 0"))
    assert_true(response.body.contains("\"limit_state\": \"missing-model\""))
  } else {
    assert_true(response.body.contains("\"model_mapped_joints\": 24"))
    assert_true(response.body.contains("\"limit_state\": \"ok\""))
  }
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
    response.body.contains("\"provider_id\": \"moonrobo-context-for-moonclaw\""),
  )
  let registry = @runtime.read_tool_registry(root).unwrap()
  assert_eq(registry.provider_count, 3)
  assert_eq(registry.capability_count, 35)
  assert_true(response.body.contains("\"route\": \"/api/moonbook/remember\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonbook/conversation\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/session\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/ask\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/live-exercises\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/loop\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/turn\""))
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/loops\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/loops/{loop_id}\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/turns\""))
  assert_true(
    response.body.contains("\"route\": \"/api/moonrobo/turns/{turn_id}\""),
  )
  assert_true(response.body.contains("\"route\": \"/api/moonrobo/handoff\""))
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
  assert_false(response.body.contains("/api/policies/evaluate"))
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
  assert_true(session.latest_loop is None)
  assert_true(session.mapping.mapped)
  assert_eq(session.memory.robot_id, "noetix-e1-lab-01")
  assert_eq(session.handoff.next_owner, "moonclaw")
  assert_eq(session.handoff.next_route, @host_api.moonclaw_context_path())
  assert_eq(session.handoff.target_route, @host_api.moonclaw_context_path())
  assert_true(!session.handoff.accepts_task_messages)
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
  assert_true(session.latest_loop is None)
  assert_eq(session.handoff.next_owner, "moonclaw")
  assert_eq(session.handoff.next_route, @host_api.moonclaw_context_path())
  assert_eq(session.handoff.target_route, @host_api.moonclaw_context_path())
  assert_true(!session.handoff.accepts_task_messages)
  assert_true(
    session.latest_turn
    is Some({ turn_id: "robo-turn-message-session-turn-4110", .. }),
  )
  assert_eq(session.session.thread_id, "moonbook-task-messages")
  assert_eq(session.session.mapping_id, session.mapping.mapping_id)
  let context_response = @host_api.route(
    root,
    "GET",
    @host_api.moonclaw_context_path(),
  )
  assert_eq(context_response.status, 200)
  let context : @host_api.MoonClawContextResponse = @json.from_json(
    @json.parse(context_response.body),
  )
  assert_true(context.context.task_intent.has_task)
  assert_eq(context.context.task_intent.task_id, "message-session-turn")
  assert_eq(context.context.task_intent.goal, "walk forward")
  assert_eq(context.context.task_intent.message_id, "session-turn")
}

///|
test "host api handoff exposes queued work to MoonClaw" {
  let root = "/tmp/moonrobo-host-api-decision-operator-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.robo_handoff_path())
  assert_eq(response.status, 200)
  let decision : @host_api.RoboHandoffResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(decision.status, "moonclaw-context-ready")
  assert_true(!decision.can_act)
  assert_true(!decision.needs_operator)
  assert_true(decision.needs_moonclaw)
  assert_eq(decision.next_owner, "moonclaw")
  assert_eq(decision.next_route, @host_api.moonclaw_context_path())
  assert_eq(decision.target_route, @host_api.moonclaw_context_path())
  assert_eq(decision.next_kind, "moonclaw-routine")
  assert_true(decision.queue_count > 0)
  assert_eq(decision.loop_status, "incomplete")
}

///|
test "host api handoff exposes safe evidence work to MoonClaw" {
  let root = "/tmp/moonrobo-host-api-decision-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route(root, "GET", @host_api.robo_handoff_path())
  assert_eq(response.status, 200)
  let decision : @host_api.RoboHandoffResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(decision.status, "moonclaw-context-ready")
  assert_true(!decision.can_act)
  assert_true(!decision.needs_operator)
  assert_true(decision.needs_moonclaw)
  assert_eq(decision.next_owner, "moonclaw")
  assert_eq(decision.next_route, @host_api.moonclaw_context_path())
  assert_eq(decision.target_route, @host_api.moonclaw_context_path())
  assert_eq(decision.next_kind, "moonclaw-routine")
  assert_true(!decision.physical_execution_allowed)
}

///|
test "host api ask persists MoonBook task message and returns handoff" {
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
  assert_eq(ask.live_readiness.loop_proof.percent, ask.handoff.loop_percent)
  assert_eq(ask.handoff.status, "moonclaw-context-ready")
  assert_eq(ask.handoff.next_route, @host_api.moonclaw_context_path())
  assert_eq(ask.handoff.target_route, @host_api.moonclaw_context_path())
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
test "host api turn leaves MoonClaw-ready work for MoonClaw" {
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
  assert_true(turn.moonclaw_handoff)
  assert_eq(turn.turn_id, "robo-turn-message-turn-runtime-validation-4100")
  assert_eq(
    turn.turn_path,
    root +
    "/.moonsuite/products/moonrobo/robo-turns/robo-turn-message-turn-runtime-validation-4100.json",
  )
  assert_eq(turn.ask.handoff.status, "moonclaw-context-ready")
  assert_eq(turn.ask.handoff.next_route, @host_api.moonclaw_context_path())
  assert_eq(turn.ask.handoff.target_route, @host_api.moonclaw_context_path())
  assert_true(
    @fsx.path_exists(
      root + "/moonbook/task-messages/message-turn-runtime-validation.json",
    ),
  )
  assert_true(@fsx.path_exists(turn.turn_path))
  assert_true(
    !@fsx.path_exists(root + "/runs/robo-turns/" + turn.turn_id + ".json"),
  )
  let turn_text = @fsx.read_file_to_string(turn.turn_path) catch {
    _ => fail("failed to read persisted Robo turn")
  }
  assert_true(turn_text.contains("\"moonclaw_handoff\": true"))
  assert_true(!turn_text.contains("\"agent_ran\""))
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
  assert_eq(loop_run.status, "moonclaw-ready")
  assert_true(loop_run.turn is None)
  assert_eq(
    loop_run.loop_path,
    root + "/.moonsuite/products/moonrobo/robo-loops/current-loop.json",
  )
  assert_true(@fsx.path_exists(loop_run.loop_path))
  assert_true(!@fsx.path_exists(root + "/runs/robo-loops/current-loop.json"))
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
      now_ms: 4115L,
      remember: true,
    }),
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
  assert_true(loop_run.turn is Some({ moonclaw_handoff: true, .. }))
  assert_eq(loop_run.status, "moonclaw-ready")
  assert_true(loop_run.session.turn_count >= 1)
  assert_eq(
    loop_run.loop_path,
    root + "/.moonsuite/products/moonrobo/robo-loops/agent-loop.json",
  )
  assert_true(@fsx.path_exists(loop_run.loop_path))
  assert_true(!@fsx.path_exists(root + "/runs/robo-loops/agent-loop.json"))
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
    route == loop_run.handoff.next_route,
  )
}

///|
test "host api no longer exposes local Robo step runner" {
  let root = "/tmp/moonrobo-host-api-step-operator-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root, "POST", "/api/moonrobo/step", "{}",
  )
  assert_eq(response.status, 404)
  let steps = @host_api.route(root, "GET", "/api/moonrobo/steps")
  assert_eq(steps.status, 404)
}

///|
test "host api session records MoonClaw handoff without local Robo step" {
  let root = "/tmp/moonrobo-host-api-step-agent-test"
  prepare_submission_root(root)
  write_pending_runtime_revalidation(root)
  let session_response = @host_api.route(
    root,
    "GET",
    @host_api.robo_session_path(),
  )
  assert_eq(session_response.status, 200)
  let session : @host_api.RoboSessionResponse = @json.from_json(
    @json.parse(session_response.body),
  )
  assert_eq(session.handoff.next_owner, "moonclaw")
  assert_eq(session.handoff.next_route, @host_api.moonclaw_context_path())
  assert_eq(session.handoff.target_route, @host_api.moonclaw_context_path())
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
test "host api prove-loop audits evidence without running routine policy" {
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
  assert_true(!proof.ready)
  assert_true(proof.after.completed_count > proof.before.completed_count)
  assert_eq(proof.after.next_route, @host_api.moonrobo_gateway_command_path())
  assert_true(@fsx.path_exists(proof.proof_path))
  assert_true(@fsx.path_exists(proof.memory_path))
  assert_true(proof.bootstrap is Some(_))
  assert_true(proof.message.contains(@host_api.moonrobo_gateway_command_path()))
  let record_text = @fsx.read_file_to_string(proof.proof_path) catch {
    _ => fail("failed to read prove-loop record")
  }
  assert_true(
    record_text.contains("\"proof_id\": \"prove-loop-prove-loop-partial-3300\""),
  )
  assert_true(record_text.contains("\"completed_after\": 3"))
  let memory_text = @fsx.read_file_to_string(proof.memory_path) catch {
    _ => fail("failed to read prove-loop memory")
  }
  assert_true(memory_text.contains("\"kind\": \"closed-loop-proof\""))
  assert_true(memory_text.contains(proof.proof_path))
  assert_true(
    !@fsx.path_exists(root + "/runs/gateway-commands/prove-loop-partial.json"),
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
  assert_eq(session.next_route, @host_api.moonrobo_gateway_command_path())
  assert_eq(
    session.session_path,
    root +
    "/.moonsuite/products/moonrobo/proof-sessions/proof-session-blocked.json",
  )
  assert_true(@fsx.path_exists(session.session_path))
  assert_true(
    !@fsx.path_exists(root + "/runs/proof-sessions/proof-session-blocked.json"),
  )
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
  assert_eq(session.next_route, @host_api.moonrobo_gateway_command_path())
  assert_eq(
    session.session_path,
    root +
    "/.moonsuite/products/moonrobo/proof-sessions/proof-session-complete.json",
  )
  assert_eq(session.attempts.length(), 2)
  assert_true(!session.attempts[0].ready)
  assert_true(@fsx.path_exists(session.session_path))
  assert_true(
    !@fsx.path_exists(root + "/runs/proof-sessions/proof-session-complete.json"),
  )
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
test "host api explicit task-message gates stop at runtime required" {
  let root = "/tmp/moonrobo-host-api-explicit-gate-test"
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
    @host_api.moonbook_task_message_evaluate_path(
      "message-bootstrap-first-task",
    ),
    "",
  )
  assert_eq(evaluate.status, 200)
  let evaluated_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-bootstrap-first-task"),
  )
  assert_eq(evaluated_status.status, 200)
  assert_true(evaluated_status.body.contains("\"stage\": \"needs-dry-run\""))
  let dry_run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_dry_run_path("message-bootstrap-first-task"),
    "",
  )
  assert_eq(dry_run.status, 200)
  let dry_run_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-bootstrap-first-task"),
  )
  assert_eq(dry_run_status.status, 200)
  assert_true(dry_run_status.body.contains("\"stage\": \"needs-approval\""))
  let approval = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_approve_path("message-bootstrap-first-task"),
    "",
  )
  assert_eq(approval.status, 200)
  let approved_status = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_task_message_status_path("message-bootstrap-first-task"),
  )
  assert_eq(approved_status.status, 200)
  assert_true(approved_status.body.contains("\"stage\": \"ready-to-dispatch\""))
  let execute = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonbook_task_message_execute_path("message-bootstrap-first-task"),
    "",
  )
  assert_eq(execute.status, 409)
  assert_true(execute.body.contains("\"code\": \"runtime-required\""))
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
  assert_true(
    !@fsx.path_exists(
      root + "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    ),
  )
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
  assert_true(
    @fsx.path_exists(
      root + "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    ),
  )
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
  assert_true(
    !@fsx.path_exists(
      root + "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    ),
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
    response.body.contains(
      "\"snapshot_path\": \".tmp/products/moonrobo/sdk-e1/snapshot.json\"",
    ),
  )
  assert_true(
    response.body.contains(".tmp/products/moonrobo/sdk-e1/command.json"),
  )
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
    response.body.contains(
      "\"snapshot_path\": \".tmp/products/moonrobo/sdk-e1/snapshot.json\"",
    ),
  )
  assert_true(
    response.body.contains(".tmp/products/moonrobo/sdk-e1/command.json"),
  )
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
    response.body.contains(
      "wait_for_file '.tmp/products/moonrobo/sdk-e1/snapshot.json'",
    ),
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
      "/.moonsuite/products/moonrobo/runtime-supervisor/runtime-supervisor-noetix-e1-lab-01:sdk-e1.sh",
    ),
  )
  assert_true(
    @fsx.path_exists(
      root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/runtime-supervisor-noetix-e1-lab-01:sdk-e1.json",
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
test "host api emits moonclaw context pack" {
  let root = "/tmp/moonrobo-host-api-moonclaw-context-test"
  prepare_submission_root(root)
  let response = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"pack_id\""))
  assert_true(response.body.contains("\"context\""))
  assert_true(response.body.contains("\"next_route\""))
  assert_true(response.body.contains("/api/runtime/validation/session"))
  assert_true(response.body.contains("\"memory\""))
  assert_true(response.body.contains("moonbook-memory-noetix-e1-lab-01-0"))
  assert_true(response.body.contains("\"platform_queue\""))
  assert_true(response.body.contains("\"kind\": \"start-runtime\""))
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
  assert_eq(
    decoded.context.gateway.next_route,
    "/api/runtime/validation/session",
  )
  assert_true(!decoded.context.task_intent.has_task)
  assert_eq(decoded.context.platform_queue.items[0].kind, "start-runtime")
  assert_eq(
    decoded.context.platform_queue.items[0].target_path,
    "/api/runtime/supervisor/start",
  )
  assert_eq(decoded.live_closure.closure.missing.length(), 1)
  assert_eq(decoded.live_closure.closure.missing[0], "moonclaw-routine-turn")
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
  assert_true(response.body.contains("\"readiness\""))
  assert_true(response.body.contains("\"readiness_plan\""))
  assert_true(
    response.body.contains(
      "\"next_route\": \"/api/runtime/validation/session\"",
    ),
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
  assert_true(context.body.contains("\"gateway\""))
  assert_true(context.body.contains("\"live_readiness\""))
  assert_true(context.body.contains("\"ready-for-proof-session\""))
  assert_true(context.body.contains("\"live_exercises\""))
  assert_true(
    context.body.contains("\"next_route\": \"/api/moonrobo/proof-session\""),
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
  assert_eq(readiness.proof_session_feedback_binding_required_count, 0)
  assert_eq(readiness.proof_session_feedback_binding_success_count, 0)
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
  assert_eq(closure.closure.missing[0], "moonclaw-routine-turn")
  assert_eq(closure.next_route, @host_api.moonclaw_context_path())
}

///|
test "host api emits moonstat status projection" {
  let root = "/tmp/moonrobo-host-api-moonstat-status-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("moonstat-host-run", 2),
  )
  let response = @host_api.route(root, "GET", @host_api.moonstat_status_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"service\": \"moonrobo\""))
  assert_true(response.body.contains("\"status\": \"not-ready\""))
  assert_true(response.body.contains("\"receipt_count\": 2"))
  assert_true(response.body.contains("\"observation_count\": 1"))
  assert_true(response.body.contains("\"process_review_count\": 1"))
}

///|
test "host api projects Moonrobo platform queue from replay evidence" {
  let root = "/tmp/moonrobo-host-api-platform-queue-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("platform-queue-host-run", 2),
  )
  let response = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains(
      "\"queue_id\": \"platform-queue-noetix-e1-lab-01-0\"",
    ),
  )
  assert_true(response.body.contains("\"kind\": \"start-runtime\""))
  assert_true(response.body.contains("\"kind\": \"run-proof-session\""))
  assert_true(
    response.body.contains(
      "\"target_path\": \"/api/replays/task-platform-queue-host-run-observe/annotations\"",
    ),
  )
  assert_false(response.body.contains("/api/policies/evaluate"))
}

///|
test "host api projects runtime calibration plan into Moonrobo platform queue" {
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
  let response = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"kind\": \"calibrate-runtime\""))
  assert_true(
    response.body.contains(
      "\"target_path\": \"/api/moonclaw/runtime-calibration/latest\"",
    ),
  )
  assert_true(response.body.contains("\"priority\": 95"))
  let calibration = @host_api.route(
    root,
    "GET",
    @host_api.moonclaw_runtime_calibration_path(),
  )
  assert_eq(calibration.status, 200)
  assert_true(
    calibration.body.contains("\"plan_id\": \"runtime-calibration-host\""),
  )
  assert_true(calibration.body.contains("\"blocker_code\": \"runtime-active\""))
  let resolved = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonclaw_runtime_calibration_resolve_path(),
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
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(after_resolution.status, 200)
  assert_true(after_resolution.body.contains("\"kind\": \"validate-runtime\""))
  assert_true(
    after_resolution.body.contains(
      "\"target_path\": \"/api/runtime/validation/session\"",
    ),
  )
  assert_true(after_resolution.body.contains("\"priority\": 101"))
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
    @host_api.robot_platform_queue_path(),
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
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"validate-runtime\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/runtime/validation/session\""),
  )
  assert_true(!queue.body.contains("\"kind\": \"start-runtime\""))
}

///|
test "host api exposes proof-session work through queue and context" {
  let root = "/tmp/moonrobo-host-api-proof-session-work-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"run-proof-session\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/moonrobo/proof-session\""),
  )
  let resident = @host_api.route(root, "GET", @host_api.resident_path())
  assert_eq(resident.status, 200)
  assert_true(resident.body.contains("\"proof_session_count\": 0"))
  let memory = @host_api.route(root, "GET", @host_api.moonbook_memory_path())
  assert_eq(memory.status, 200)
  assert_true(memory.body.contains("\"kind\": \"work-pressure\""))
  assert_true(
    memory.body.contains("\"next_route\": \"/api/moonrobo/platform-queue\""),
  )
  let context = @host_api.route(root, "GET", @host_api.moonclaw_context_path())
  assert_eq(context.status, 200)
  assert_true(context.body.contains("\"live_readiness\""))
  assert_true(context.body.contains("\"proof_sessions\""))
  assert_true(context.body.contains("\"live_exercises\""))
  assert_true(context.body.contains("\"session_count\": 0"))
}

///|
test "host api exposes gateway command work for MoonClaw-owned policy" {
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
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(!queue.body.contains("\"kind\": \"run-live-exercise\""))
  assert_true(
    !queue.body.contains("\"target_path\": \"/api/moonrobo/live-exercise\""),
  )
  assert_true(queue.body.contains("\"kind\": \"submit-gateway-command\""))
  assert_true(
    queue.body.contains("\"target_path\": \"/api/moonrobo/gateway/command\""),
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
    @host_api.moontown_observe_run_path(),
    observe_run_json("moonbook-memory-host-run", 2),
  )
  let projected = @host_api.route(root, "GET", @host_api.moonbook_memory_path())
  assert_eq(projected.status, 200)
  assert_true(projected.body.contains("\"persisted\": false"))
  assert_true(projected.body.contains("\"kind\": \"resident-state\""))
  assert_true(projected.body.contains("\"kind\": \"latest-observation\""))
  assert_true(projected.body.contains("\"kind\": \"work-pressure\""))
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
  assert_true(text.contains("\"next_route\": \"/api/moonrobo/platform-queue\""))
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
  write_healthy_runtime(root, 3000L)
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
      "\"dispatch_path\": \"\{root}/.moonsuite/products/moonrobo/bridge-dispatches/dispatch-request-execute-intent-message-walk-queue-now-3000.json\"",
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
    runtime_health_path=root +
      "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/moonrobo.log",
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
      "routine execution remains outside Moonrobo",
    ),
  )
  assert_eq(
    command_decoded.command.next_route,
    command_decoded.ask.unwrap().handoff.next_route,
  )
  assert_eq(
    command_decoded.command.command_path,
    command_root +
    "/.moonsuite/products/moonrobo/gateway-commands/gateway-command-now.json",
  )
  assert_true(@fsx.path_exists(command_decoded.command.command_path))
  assert_true(@fsx.path_exists(command_decoded.command.message_path))
  assert_true(
    !@fsx.path_exists(
      command_root + "/runs/gateway-commands/gateway-command-now.json",
    ),
  )
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
  assert_eq(prove_decoded.after.completed_count, 4)
  assert_eq(prove_decoded.after.percent, 66)
  assert_true(prove_decoded.bootstrap_applied)
  assert_eq(prove_decoded.next_route, @host_api.moonrobo_gateway_command_path())
  assert_true(@fsx.path_exists(prove_decoded.proof_path))
  assert_true(@fsx.path_exists(prove_decoded.memory_path))
  let record_text = @fsx.read_file_to_string(prove_decoded.proof_path) catch {
    _ => fail("failed to read prove-loop record")
  }
  assert_true(!record_text.contains("\"command_path\""))
  assert_true(!record_text.contains("\"message_path\""))
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
    root + "/.moonsuite/products/moonrobo/bridge-dispatches/dispatch-proof.json",
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
    root + "/.moonsuite/products/moonrobo/bridge-dispatches/dispatch-proof.json",
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    3002L,
    runtime_health_path=root +
      "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/moonrobo.log",
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
    runtime_health_path=root +
      "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/moonrobo.log",
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
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"bind-execution-feedback\""))
  assert_true(
    queue.body.contains(
      "\"target_path\": \"/api/moonrobo/executions/feedback\"",
    ),
  )
  let request : @host_api.TaskExecutionFeedbackRequest = {
    snapshot_id: "task-execution-feedback-bind",
    telemetry: feedback,
    session_id: "explicit-feedback-bind-test",
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.task_execution_feedback_path(),
    request.to_json().stringify(),
  )
  assert_eq(response.status, 200)
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
test "host api prove-loop leaves execution feedback operator-owned" {
  let root = "/tmp/moonrobo-host-api-prove-loop-feedback-binding-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-feedback-binding",
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
    detail: "feedback binding proof intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-feedback-binding-ready", "sdk-e1", intent, verdict, 4100L,
  )
  let receipt = @core.executed_receipt(
    "receipt-feedback-binding-executed", ready, 4101L,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-request-feedback-binding",
    "request-feedback-binding",
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
    "task-execution-feedback-binding",
    "message-feedback-binding",
    root + "/moonbook/task-messages/message-feedback-binding.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    4101L,
    runtime_health_path=root +
      "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/moonrobo.log",
  )
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
  let feedback = {
    ..@core.empty_telemetry_frame(
      "frame-feedback-binding", "noetix-e1-lab-01", "sdk-e1", 4102L,
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
    root, "runtime-feedback-binding", feedback,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        4102L, "healthy", true, true, 42, "launch-feedback-binding", "runtime-feedback-binding",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        feedback_path, "frame-feedback-binding", 4102L,
      ),
    ).unwrap(),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_prove_loop_path(),
    @host_api.PlatformProveLoopRequest::{
      task_message: @task.task_message_request(
        "prove-loop-feedback-binding",
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
  assert_true(response.body.contains("\"feedback_binding_required\": true"))
  assert_true(response.body.contains("\"feedback_binding_status\": 0"))
  assert_true(response.body.contains("operator-verification"))
  let proof : @host_api.PlatformProveLoopResponse = @json.from_json(
    @json.parse(response.body),
  )
  assert_true(!proof.ready)
  assert_true(!proof.after.ready)
  assert_eq(proof.after.next_route, @host_api.moonrobo_gateway_command_path())
  let unbound = @runtime.read_task_execution_snapshot(
    root, "task-execution-feedback-binding",
  ).unwrap()
  assert_eq(unbound.telemetry_frame_id, "")
  assert_eq(unbound.physical_feedback_status, "missing")
  assert_eq(unbound.command_outcome_status, "unconfirmed")
}

///|
test "host api proof-session keeps feedback binding explicit" {
  let root = "/tmp/moonrobo-host-api-proof-session-feedback-binding-test"
  prepare_submission_root(root)
  complete_required_paths(root)
  clear_json_files(root + "/runs/task-executions")
  let intent = @core.command_intent(
    "intent-proof-session-feedback-binding",
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
    detail: "proof session feedback binding intent allowed",
  }
  let ready = @core.receipt_from_verdict(
    "receipt-proof-session-feedback-binding-ready", "sdk-e1", intent, verdict, 4200L,
  )
  let receipt = @core.executed_receipt(
    "receipt-proof-session-feedback-binding-executed", ready, 4201L,
  )
  let dispatch = @core.bridge_dispatch_evidence(
    "dispatch-request-proof-session-feedback-binding",
    "request-proof-session-feedback-binding",
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
    "task-execution-proof-session-feedback-binding",
    "message-proof-session-feedback-binding",
    root + "/moonbook/task-messages/message-proof-session-feedback-binding.json",
    @runtime.receipt_path(root, receipt.receipt_id),
    @runtime.bridge_dispatch_evidence_path(root, dispatch.dispatch_id),
    root + "/moonbook/memory/memory.json",
    receipt,
    dispatch,
    4201L,
    runtime_health_path=root +
      "/.moonsuite/products/moonrobo/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    runtime_log_path=root +
      "/.moonsuite/products/moonrobo/runtime-supervisor/moonrobo.log",
  )
  ignore(@runtime.write_task_execution_snapshot(root, snapshot).unwrap())
  let feedback = {
    ..@core.empty_telemetry_frame(
      "frame-proof-session-feedback-binding", "noetix-e1-lab-01", "sdk-e1", 4202L,
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
    root, "runtime-proof-session-feedback-binding", feedback,
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        4202L, "healthy", true, true, 42, "launch-proof-session-feedback-binding",
        "runtime-proof-session-feedback-binding", "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391",
        true, "ok", "telemetry healthy", feedback_path, "frame-proof-session-feedback-binding",
        4202L,
      ),
    ).unwrap(),
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.platform_proof_session_path(),
    @host_api.PlatformProofSessionRequest::{
      session_id: "proof-session-feedback-binding",
      task_message: @task.task_message_request(
        "proof-session-feedback-binding",
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
  assert_eq(session.feedback_binding_required_count, 2)
  assert_eq(session.feedback_binding_success_count, 0)
  assert_eq(session.latest_feedback_binding_status, 0)
  assert_true(
    session.latest_feedback_binding_message.contains("operator-verification"),
  )
  assert_true(response.body.contains("\"feedback_binding_success_count\": 0"))
  let readiness_response = @host_api.route(
    root,
    "GET",
    @host_api.moonrobo_live_readiness_path(),
  )
  assert_eq(readiness_response.status, 200)
  let readiness : @host_api.MoonroboLiveReadinessResponse = @json.from_json(
    @json.parse(readiness_response.body),
  )
  assert_true(!readiness.proof_session_feedback_closed)
  assert_eq(readiness.proof_session_feedback_binding_success_count, 0)
  assert_eq(readiness.proof_session_latest_feedback_status, 0)
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
      item.evidence_path.contains(
        "task-execution-proof-session-feedback-binding",
      )
    }),
  )
  let resident_response = @host_api.route(
    root,
    "GET",
    @host_api.resident_path(),
  )
  assert_eq(resident_response.status, 200)
  assert_true(resident_response.body.contains("\"feedback_closed\": false"))
  assert_true(resident_response.body.contains("\"latest_feedback_status\": 0"))
  let memory_response = @host_api.route(
    root,
    "GET",
    @host_api.moonbook_memory_path(),
  )
  assert_eq(memory_response.status, 200)
  assert_true(
    memory_response.body.contains("\"kind\": \"latest-proof-session\""),
  )
  assert_true(memory_response.body.contains("feedback 0/2"))
  assert_true(memory_response.body.contains("feedback_closed false"))
  let unbound = @runtime.read_task_execution_snapshot(
    root, "task-execution-proof-session-feedback-binding",
  ).unwrap()
  assert_eq(unbound.physical_feedback_status, "missing")
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
  assert_eq(durable.next_route, @host_api.moonrobo_gateway_command_path())
  assert_true(
    !durable.checks.any(item => {
      item.code == "physical-feedback-verified" &&
      item.ready &&
      item.evidence_path == session.session_path
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
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"\{kind}\""))
  assert_true(queue.body.contains("\"target_path\": \"\{target_path}\""))
}

///|
test "host platform queue starts reviewed command messages at evaluation" {
  let root = "/tmp/moonrobo-host-api-task-message-queue-evaluate-test"
  prepare_submission_root(root)
  submit_command_message(root, "queue-evaluate")
  assert_queue_step(
    root, "evaluate-command-message", "/api/moonbook/task-messages/message-queue-evaluate/evaluate",
  )
}

///|
test "host platform queue advances reviewed command messages to dry run" {
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
test "host platform queue advances reviewed command messages to approval" {
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
test "host platform queue advances reviewed command messages to execution" {
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
  write_healthy_runtime(root, 3100L)
  ignore(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_execute_path("message-queue-execute"),
      "",
    ),
  )
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
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
  assert_true(response.body.contains("\"needs_human_count\": 1"))
  assert_true(
    response.body.contains("\"review_id\": \"review-moonclaw-host-test\""),
  )
  assert_true(response.body.contains("/tmp/moonclaw-host-artifact.json"))
  assert_true(response.body.contains("\"tool_registry\""))
}

///|
test "host api does not expose embedded robot policy runner" {
  let root = "/tmp/moonrobo-host-api-embedded-policy-test"
  prepare_submission_root(root)
  let response = @host_api.route_with_body(
    root, "POST", "/api/agent/routine/next", "{}",
  )
  assert_eq(response.status, 404)
  assert_true(response.body.contains("No Moonrobo host API route"))
}

///|
test "host api runtime validation remains direct Moonrobo gateway work" {
  let root = "/tmp/moonrobo-host-api-moonclaw-run-revalidation-test"
  prepare_submission_root(root)
  write_healthy_runtime(root, 8250L)
  write_pending_runtime_revalidation(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.runtime_validation_session_path(),
    @runtime.default_runtime_validation_session_request().to_json().stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(
    @fsx.path_exists(@runtime.latest_runtime_validation_session_path(root)),
  )
}

///|
test "host api exports dataset episode from replay evidence" {
  let root = "/tmp/moonrobo-host-api-dataset-episode-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("dataset-host-run", 3),
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
  assert_true(quality.body.contains("\"warning_count\": 1"))
  assert_true(quality.body.contains("\"frame_count\": 3"))
}

///|
test "host api records replay annotations" {
  let root = "/tmp/moonrobo-host-api-replay-annotation-test"
  prepare_submission_root(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json("annotation-host-run", 2),
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
test "host api exposes replay annotation work after review resolution" {
  let root = "/tmp/moonrobo-host-api-agent-dispatch-test"
  prepare_submission_root(root)
  let task_id = fresh_dispatch_task_id(root)
  let _run = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_observe_run_path(),
    observe_run_json(task_id, 2),
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
  let queue = @host_api.route(
    root,
    "GET",
    @host_api.robot_platform_queue_path(),
  )
  assert_eq(queue.status, 200)
  assert_true(queue.body.contains("\"kind\": \"annotate-replay\""))
  assert_true(
    queue.body.contains(
      "\"target_path\": \"/api/replays/\{session_id}/annotations\"",
    ),
  )
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
  assert_true(blocked.body.contains("\"needs_human_count\": 1"))
  assert_true(
    blocked.body.contains("\"review_id\": \"review-moonclaw-resolution\""),
  )
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
  assert_true(reopened.body.contains("\"needs_human_count\": 0"))
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
fn is_test_dir(path : String) -> Bool {
  @fsx.is_dir(path) catch {
    _ => false
  }
}

///|
fn clear_json_files_deep(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path) catch {
      _ => fail("failed to read test directory: \{path}")
    }
    for name in names {
      let child = path + "/\{name}"
      if is_test_dir(child) {
        clear_json_files_deep(child)
      } else if name.has_suffix(".json") {
        @fsx.remove_file(child) catch {
          _ => fail("failed to remove stale test file: \{child}")
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
  ensure_dir(root + "/runs/task-executions")
  ensure_dir(root + "/.moonsuite/products/moonrobo/runtime-health")
  ensure_dir(root + "/.moonsuite/products/moonrobo/runtime-validation")
  ensure_dir(root + "/.moonsuite/products/moonrobo/runtime-validation/sessions")
  ensure_dir(root + "/.moonsuite/products/moonrobo/runtime-calibration")
  ensure_dir(
    root + "/.moonsuite/products/moonrobo/runtime-calibration/resolutions",
  )
  ensure_dir(root + "/runs/prove-loop")
  ensure_dir(root + "/runs/proof-sessions")
  ensure_dir(root + "/runs/gateway-commands")
  ensure_dir(root + "/runs/model-edits")
  ensure_dir(root + "/runs/model-edits/sources")
  ensure_dir(root + "/runs/robo-loops")
  ensure_dir(root + "/runs/observations")
  ensure_dir(root + "/runs/telemetry")
  ensure_dir(root + "/runs/reviews")
  ensure_dir(root + "/.moonsuite")
  ensure_dir(root + "/.moonsuite/products")
  ensure_dir(root + "/.moonsuite/products/moonrobo")
  ensure_dir(root + "/.moonsuite/products/moonrobo/gateway-commands")
  ensure_dir(root + "/.moonsuite/products/moonrobo/robo-loops")
  ensure_dir(root + "/.moonsuite/products/moonrobo/robo-turns")
  ensure_dir(root + "/.moonsuite/products/moonrobo/bridge-dispatches")
  ensure_dir(root + "/.moonsuite/products/moonrobo/bridge-contracts")
  ensure_dir(root + "/moonbook")
  ensure_dir(root + "/moonbook/memory")
  ensure_dir(root + "/moonbook/task-messages")
  ensure_dir(root + "/agents")
  ensure_dir(root + "/model")
  clear_json_files(root + "/runs/receipts")
  clear_json_files(root + "/runs/dry-runs")
  clear_json_files(root + "/runs/approvals")
  clear_json_files(root + "/runs/task-executions")
  clear_json_files(root + "/.moonsuite/products/moonrobo/runtime-health")
  clear_json_files(root + "/.moonsuite/products/moonrobo/runtime-validation")
  clear_json_files(
    root + "/.moonsuite/products/moonrobo/runtime-validation/sessions",
  )
  clear_json_files(root + "/.moonsuite/products/moonrobo/runtime-calibration")
  clear_json_files(
    root + "/.moonsuite/products/moonrobo/runtime-calibration/resolutions",
  )
  clear_json_files(root + "/runs/prove-loop")
  clear_json_files(root + "/runs/proof-sessions")
  clear_json_files(root + "/runs/gateway-commands")
  clear_json_files(root + "/runs/model-edits")
  clear_json_files(root + "/runs/robo-turns")
  clear_json_files(root + "/runs/robo-loops")
  clear_json_files(root + "/runs/observations")
  clear_json_files_deep(root + "/runs/telemetry")
  clear_json_files(root + "/runs/reviews")
  clear_json_files(root + "/.moonsuite/products/moonrobo/gateway-commands")
  clear_json_files(root + "/.moonsuite/products/moonrobo/robo-loops")
  clear_json_files(root + "/.moonsuite/products/moonrobo/robo-turns")
  clear_json_files(root + "/.moonsuite/products/moonrobo/bridge-dispatches")
  clear_json_files(root + "/.moonsuite/products/moonrobo/bridge-contracts")
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
fn write_editor_test_urdf(root : String) -> Unit raise {
  let source =
    #|<robot name="editor_route_bot">
    #|  <material name="route_paint">
    #|    <color rgba="0.2 0.4 0.6 1"/>
    #|  </material>
    #|  <link name="base_link">
    #|    <inertial>
    #|      <origin xyz="0 0 0.1" rpy="0 0 0"/>
    #|      <mass value="5"/>
    #|      <inertia ixx="1" ixy="0" ixz="0" iyy="1.5" iyz="0" izz="2"/>
    #|    </inertial>
    #|    <visual>
    #|      <origin xyz="0 0 0" rpy="0 0 0"/>
    #|      <geometry><box size="1 1 1"/></geometry>
    #|      <material name="route_paint"/>
    #|    </visual>
    #|    <collision>
    #|      <origin xyz="0 0 0.5" rpy="0 0 0"/>
    #|      <geometry><sphere radius="0.5"/></geometry>
    #|    </collision>
    #|  </link>
    #|  <link name="driver_link"/>
    #|  <link name="tool_link"/>
    #|  <joint name="driver_joint" type="revolute">
    #|    <parent link="base_link"/>
    #|    <child link="driver_link"/>
    #|  </joint>
    #|  <joint name="tool_joint" type="revolute">
    #|    <parent link="driver_link"/>
    #|    <child link="tool_link"/>
    #|    <origin xyz="0 0 1" rpy="0 0 0"/>
    #|    <axis xyz="0 0 1"/>
    #|    <limit lower="-1" upper="1" effort="10" velocity="2"/>
    #|    <dynamics damping="0.1" friction="0.2"/>
    #|  </joint>
    #|</robot>
  @fsx.write_string_to_file(root + "/model/robot.urdf", source) catch {
    _ => fail("failed to write editor test URDF")
  }
}

///|
test "host API exposes active URDF editor document" {
  let root = "/tmp/moonrobo-host-urdf-editor-document"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route(
    root,
    "GET",
    @host_api.robobook_urdf_document_path(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"robot_name\": \"editor_route_bot\""))
  assert_true(response.body.contains("\"node_id\": \"joint:tool_joint\""))
  assert_true(response.body.contains("\"node_id\": \"visual:base_link:0\""))
  assert_true(response.body.contains("\"node_id\": \"collision:base_link:0\""))
  assert_true(response.body.contains("\"node_id\": \"inertial:base_link\""))
  assert_true(
    response.body.contains("\"node_id\": \"material:robot:route_paint\""),
  )
  assert_true(
    response.body.contains("\"node_id\": \"material:base_link:visual:0\""),
  )
  assert_true(response.body.contains("\"components\""))
  assert_true(response.body.contains("\"inertials\""))
  assert_true(response.body.contains("\"materials\""))
  assert_true(response.body.contains("\"dynamics\""))
  assert_true(response.body.contains("\"kind\": \"joint\""))
  assert_true(response.body.contains("\"kind\": \"inertial\""))
  assert_true(response.body.contains("\"kind\": \"material\""))
  assert_true(response.body.contains("\"command_count\": 2"))
}

///|
test "host API previews URDF editor edits without writing source" {
  let root = "/tmp/moonrobo-host-urdf-editor-preview"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let before = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model before preview")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-limit",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: Some({
        lower: Some(-2.0),
        upper: Some(2.0),
        effort: Some(20.0),
        velocity: Some(4.0),
      }),
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: false,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": false"))
  assert_true(
    response.body.contains(
      "<limit lower=\\\"-2\\\" upper=\\\"2\\\" effort=\\\"20\\\" velocity=\\\"4\\\"/>",
    ),
  )
  let after = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after preview")
  }
  assert_eq(after, before)
}

///|
test "host API lists saved URDF editor history" {
  let root = "/tmp/moonrobo-host-urdf-editor-history"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let empty = @host_api.route(
    root,
    "GET",
    @host_api.robobook_urdf_history_path(),
  )
  assert_eq(empty.status, 200)
  assert_true(empty.body.contains("\"receipt_count\": 0"))
  let save = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-visual-origin",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: Some(0),
      collision_index: None,
      origin: Some({ xyz: "1 2 3", rpy: "0.1 0.2 0.3" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(save.status, 200)
  let history = @host_api.route(
    root,
    "GET",
    @host_api.robobook_urdf_history_path(),
  )
  assert_eq(history.status, 200)
  assert_true(history.body.contains("\"receipt_count\": 1"))
  assert_true(history.body.contains("\"command\": \"update-visual-origin\""))
  assert_true(history.body.contains("\"target\": \"base_link:0\""))
  assert_true(history.body.contains("\"before_source_path\""))
  assert_true(history.body.contains("\"after_source_path\""))
}

///|
test "host API restores a saved URDF editor receipt snapshot" {
  let root = "/tmp/moonrobo-host-urdf-editor-restore"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let before = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model before restore test")
  }
  let save = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-visual-origin",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: Some(0),
      collision_index: None,
      origin: Some({ xyz: "1 2 3", rpy: "0.1 0.2 0.3" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(save.status, 200)
  let saved : @runtime.UrdfEditorApplyResult = @json.from_json(
    @json.parse(save.body),
  )
  let receipt = match saved.receipt {
    Some(value) => value
    None => fail("expected saved URDF edit receipt")
  }
  let changed = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after save")
  }
  assert_true(changed.contains("<origin xyz=\"1 2 3\" rpy=\"0.1 0.2 0.3\"/>"))
  let restored = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_restore_path(),
    @runtime.UrdfEditorRestoreRequest::{
      edit_id: receipt.edit_id,
      source_side: "before",
    }
    .to_json()
    .stringify(),
  )
  assert_eq(restored.status, 200)
  assert_true(restored.body.contains("\"reverted\": true"))
  assert_true(restored.body.contains("restored before snapshot"))
  assert_true(@fsx.path_exists(root + "/runs/model-edits/latest-restore.json"))
  let after_restore = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after receipt restore")
  }
  assert_eq(after_restore, before)
  let history = @host_api.route(
    root,
    "GET",
    @host_api.robobook_urdf_history_path(),
  )
  assert_eq(history.status, 200)
  assert_true(history.body.contains("\"receipt_count\": 2"))
  assert_true(history.body.contains("\"command\": \"restore-receipt-before\""))
  assert_false(history.body.contains("latest-restore.json"))
}

///|
test "host API compares saved URDF editor receipt snapshots" {
  let root = "/tmp/moonrobo-host-urdf-editor-compare"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let save = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-limit",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: Some({
        lower: Some(-2.0),
        upper: Some(2.0),
        effort: Some(20.0),
        velocity: Some(4.0),
      }),
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(save.status, 200)
  let saved : @runtime.UrdfEditorApplyResult = @json.from_json(
    @json.parse(save.body),
  )
  let receipt = match saved.receipt {
    Some(value) => value
    None => fail("expected saved URDF edit receipt")
  }
  let compare = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_compare_path(),
    @runtime.UrdfEditorCompareRequest::{
      edit_id: receipt.edit_id,
      compare_mode: None,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(compare.status, 200)
  assert_true(compare.body.contains("\"compare_mode\": \"receipt\""))
  assert_true(compare.body.contains("\"left_label\": \"Receipt Before\""))
  assert_true(compare.body.contains("\"right_label\": \"Receipt After\""))
  assert_true(compare.body.contains("\"left_source\""))
  assert_true(compare.body.contains("\"right_source\""))
  assert_true(compare.body.contains("\"command\": \"update-joint-limit\""))
  assert_true(compare.body.contains("\"before_document\""))
  assert_true(compare.body.contains("\"after_document\""))
  assert_true(compare.body.contains("\"changed\": true"))
  assert_true(compare.body.contains("\"hunks\""))
  assert_true(compare.body.contains("lower=\\\"-1\\\""))
  assert_true(compare.body.contains("lower=\\\"-2\\\""))
  let current_compare = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_compare_path(),
    @runtime.UrdfEditorCompareRequest::{
      edit_id: receipt.edit_id,
      compare_mode: Some("current-before"),
    }
    .to_json()
    .stringify(),
  )
  assert_eq(current_compare.status, 200)
  assert_true(
    current_compare.body.contains("\"compare_mode\": \"current-before\""),
  )
  assert_true(
    current_compare.body.contains("\"left_label\": \"Current Active\""),
  )
  assert_true(
    current_compare.body.contains("\"right_label\": \"Receipt Before\""),
  )
  assert_true(current_compare.body.contains("\"left_source\""))
  assert_true(current_compare.body.contains("\"right_source\""))
  assert_true(current_compare.body.contains("lower=\\\"-2\\\""))
  assert_true(current_compare.body.contains("lower=\\\"-1\\\""))
}

///|
test "host API saves URDF editor edits and writes receipt" {
  let root = "/tmp/moonrobo-host-urdf-editor-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-visual-origin",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: Some(0),
      collision_index: None,
      origin: Some({ xyz: "1 2 3", rpy: "0.1 0.2 0.3" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-visual-origin\""))
  assert_true(response.body.contains("\"before_digest\""))
  assert_true(response.body.contains("\"after_digest\""))
  assert_true(response.body.contains("\"diff_summary\""))
  assert_true(@fsx.path_exists(root + "/runs/model-edits/latest.json"))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved editor model")
  }
  assert_true(saved.contains("<origin xyz=\"1 2 3\" rpy=\"0.1 0.2 0.3\"/>"))
  let receipt = @fsx.read_file_to_string(root + "/runs/model-edits/latest.json") catch {
    _ => fail("failed to read editor receipt")
  }
  assert_true(receipt.contains("\"target\": \"base_link:0\""))
  assert_true(receipt.contains("\"status\": \"ready\""))
  assert_true(receipt.contains("\"before_source_path\""))
  assert_true(receipt.contains("\"after_source_path\""))
  assert_true(receipt.contains("\"changed at byte"))
  assert_true(@fsx.path_exists(root + "/runs/model-edits/sources"))
}

///|
test "host API saves URDF collision origin edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-collision-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-collision-origin",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: Some(0),
      origin: Some({ xyz: "0.4 0.5 0.6", rpy: "0.7 0.8 0.9" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(
    response.body.contains("\"command\": \"update-collision-origin\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved editor model")
  }
  assert_true(
    saved.contains("<origin xyz=\"0.4 0.5 0.6\" rpy=\"0.7 0.8 0.9\"/>"),
  )
  assert_true(saved.contains("<sphere radius=\"0.5\"/>"))
}

///|
test "host API saves URDF joint axis edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-axis-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-axis",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: Some({ xyz: "1 0 0" }),
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-joint-axis\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved axis editor model")
  }
  assert_true(saved.contains("<axis xyz=\"1 0 0\"/>"))
  assert_true(saved.contains("<joint name=\"tool_joint\" type=\"revolute\">"))
}

///|
test "host API saves URDF editor joint dynamics edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-dynamics-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-dynamics",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: Some({ damping: Some(0.7), friction: Some(0.8) }),
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-joint-dynamics\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved dynamics editor model")
  }
  assert_true(saved.contains("<dynamics damping=\"0.7\" friction=\"0.8\"/>"))
  assert_true(saved.contains("<axis xyz=\"0 0 1\"/>"))
}

///|
test "host API saves URDF editor joint mimic edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-mimic-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-mimic",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: Some({
        target_joint: "driver_joint",
        multiplier: Some(-1.0),
        offset: Some(0.25),
      }),
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-joint-mimic\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved mimic editor model")
  }
  assert_true(
    saved.contains(
      "<mimic joint=\"driver_joint\" multiplier=\"-1\" offset=\"0.25\"/>",
    ),
  )
  assert_true(saved.contains("<joint name=\"driver_joint\" type=\"revolute\">"))
}

///|
test "host API saves URDF editor joint calibration edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-calibration-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-calibration",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: Some({ rising: Some(0.04), falling: Some(-0.04) }),
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(
    response.body.contains("\"command\": \"update-joint-calibration\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved calibration editor model")
  }
  assert_true(
    saved.contains("<calibration rising=\"0.04\" falling=\"-0.04\"/>"),
  )
  assert_true(saved.contains("<joint name=\"tool_joint\" type=\"revolute\">"))
}

///|
test "host API saves URDF editor joint safety controller edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-safety-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-safety-controller",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: Some({
        soft_lower_limit: Some(-0.6),
        soft_upper_limit: Some(0.6),
        k_position: Some(15.0),
        k_velocity: Some(2.5),
      }),
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(
    response.body.contains("\"command\": \"update-joint-safety-controller\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved safety controller editor model")
  }
  assert_true(
    saved.contains(
      "<safety_controller soft_lower_limit=\"-0.6\" soft_upper_limit=\"0.6\" k_position=\"15\" k_velocity=\"2.5\"/>",
    ),
  )
  assert_true(saved.contains("<joint name=\"tool_joint\" type=\"revolute\">"))
}

///|
test "host API saves URDF inertial edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-inertial-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-inertial",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: Some({
        origin: Some({ xyz: "0.1 0.2 0.3", rpy: "0.4 0.5 0.6" }),
        mass: Some(7.5),
        ixx: Some(1.1),
        ixy: Some(0.1),
        ixz: Some(0.2),
        iyy: Some(1.2),
        iyz: Some(0.3),
        izz: Some(1.3),
      }),
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-inertial\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved inertial editor model")
  }
  assert_true(
    saved.contains("<origin xyz=\"0.1 0.2 0.3\" rpy=\"0.4 0.5 0.6\"/>"),
  )
  assert_true(saved.contains("<mass value=\"7.5\"/>"))
  assert_true(
    saved.contains(
      "<inertia ixx=\"1.1\" ixy=\"0.1\" ixz=\"0.2\" iyy=\"1.2\" iyz=\"0.3\" izz=\"1.3\"/>",
    ),
  )
}

///|
test "host API saves URDF material edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-material-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-material",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: Some("material:robot:route_paint"),
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: Some({
        color_rgba: Some("0.9 0.1 0.2 1"),
        texture_filename: Some("textures/route_paint.png"),
      }),
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-material\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved material editor model")
  }
  assert_true(saved.contains("<color rgba=\"0.9 0.1 0.2 1\"/>"))
  assert_true(
    saved.contains("<texture filename=\"textures/route_paint.png\"/>"),
  )
  assert_true(saved.contains("<material name=\"route_paint\"/>"))
}

///|
test "host API saves URDF extension raw edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-extension-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="extension_route_bot">
      #|  <link name="base_link"/>
      #|  <gazebo reference="base_link">
      #|    <plugin name="sim" filename="libsim.so"/>
      #|  </gazebo>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write extension editor test URDF")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-extension-raw",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some("extension:gazebo:0"),
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: Some({
        raw_source: (
          #|<gazebo reference="base_link">
          #|  <plugin name="physics" filename="libphysics.so"/>
          #|</gazebo>,
        ),
      }),
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-extension-raw\""))
  assert_true(response.body.contains("\"target\": \"extension:gazebo:0\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved extension editor model")
  }
  assert_true(saved.contains("name=\"physics\""))
  assert_false(saved.contains("name=\"sim\""))
  assert_true(saved.contains("<link name=\"base_link\"/>"))
}

///|
test "host API saves URDF extension attribute edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-extension-attribute-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="extension_attr_route_bot">
      #|  <link name="base_link"/>
      #|  <gazebo reference="base_link">
      #|    <plugin name="sim" filename="libsim.so"/>
      #|  </gazebo>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write extension attribute editor test URDF")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-extension-attribute",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some("extension:gazebo:0"),
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: Some({ name: "reference", value: "body_link" }),
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(
    response.body.contains("\"command\": \"update-extension-attribute\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved extension attribute editor model")
  }
  assert_true(saved.contains("<gazebo reference=\"body_link\">"))
  assert_true(saved.contains("filename=\"libsim.so\""))
}

///|
test "host API saves URDF transmission edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-transmission-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="transmission_route_bot">
      #|  <link name="base_link"/>
      #|  <link name="tool_link"/>
      #|  <joint name="tool_joint" type="fixed">
      #|    <parent link="base_link"/>
      #|    <child link="tool_link"/>
      #|  </joint>
      #|  <transmission name="tool_drive">
      #|    <type>old</type>
      #|    <joint name="old_joint"/>
      #|    <actuator name="old_motor">
      #|      <mechanicalReduction>1</mechanicalReduction>
      #|    </actuator>
      #|  </transmission>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write transmission editor test URDF")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-transmission",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some("extension:transmission:0"),
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: Some({
        transmission_type: Some("transmission_interface/SimpleTransmission"),
        joint_name: Some("tool_joint"),
        actuator_name: Some("tool_motor"),
        mechanical_reduction: Some(2.0),
      }),
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"command\": \"update-transmission\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved transmission editor model")
  }
  assert_true(
    saved.contains("<type>transmission_interface/SimpleTransmission</type>"),
  )
  assert_true(saved.contains("<joint name=\"tool_joint\"/>"))
  assert_true(saved.contains("<actuator name=\"tool_motor\">"))
  assert_true(saved.contains("<mechanicalReduction>2</mechanicalReduction>"))
}

///|
test "host API saves URDF gazebo plugin edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-gazebo-plugin-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="gazebo_plugin_route_bot">
      #|  <link name="base_link"/>
      #|  <gazebo reference="base_link">
      #|    <plugin name="sim" filename="libsim.so">
      #|      <topicName>/old</topicName>
      #|    </plugin>
      #|  </gazebo>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write gazebo plugin editor test URDF")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-gazebo-plugin",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some("extension:gazebo:0"),
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: Some({
        plugin_name: Some("physics"),
        plugin_filename: Some("libphysics.so"),
        parameters: [{ name: "topicName", value: "/new" }],
      }),
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"command\": \"update-gazebo-plugin\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved gazebo plugin editor model")
  }
  assert_true(
    saved.contains("<plugin name=\"physics\" filename=\"libphysics.so\">"),
  )
  assert_true(saved.contains("<topicName>/new</topicName>"))
}

///|
test "host API saves URDF visual geometry edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-geometry-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-visual-geometry",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: Some(0),
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: Some({
        kind: "mesh",
        mesh_filename: Some("package://route/meshes/base.stl"),
        mesh_scale: Some("1 2 3"),
        size: None,
        radius: None,
        length: None,
      }),
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"update-visual-geometry\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved visual geometry editor model")
  }
  assert_true(
    saved.contains(
      "<mesh filename=\"package://route/meshes/base.stl\" scale=\"1 2 3\"/>",
    ),
  )
  assert_true(saved.contains("<material name=\"route_paint\"/>"))
}

///|
test "host API saves URDF link rename edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-rename-link-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "rename-link",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: Some("body_link"),
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"rename-link\""))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved rename editor model")
  }
  assert_true(saved.contains("<link name=\"body_link\">"))
  assert_true(saved.contains("<parent link=\"body_link\"/>"))
  assert_false(saved.contains("<link name=\"base_link\">"))
}

///|
test "host API saves URDF add-link edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-add-link-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="add_link_bot">
      #|  <link name="base_link"/>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write add-link editor model")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "add-link",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: Some({ name: "tool_link" }),
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"add-link\""))
  assert_true(response.body.contains("\"target\": \"tool_link\""))
  assert_true(
    response.body.contains("\"selected_node_id\": \"link:tool_link\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved add-link editor model")
  }
  assert_true(saved.contains("<link name=\"base_link\"/>"))
  assert_true(saved.contains("<link name=\"tool_link\"/>"))
}

///|
test "host API saves URDF add-joint edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-add-joint-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="add_joint_bot">
      #|  <link name="base_link"/>
      #|  <link name="tool_link"/>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write add-joint editor model")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "add-joint",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: Some({
        name: "tool_fixed",
        joint_type: "fixed",
        parent_link: "base_link",
        child_link: "tool_link",
        origin: Some({ xyz: "0 0 1", rpy: "0 0 0" }),
        axis: None,
        limit: None,
      }),
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"add-joint\""))
  assert_true(response.body.contains("\"target\": \"tool_fixed\""))
  assert_true(
    response.body.contains("\"selected_node_id\": \"joint:tool_fixed\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved add-joint editor model")
  }
  assert_true(saved.contains("<joint name=\"tool_fixed\" type=\"fixed\">"))
  assert_true(saved.contains("<parent link=\"base_link\"/>"))
  assert_true(saved.contains("<child link=\"tool_link\"/>"))
  assert_true(saved.contains("<origin xyz=\"0 0 1\" rpy=\"0 0 0\"/>"))
}

///|
test "host API saves URDF add-visual edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-add-visual-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="add_visual_bot">
      #|  <link name="base_link"/>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write add-visual editor model")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "add-visual",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: Some({
        link_name: "base_link",
        origin: Some({ xyz: "0 0 1", rpy: "0 0 0" }),
        geometry: {
          kind: "box",
          mesh_filename: None,
          mesh_scale: None,
          size: Some("1 2 3"),
          radius: None,
          length: None,
        },
      }),
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"add-visual\""))
  assert_true(response.body.contains("\"target\": \"base_link:0\""))
  assert_true(
    response.body.contains("\"selected_node_id\": \"visual:base_link:0\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved add-visual editor model")
  }
  assert_true(saved.contains("<link name=\"base_link\">"))
  assert_true(saved.contains("<visual>"))
  assert_true(saved.contains("<box size=\"1 2 3\"/>"))
}

///|
test "host API saves URDF add-collision edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-add-collision-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="add_collision_bot">
      #|  <link name="base_link"/>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write add-collision editor model")
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "add-collision",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: Some({
        link_name: "base_link",
        origin: None,
        geometry: {
          kind: "sphere",
          mesh_filename: None,
          mesh_scale: None,
          size: None,
          radius: Some(0.25),
          length: None,
        },
      }),
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"command\": \"add-collision\""))
  assert_true(response.body.contains("\"target\": \"base_link:0\""))
  assert_true(
    response.body.contains("\"selected_node_id\": \"collision:base_link:0\""),
  )
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved add-collision editor model")
  }
  assert_true(saved.contains("<collision>"))
  assert_true(saved.contains("<sphere radius=\"0.25\"/>"))
}

///|
test "host API saves URDF remove visual and collision edits" {
  let root = "/tmp/moonrobo-host-urdf-editor-remove-vc-save"
  prepare_submission_root(root)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    (
      #|<robot name="remove_vc_bot">
      #|  <link name="base_link">
      #|    <visual><geometry><box size="1 1 1"/></geometry></visual>
      #|    <collision><geometry><sphere radius="0.5"/></geometry></collision>
      #|  </link>
      #|</robot>,
    ),
  ) catch {
    _ => fail("failed to write remove visual/collision editor model")
  }
  let remove_visual = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "remove-visual",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: Some(0),
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(remove_visual.status, 200)
  let remove_collision = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "remove-collision",
      joint_name: None,
      link_name: Some("base_link"),
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: Some(0),
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(remove_collision.status, 200)
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved remove visual/collision editor model")
  }
  assert_false(saved.contains("<visual>"))
  assert_false(saved.contains("<collision>"))
  assert_true(saved.contains("<link name=\"base_link\">"))
}

///|
test "host API saves current URDF editor session without reapplying command" {
  let root = "/tmp/moonrobo-host-urdf-editor-save-session"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let before = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model before session save")
  }
  let active = match @runtime.read_active_urdf_document(root) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let session = {
    ..active.session,
    source: before
    .replace(old="base_link", new="body_link")
    .replace(old="base_link", new="body_link"),
    selected_node_id: "link:body_link",
    dirty: true,
  }
  assert_true(session.dirty)
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "save-session",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some(session.selected_node_id),
      session: Some(session),
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"command\": \"save-session\""))
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"dirty\": false"))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read saved session editor model")
  }
  assert_true(saved.contains("<link name=\"body_link\">"))
  assert_true(saved.contains("<parent link=\"body_link\"/>"))
  assert_false(saved.contains("<link name=\"base_link\">"))
}

///|
test "host API blocks saving URDF editor session with errors" {
  let root = "/tmp/moonrobo-host-urdf-editor-block-invalid-save"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let before = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model before blocked save")
  }
  let active = match @runtime.read_active_urdf_document(root) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let invalid_source =
    #|<robot name="invalid_save_bot">
    #|  <link name="base_link"/>
    #|  <joint name="bad_joint" type="fixed">
    #|    <parent link="base_link"/>
    #|    <child link="missing_link"/>
    #|  </joint>
    #|</robot>
  let session = {
    ..active.session,
    source: invalid_source,
    selected_node_id: "joint:bad_joint",
    dirty: true,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "save-session",
      joint_name: None,
      link_name: None,
      new_name: None,
      selected_node_id: Some(session.selected_node_id),
      session: Some(session),
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: None,
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(response.status, 400)
  assert_true(response.body.contains("urdf-editor-blocking-diagnostics"))
  assert_true(response.body.contains("joint-child-unknown"))
  assert_false(@fsx.path_exists(root + "/runs/model-edits/latest.json"))
  let saved = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after blocked save")
  }
  assert_eq(saved, before)
}

///|
test "host API reverts latest saved URDF editor edit" {
  let root = "/tmp/moonrobo-host-urdf-editor-revert"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let before = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model before save")
  }
  let save = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-origin",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: Some({ xyz: "9 8 7", rpy: "0.9 0.8 0.7" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(save.status, 200)
  let changed = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after save")
  }
  assert_true(changed.contains("<origin xyz=\"9 8 7\" rpy=\"0.9 0.8 0.7\"/>"))
  let revert = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_revert_path(),
    "{}",
  )
  assert_eq(revert.status, 200)
  assert_true(revert.body.contains("\"reverted\": true"))
  assert_true(revert.body.contains("\"source_path\""))
  assert_true(@fsx.path_exists(root + "/runs/model-edits/latest-revert.json"))
  let restored = @fsx.read_file_to_string(root + "/model/robot.urdf") catch {
    _ => fail("failed to read editor model after revert")
  }
  assert_eq(restored, before)
}

///|
test "host API rejects URDF editor revert when active source changed" {
  let root = "/tmp/moonrobo-host-urdf-editor-revert-stale"
  prepare_submission_root(root)
  write_editor_test_urdf(root)
  let save = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_edit_path(),
    @runtime.UrdfEditorEditRequest::{
      command: "update-joint-origin",
      joint_name: Some("tool_joint"),
      link_name: None,
      new_name: None,
      selected_node_id: None,
      session: None,
      material_node_id: None,
      visual_index: None,
      collision_index: None,
      origin: Some({ xyz: "9 8 7", rpy: "0.9 0.8 0.7" }),
      axis: None,
      limit: None,
      dynamics: None,
      mimic: None,
      calibration: None,
      safety_controller: None,
      inertial: None,
      material: None,
      geometry: None,
      extension: None,
      extension_attribute: None,
      transmission: None,
      gazebo_plugin: None,
      link_create: None,
      joint_create: None,
      visual_create: None,
      collision_create: None,
      save: true,
    }
    .to_json()
    .stringify(),
  )
  assert_eq(save.status, 200)
  @fsx.write_string_to_file(
    root + "/model/robot.urdf",
    "<robot name=\"external_change\"/>",
  ) catch {
    _ => fail("failed to mutate editor model after save")
  }
  let revert = @host_api.route_with_body(
    root,
    "POST",
    @host_api.robobook_urdf_revert_path(),
    "{}",
  )
  assert_eq(revert.status, 400)
  assert_true(revert.body.contains("urdf-editor-revert-stale-active"))
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
      "\"dispatch_path\": \"\{root}/.moonsuite/products/moonrobo/bridge-dispatches/dispatch-request-execute-intent-host-api-walk-1000.json\"",
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
