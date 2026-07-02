///|
fn input(
  mapped? : Bool = true,
  has_task_message? : Bool = true,
  memory_card_count? : Int = 3,
  can_submit_gateway_command? : Bool = true,
  physical_execution_allowed? : Bool = false,
  loop_ready? : Bool = false,
  proof_session_feedback_closed? : Bool = false,
) -> @product_status.MoonroboProductStatusInput {
  let root = "/tmp/moonrobo-product-status-suite/books/status-test"
  {
    root,
    robot_id: "noetix-e1-lab-01",
    bridge_id: "sdk-e1",
    mapped,
    has_task_message,
    memory_card_count,
    can_submit_gateway_command,
    physical_execution_allowed,
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
    live_readiness_status: if can_submit_gateway_command {
      "ready-for-proof-session"
    } else {
      "needs-runtime-validation"
    },
    latest_task_execution_path: if loop_ready {
      "/runs/executions/latest.json"
    } else {
      ""
    },
    latest_gateway_command_path: @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "gateway-commands/latest.json",
    ),
    latest_robo_loop_path: @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "robo-loops/latest.json",
    ),
    latest_proof_session_path: @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "proof-sessions/latest.json",
    ),
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
    next_route: "/api/moonrobo/proof-session",
  }
}

///|
test "product status classifies first physical agent loop" {
  let suite_root = "/tmp/moonrobo-product-status-suite"
  let root = suite_root + "/books/status-test"
  let routine_ready = @product_status.project(input())
  assert_eq(routine_ready.status, "command-ready")
  assert_true(!routine_ready.ready)
  assert_eq(routine_ready.completed_count, 5)
  assert_eq(routine_ready.total_count, 6)
  assert_eq(routine_ready.next_route, "/api/moonrobo/executions/feedback")
  assert_eq(
    routine_ready.product_homes.moonrobo_product_home,
    @moonsuite.product_home_for_workspace_root(root, "moonrobo").state_path,
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_gateway_commands_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "gateway-commands",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_dry_runs_path,
    @moonsuite.product_artifact_for_workspace_root(root, "moonrobo", "dry-runs"),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_approvals_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "approvals",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_robo_loops_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "robo-loops",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_robo_turns_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "robo-turns",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_prove_loop_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "prove-loop",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_proof_sessions_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "proof-sessions",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_live_exercises_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "live-exercises",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_bridge_dispatches_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "bridge-dispatches",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_bridge_contracts_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "bridge-contracts",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_runtime_supervisor_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "runtime-supervisor",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_runtime_validation_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "runtime-validation",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_runtime_calibration_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "runtime-calibration",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonrobo_runtime_health_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "runtime-health",
    ),
  )
  assert_eq(
    routine_ready.product_homes.moonclaw_robot_routine_runs_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonclaw", "robot-routine-runs",
    ),
  )
  assert_false(
    routine_ready.product_homes.moonrobo_product_home.contains(
      "/books/status-test/.moonsuite",
    ),
  )
  let complete = @product_status.project(
    input(physical_execution_allowed=true, loop_ready=true),
  )
  assert_eq(complete.status, "complete")
  assert_true(complete.ready)
  assert_eq(complete.percent, 100)
  let session_complete = @product_status.project(
    input(loop_ready=true, proof_session_feedback_closed=true),
  )
  assert_eq(session_complete.status, "complete")
  assert_true(session_complete.ready)
  assert_eq(
    session_complete.capabilities[5].evidence_path,
    @moonsuite.product_artifact_for_workspace_root(
      root, "moonrobo", "proof-sessions/latest.json",
    ),
  )
  let foundation = @product_status.project(
    input(
      mapped=false,
      has_task_message=false,
      memory_card_count=0,
      can_submit_gateway_command=false,
    ),
  )
  assert_eq(foundation.status, "needs-foundation")
  assert_eq(foundation.next_route, "/api/moonrobo/readiness")
}
