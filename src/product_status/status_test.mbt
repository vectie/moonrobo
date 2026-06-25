///|
fn input(
  mapped? : Bool = true,
  has_task_message? : Bool = true,
  memory_card_count? : Int = 3,
  can_run_robot_routine? : Bool = true,
  physical_execution_allowed? : Bool = false,
  loop_ready? : Bool = false,
) -> @product_status.MoonroboProductStatusInput {
  {
    root: "/tmp/moonrobo-product-status-test",
    robot_id: "noetix-e1-lab-01",
    bridge_id: "sdk-e1",
    mapped,
    has_task_message,
    memory_card_count,
    can_run_robot_routine,
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
    live_readiness_status: if can_run_robot_routine {
      "ready-for-proof-session"
    } else {
      "needs-runtime-validation"
    },
    latest_task_execution_path: if loop_ready {
      "/runs/executions/latest.json"
    } else {
      ""
    },
    latest_routine_path: "/runs/moonclaw-robot-routines/latest.json",
    latest_robo_loop_path: "/runs/robo-loops/latest.json",
    latest_proof_session_path: "/runs/proof-sessions/latest.json",
    next_route: "/api/moonrobo/proof-session",
  }
}

///|
test "product status classifies first physical agent loop" {
  let routine_ready = @product_status.project(input())
  assert_eq(routine_ready.status, "routine-ready")
  assert_true(!routine_ready.ready)
  assert_eq(routine_ready.completed_count, 5)
  assert_eq(routine_ready.total_count, 6)
  assert_eq(routine_ready.next_route, "/api/moonrobo/executions/feedback")
  let complete = @product_status.project(
    input(physical_execution_allowed=true, loop_ready=true),
  )
  assert_eq(complete.status, "complete")
  assert_true(complete.ready)
  assert_eq(complete.percent, 100)
  let foundation = @product_status.project(
    input(
      mapped=false,
      has_task_message=false,
      memory_card_count=0,
      can_run_robot_routine=false,
    ),
  )
  assert_eq(foundation.status, "needs-foundation")
  assert_eq(foundation.next_route, "/api/moonrobo/readiness")
}
