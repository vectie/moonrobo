///|
fn input(
  mapped? : Bool = true,
  has_task_message? : Bool = true,
  memory_card_count? : Int = 3,
  can_run_robot_routine? : Bool = true,
  physical_execution_allowed? : Bool = false,
  loop_ready? : Bool = false,
  proof_session_feedback_closed? : Bool = false,
  live_exercise_closed? : Bool = false,
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
    proof_session_feedback_closed,
    proof_session_auto_feedback_success_count: if proof_session_feedback_closed {
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
    latest_live_exercise_path: if live_exercise_closed {
      "/runs/live-exercises/latest.json"
    } else {
      ""
    },
    live_exercise_closed,
    live_exercise_status: if live_exercise_closed {
      "verified"
    } else {
      "missing"
    },
    live_exercise_missing_count: if live_exercise_closed {
      0
    } else {
      1
    },
    live_exercise_next_route: "/api/moonrobo/live-exercise",
    live_exercise_message: if live_exercise_closed {
      "Live exercise closure is complete."
    } else {
      "No live exercise closure has been recorded."
    },
    next_route: "/api/moonrobo/proof-session",
  }
}

///|
test "product status classifies first physical agent loop" {
  let routine_ready = @product_status.project(input())
  assert_eq(routine_ready.status, "routine-ready")
  assert_true(!routine_ready.ready)
  assert_eq(routine_ready.completed_count, 5)
  assert_eq(routine_ready.total_count, 7)
  assert_eq(routine_ready.next_route, "/api/moonrobo/executions/feedback")
  let complete = @product_status.project(
    input(
      physical_execution_allowed=true,
      loop_ready=true,
      live_exercise_closed=true,
    ),
  )
  assert_eq(complete.status, "complete")
  assert_true(complete.ready)
  assert_eq(complete.percent, 100)
  let session_complete = @product_status.project(
    input(
      loop_ready=true,
      proof_session_feedback_closed=true,
      live_exercise_closed=true,
    ),
  )
  assert_eq(session_complete.status, "complete")
  assert_true(session_complete.ready)
  assert_eq(
    session_complete.capabilities[5].evidence_path,
    "/runs/proof-sessions/latest.json",
  )
  assert_true(
    session_complete.capabilities.any(item => {
      item.code == "live-exercise-closure" &&
      item.ready &&
      item.evidence_path == "/runs/live-exercises/latest.json"
    }),
  )
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
