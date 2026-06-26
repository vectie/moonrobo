///|
fn resident(availability : String) -> @resident.ResidentRobotAgent {
  {
    resident_id: "robot:noetix-e1-lab-01",
    robot_id: "noetix-e1-lab-01",
    label: "Noetix E1",
    platform: "noetix-e1",
    role: "physical-robot",
    availability,
    safety_state: "clear",
    bridge_state: "launchable",
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
    command_path: "/tmp/sdk-e1",
    town_route: "/town/residents/robot:noetix-e1-lab-01",
  }
}

///|
fn unverified_execution() -> @resident.ResidentExecutionSummary {
  {
    snapshot_id: "task-execution-work",
    task_id: "message-work",
    status: "bridge-accepted",
    verified: false,
    message: "execution needs runtime proof",
    receipt_id: "receipt-work-executed",
    command_capability: "control.high.walk",
    bridge_status: "Accepted",
    runtime_status: "",
    runtime_health_persisted: false,
    telemetry_frame_id: "",
    physical_feedback_path: "",
    physical_feedback_status: "missing",
    physical_feedback_verified: false,
    command_outcome_status: "unconfirmed",
    command_outcome_verified: false,
    captured_at_ms: 60L,
  }
}

///|
fn accepted_episode() -> @dataset.DatasetEpisode {
  {
    episode_id: "episode-session-work",
    format_version: 1,
    robot_id: "noetix-e1-lab-01",
    bridge_id: "sdk-e1",
    session_id: "session-work",
    status: "stopped",
    started_at_ms: 1L,
    stopped_at_ms: Some(2L),
    frame_count: 1,
    receipt_id: "receipt-work",
    review_id: "review-work",
    review_disposition: "accepted",
    replay_path: "/api/replays/session-work",
    artifact_paths: ["/tmp/frame.json"],
    annotation_count: 0,
    annotation_ids: [],
    frames: [],
  }
}

///|
test "work queue prioritizes feedback binding before observation" {
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    {
      ..resident("ready"),
      latest_execution: Some(unverified_execution()),
      execution_count: 1,
      verified_execution_count: 0,
    },
    [],
    [],
    [],
    [],
    46L,
  )
  assert_true(queue.next_item is Some({ kind: "bind-execution-feedback", .. }))
  assert_eq(queue.items[0].target_path, "/api/moonrobo/executions/feedback")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "bind-execution-feedback")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/moonrobo/executions/feedback")
  assert_eq(action.body_schema, "TaskExecutionFeedbackRequest")
  assert_eq(action.execution_mode, "bounded-verification")
  assert_true(!action.physical_execution_allowed)
}

///|
test "work queue prioritizes runtime start and review before observation" {
  let review : @review.ProcessReview = {
    review_id: "review-work",
    task_id: "task-work",
    session_id: "session-work",
    robot_id: "noetix-e1-lab-01",
    receipt_id: "receipt-work",
    disposition: NeedsHumanReview,
    severity: Attention,
    summary: "needs operator review",
    findings: ["review before next loop"],
    artifact_paths: ["/tmp/review.json"],
    created_at_ms: 10L,
    resolved_at_ms: None,
    resolution_note: None,
  }
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("bridge-missing"),
    [review],
    [],
    [],
    [],
    42L,
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.high_priority_count, 2)
  assert_true(queue.next_item is Some({ kind: "start-runtime", .. }))
  assert_eq(queue.items[1].kind, "review-evidence")
  let plan = @work_queue.next_action_plan(queue)
  assert_true(plan.action is Some({ http_method: "POST", .. }))
  assert_true(
    plan.action is Some({ route: "/api/runtime/supervisor/start", .. }),
  )
  assert_true(plan.action is Some({ body_template: None, .. }))
  assert_true(plan.action is Some({ physical_execution_allowed: false, .. }))
}

