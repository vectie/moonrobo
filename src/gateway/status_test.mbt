///|
fn input(
  mapped? : Bool = true,
  loop_ready? : Bool = false,
  live_readiness_status? : String = "needs-runtime-validation",
  can_submit_gateway_command? : Bool = false,
  proof_session_feedback_closed? : Bool = false,
) -> @gateway.MoonroboGatewayStatusInput {
  {
    root: "/tmp/moonrobo-gateway-test",
    robot_id: "noetix-e1-lab-01",
    bridge_id: "sdk-e1",
    mapped,
    has_task_message: true,
    session_stage: "ready-to-dispatch",
    memory_card_count: 3,
    loop_ready,
    loop_percent: if loop_ready {
      100
    } else {
      67
    },
    loop_status: if loop_ready {
      "complete"
    } else {
      "operational-unproven"
    },
    live_readiness_status,
    physical_execution_allowed: loop_ready &&
    live_readiness_status == "verified",
    can_submit_gateway_command,
    latest_task_execution_path: "/tmp/execution.json",
    latest_gateway_command_path: "/tmp/routine.json",
    latest_robo_loop_path: "/tmp/loop.json",
    latest_proof_session_path: "/tmp/proof-session.json",
    proof_session_feedback_closed,
    proof_session_feedback_binding_success_count: if proof_session_feedback_closed {
      1
    } else {
      0
    },
    proof_session_latest_feedback_status: if proof_session_feedback_closed {
      200
    } else {
      0
    },
    proof_session_latest_feedback_message: if proof_session_feedback_closed {
      "Physical feedback verified."
    } else {
      ""
    },
    next_method: "POST",
    next_route: "/api/moonrobo/proof-session",
    next_title: "Run bounded proof session",
  }
}

///|
test "gateway status classifies compact product state" {
  let verified = @gateway.project(
    input(
      loop_ready=true,
      live_readiness_status="verified",
      can_submit_gateway_command=true,
    ),
  )
  assert_eq(verified.status, "verified")
  assert_true(verified.ready)
  assert_true(verified.physical_execution_allowed)
  assert_eq(verified.loop_percent, 100)
  let routine = @gateway.project(
    input(
      live_readiness_status="ready-for-proof-session",
      can_submit_gateway_command=true,
    ),
  )
  assert_eq(routine.status, "ready-for-command")
  assert_true(!routine.ready)
  let mapped = @gateway.project(input())
  assert_eq(mapped.status, "mapped-needs-evidence")
  assert_true(mapped.message.contains("/api/moonrobo/proof-session"))
  let unmapped = @gateway.project(input(mapped=false))
  assert_eq(unmapped.status, "unmapped")
}