///|
test "next action can resolve route authority from tool registry" {
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    47L,
  )
  assert_true(queue.next_item is Some({ kind: "observe", .. }))
  let override_provider : @tool_registry.ToolProvider = {
    provider_id: "test-observation-gateway",
    label: "Test Observation Gateway",
    kind: "suite-tool",
    robot_id: "noetix-e1-lab-01",
    endpoint_base: "/api/test",
    memory_required: true,
    capabilities: [
      {
        capability_id: "observation.run",
        label: "Run observation through gateway override",
        http_method: "POST",
        route: "/api/test/moonrobo/observe-run",
        body_schema: "ObservationRunRequest",
        execution_mode: "bounded-observation",
        physical_execution_allowed: false,
        safety_note: "Registry-owned route authority for bounded observation evidence.",
      },
    ],
    registered_at_ms: 47L,
  }
  let registry = @tool_registry.with_provider(
    @tool_registry.default_registry("noetix-e1-lab-01", 0L),
    override_provider,
    47L,
  )
  let action = @work_queue.next_action_plan_with_registry(queue, registry).action.unwrap()
  assert_eq(action.kind, "observe")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/test/moonrobo/observe-run")
  assert_eq(action.body_schema, "ObservationRunRequest")
  assert_eq(action.execution_mode, "bounded-observation")
  assert_true(!action.physical_execution_allowed)
}

///|
test "work queue promotes proof session before ordinary observation" {
  let proof = @work_queue.proof_session_work_evidence(
    "operational-unproven", false, 5, 6, 83, "/api/moonrobo/executions", "Moonrobo loop is 5/6 proven; continue with /api/moonrobo/executions.",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    48L,
    proof_session=Some(proof),
  )
  assert_eq(queue.item_count, 2)
  assert_true(queue.next_item is Some({ kind: "run-proof-session", .. }))
  assert_eq(queue.items[0].priority, 82)
  assert_eq(queue.items[1].kind, "observe")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "run-proof-session")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/moonrobo/proof-session")
  assert_eq(action.body_schema, "PlatformProofSessionRequest")
  assert_eq(action.execution_mode, "bounded-proof")
  assert_true(!action.physical_execution_allowed)
  match action.body_template {
    Some(body) => {
      let text = body.stringify()
      assert_true(text.contains("\"iterations\":3"))
      assert_true(
        text.contains("\"session_id\":\"proof-session-noetix-e1-lab-01\""),
      )
    }
    None => fail("expected proof-session body template")
  }
}

///|
test "work queue promotes gateway command before proof session" {
  let routine = @work_queue.robot_routine_work_evidence(
    "ready-for-command", true, "/api/moonrobo/gateway/command", "Moonrobo gateway is mapped and live-ready; submit a gateway command.",
  )
  let proof = @work_queue.proof_session_work_evidence(
    "operational-unproven", false, 5, 6, 83, "/api/moonrobo/executions", "Moonrobo loop is 5/6 proven; continue with /api/moonrobo/executions.",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    49L,
    robot_routine=Some(routine),
    proof_session=Some(proof),
  )
  assert_eq(queue.item_count, 3)
  assert_true(queue.next_item is Some({ kind: "submit-gateway-command", .. }))
  assert_eq(queue.items[0].priority, 83)
  assert_eq(queue.items[1].kind, "run-proof-session")
  assert_eq(queue.items[2].kind, "observe")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "submit-gateway-command")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/moonrobo/gateway/command")
  assert_eq(action.body_schema, "MoonroboGatewayCommandRequest")
  assert_eq(action.execution_mode, "gateway-command")
  assert_true(!action.physical_execution_allowed)
  match action.body_template {
    Some(body) => {
      let text = body.stringify()
      assert_true(text.contains("\"remember\":true"))
      assert_true(
        text.contains("\"command_id\":\"gateway-command-noetix-e1-lab-01\""),
      )
    }
    None => fail("expected gateway-command body template")
  }
}

///|
test "work queue promotes live exercise before routine and proof work" {
  let exercise = @work_queue.live_exercise_work_evidence(
    "pending-proof",
    false,
    2,
    "/api/moonrobo/live-exercise",
    message="Live exercise is missing proof and feedback closure.",
  )
  let routine = @work_queue.robot_routine_work_evidence(
    "ready-for-command", true, "/api/moonrobo/gateway/command", "Moonrobo gateway is mapped and live-ready; submit a gateway command.",
  )
  let proof = @work_queue.proof_session_work_evidence(
    "operational-unproven", false, 5, 6, 83, "/api/moonrobo/executions", "Moonrobo loop is 5/6 proven; continue with /api/moonrobo/executions.",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    50L,
    live_exercise=Some(exercise),
    robot_routine=Some(routine),
    proof_session=Some(proof),
  )
  assert_eq(queue.item_count, 4)
  assert_true(queue.next_item is Some({ kind: "run-live-exercise", .. }))
  assert_eq(queue.items[0].priority, 84)
  assert_eq(queue.items[1].kind, "submit-gateway-command")
  assert_eq(queue.items[2].kind, "run-proof-session")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "run-live-exercise")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/moonrobo/live-exercise")
  assert_eq(action.body_schema, "MoonroboLiveExerciseRequest")
  assert_eq(action.execution_mode, "bounded-live-exercise")
  assert_true(!action.physical_execution_allowed)
  match action.body_template {
    Some(body) => {
      let text = body.stringify()
      assert_true(
        text.contains("\"exercise_id\":\"live-exercise-noetix-e1-lab-01\""),
      )
      assert_true(text.contains("\"validation_sample_count\":3"))
      assert_true(text.contains("\"remember\":true"))
    }
    None => fail("expected live-exercise body template")
  }
}

///|
test "work queue moves curated episodes toward policy evaluation" {
  let episode = {
    ..accepted_episode(),
    annotation_count: 1,
    annotation_ids: ["a1"],
  }
  let quality : @dataset.DatasetQualityReport = {
    episode_id: episode.episode_id,
    passed: true,
    issue_count: 0,
    blocker_count: 0,
    warning_count: 0,
    frame_count: 1,
    artifact_count: 1,
    issues: [],
  }
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    {
      ..resident("ready"),
      latest_observation: Some(
        @resident.observation_summary(
          @core.stopped_observation_session(
            @core.observation_session(
              "session-work",
              @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1"),
              @core.operator_requester("test"),
              "receipt-work",
              1L,
            ),
            2L,
            1,
            latest_frame_id="frame-work",
          ),
        ),
      ),
    },
    [],
    [],
    [@work_queue.dataset_work_evidence(episode, quality)],
    [],
    43L,
  )
  assert_eq(queue.item_count, 1)
  assert_true(queue.next_item is Some({ kind: "evaluate-policy", .. }))
  assert_eq(queue.items[0].target_path, "/api/policies/evaluate")
  let plan = @work_queue.next_action_plan(queue)
  assert_true(plan.action is Some({ kind: "evaluate-policy", .. }))
  assert_true(plan.action is Some({ http_method: "POST", .. }))
  assert_true(
    plan.action is Some({ body_schema: "PolicyEvaluationRequest", .. }),
  )
  match plan.action {
    Some({ body_template: Some(body), .. }) => {
      let text = body.stringify()
      assert_true(text.contains("\"episode_id\":\"episode-session-work\""))
      assert_true(!text.contains("\"physical_execution_allowed\""))
    }
    _ => fail("expected policy action body template")
  }
}

///|
test "work queue raises runtime calibration blockers before observation" {
  let calibration = @work_queue.runtime_calibration_work_evidence(
    "runtime-calibration-test", "needs-calibration", 4, 3, "calibrate-runtime-process",
    "runtime-active", "runtime", "Physical runtime supervisor is not active", "Start the runtime supervisor and refresh validation before dispatching physical tasks",
    "/api/agent/runtime-calibration/latest",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    45L,
    runtime_calibration=Some(calibration),
  )
  assert_eq(queue.item_count, 2)
  assert_true(queue.next_item is Some({ kind: "calibrate-runtime", .. }))
  assert_eq(queue.items[0].priority, 95)
  assert_eq(queue.items[0].target_path, "/api/agent/runtime-calibration/latest")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "calibrate-runtime")
  assert_eq(action.http_method, "GET")
  assert_eq(action.route, "/api/agent/runtime-calibration/latest")
  assert_eq(action.execution_mode, "operator-calibration")
  assert_true(!action.physical_execution_allowed)
}

///|
test "work queue raises runtime validation after calibration resolution" {
  let calibration = @work_queue.runtime_calibration_work_evidence(
    "runtime-calibration-test",
    "needs-calibration",
    4,
    3,
    "calibrate-runtime-process",
    "runtime-active",
    "runtime",
    "Physical runtime supervisor is not active",
    "Start the runtime supervisor and refresh validation before dispatching physical tasks",
    "/api/agent/runtime-calibration/latest",
    pending_revalidation=true,
    resolution_id="runtime-calibration-resolution-calibrate-runtime-process-9900",
    resolution_status="resolved-pending-validation",
    validation_path="/api/runtime/validation/session",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    46L,
    runtime_calibration=Some(calibration),
  )
  assert_eq(queue.item_count, 2)
  assert_true(queue.next_item is Some({ kind: "validate-runtime", .. }))
  assert_eq(queue.items[0].priority, 101)
  assert_eq(queue.items[0].target_path, "/api/runtime/validation/session")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "validate-runtime")
  assert_eq(action.http_method, "POST")
  assert_eq(action.route, "/api/runtime/validation/session")
  assert_eq(action.execution_mode, "operator-validation")
  assert_true(action.body_template is None)
  assert_true(!action.physical_execution_allowed)
}

///|
test "work queue raises runtime validation from readiness evidence" {
  let readiness = @work_queue.runtime_calibration_work_evidence(
    "readiness-noetix-e1-lab-01-bridge-contract",
    "needs-validation",
    1,
    1,
    "persist-live-bridge-contract",
    "bridge-contract-ready",
    "bridge",
    "bridge authority contract evidence is not persisted",
    "Run repeated runtime validation so Moonrobo persists the live bridge authority contract before physical dispatch",
    "/tmp/moonrobo/runs/bridge-contracts/latest.json",
    pending_revalidation=true,
    validation_path="/api/runtime/validation/session",
  )
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    [],
    47L,
    runtime_calibration=Some(readiness),
  )
  assert_true(queue.next_item is Some({ kind: "validate-runtime", .. }))
  assert_eq(queue.items[0].title, "Validate runtime readiness")
  assert_eq(
    queue.items[0].summary,
    "bridge authority contract evidence is not persisted",
  )
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "validate-runtime")
  assert_true(action.safety_note.contains("does not dispatch physical tasks"))
}

///|
fn command_task_message_plan() -> @task.RobotTaskMessagePlan {
  @task.plan_task_message(
    @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1"),
    @task.task_message_request(
      "walk-now",
      "noetix-e1-lab-01",
      @core.operator_requester("rabbita"),
      "walk forward",
      50L,
    ),
  ).unwrap()
}

///|
fn task_message_queue(
  evidence : @work_queue.TaskMessageWorkEvidence,
) -> @work_queue.AgentWorkQueue {
  @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [evidence],
    [],
    [],
    44L,
  )
}

///|
test "work queue advances command task messages through safety steps" {
  let plan = command_task_message_plan()
  let queue = task_message_queue(
    @work_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json", plan,
    ),
  )
  assert_eq(queue.item_count, 2)
  assert_true(queue.next_item is Some({ kind: "evaluate-command-message", .. }))
  assert_eq(
    queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/evaluate",
  )
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.http_method, "POST")
  assert_eq(action.execution_mode, "operator-safety")
  assert_true(!action.physical_execution_allowed)
  let dry_run_queue = task_message_queue(
    @work_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
    ),
  )
  assert_true(
    dry_run_queue.next_item is Some({ kind: "dry-run-command-message", .. }),
  )
  assert_eq(
    dry_run_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/dry-run",
  )
  let approve_queue = task_message_queue(
    @work_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
      dry_run_collected=true,
    ),
  )
  assert_true(
    approve_queue.next_item is Some({ kind: "approve-command-message", .. }),
  )
  assert_eq(
    approve_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/approve",
  )
  let execute_queue = task_message_queue(
    @work_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
      dry_run_collected=true,
      approved=true,
    ),
  )
  assert_true(
    execute_queue.next_item is Some({ kind: "execute-command-message", .. }),
  )
  assert_eq(
    execute_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/execute-sidecar",
  )
}
