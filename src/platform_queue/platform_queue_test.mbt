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
test "platform queue prioritizes feedback binding before observation" {
  let queue = @platform_queue.project(
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
    46L,
  )
  assert_eq(queue.items[0].kind, "bind-execution-feedback")
  assert_eq(queue.items[0].target_path, "/api/moonrobo/executions/feedback")
}

///|
test "platform queue prioritizes runtime start and review before observation" {
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
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("bridge-missing"),
    [review],
    [],
    [],
    42L,
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.high_priority_count, 2)
  assert_eq(queue.items[0].kind, "start-runtime")
  assert_eq(queue.items[1].kind, "review-evidence")
}

///|
test "platform queue promotes proof session before ordinary observation" {
  let proof = @platform_queue.proof_session_work_evidence(
    "operational-unproven", false, 5, 6, 83, "/api/moonrobo/executions", "Moonrobo loop is 5/6 proven; continue with /api/moonrobo/executions.",
  )
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    48L,
    proof_session=Some(proof),
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.items[0].kind, "run-proof-session")
  assert_eq(queue.items[0].priority, 82)
  assert_eq(queue.items[1].kind, "observe")
  assert_eq(queue.items[0].target_path, "/api/moonrobo/proof-session")
}

///|
test "platform queue promotes gateway command before proof session" {
  let gateway_command = @platform_queue.gateway_command_work_evidence(
    "ready-for-command", true, "/api/moonrobo/gateway/command", "Moonrobo gateway is mapped and live-ready; submit a gateway command.",
  )
  let proof = @platform_queue.proof_session_work_evidence(
    "operational-unproven", false, 5, 6, 83, "/api/moonrobo/executions", "Moonrobo loop is 5/6 proven; continue with /api/moonrobo/executions.",
  )
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    49L,
    gateway_command=Some(gateway_command),
    proof_session=Some(proof),
  )
  assert_eq(queue.item_count, 3)
  assert_eq(queue.items[0].kind, "submit-gateway-command")
  assert_eq(queue.items[0].priority, 83)
  assert_eq(queue.items[1].kind, "run-proof-session")
  assert_eq(queue.items[2].kind, "observe")
  assert_eq(queue.items[0].target_path, "/api/moonrobo/gateway/command")
}

///|
test "platform queue does not host policy evaluation for curated episodes" {
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
  let queue = @platform_queue.project(
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
    [@platform_queue.dataset_work_evidence(episode, quality)],
    43L,
  )
  assert_eq(queue.item_count, 0)
  assert_true(queue.items.is_empty())
}

///|
test "platform queue raises runtime calibration blockers before observation" {
  let calibration = @platform_queue.runtime_calibration_work_evidence(
    "runtime-calibration-test", "needs-calibration", 4, 3, "calibrate-runtime-process",
    "runtime-active", "runtime", "Physical runtime supervisor is not active", "Start the runtime supervisor and refresh validation before dispatching physical tasks",
    "/api/moonclaw/runtime-calibration/latest",
  )
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    45L,
    runtime_calibration=Some(calibration),
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.items[0].kind, "calibrate-runtime")
  assert_eq(queue.items[0].priority, 95)
  assert_eq(
    queue.items[0].target_path,
    "/api/moonclaw/runtime-calibration/latest",
  )
}

///|
test "platform queue raises runtime validation after calibration resolution" {
  let calibration = @platform_queue.runtime_calibration_work_evidence(
    "runtime-calibration-test",
    "needs-calibration",
    4,
    3,
    "calibrate-runtime-process",
    "runtime-active",
    "runtime",
    "Physical runtime supervisor is not active",
    "Start the runtime supervisor and refresh validation before dispatching physical tasks",
    "/api/moonclaw/runtime-calibration/latest",
    pending_revalidation=true,
    resolution_id="runtime-calibration-resolution-calibrate-runtime-process-9900",
    resolution_status="resolved-pending-validation",
    validation_path="/api/runtime/validation/session",
  )
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    46L,
    runtime_calibration=Some(calibration),
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.items[0].kind, "validate-runtime")
  assert_eq(queue.items[0].priority, 101)
  assert_eq(queue.items[0].target_path, "/api/runtime/validation/session")
}

///|
test "platform queue raises runtime validation from readiness evidence" {
  let readiness = @platform_queue.runtime_calibration_work_evidence(
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
  let queue = @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [],
    [],
    47L,
    runtime_calibration=Some(readiness),
  )
  assert_eq(queue.items[0].kind, "validate-runtime")
  assert_eq(queue.items[0].title, "Validate runtime readiness")
  assert_eq(
    queue.items[0].summary,
    "bridge authority contract evidence is not persisted",
  )
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
  evidence : @platform_queue.TaskMessageWorkEvidence,
) -> @platform_queue.RobotPlatformQueue {
  @platform_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [evidence],
    [],
    44L,
  )
}

///|
test "platform queue advances command task messages through safety steps" {
  let plan = command_task_message_plan()
  let queue = task_message_queue(
    @platform_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json", plan,
    ),
  )
  assert_eq(queue.item_count, 2)
  assert_eq(queue.items[0].kind, "evaluate-command-message")
  assert_eq(
    queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/evaluate",
  )
  let dry_run_queue = task_message_queue(
    @platform_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
    ),
  )
  assert_eq(dry_run_queue.items[0].kind, "dry-run-command-message")
  assert_eq(
    dry_run_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/dry-run",
  )
  let approve_queue = task_message_queue(
    @platform_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
      dry_run_collected=true,
    ),
  )
  assert_eq(approve_queue.items[0].kind, "approve-command-message")
  assert_eq(
    approve_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/approve",
  )
  let execute_queue = task_message_queue(
    @platform_queue.task_message_work_evidence(
      "/tmp/moonbook/task-messages/message-walk-now.json",
      plan,
      evaluated=true,
      dry_run_collected=true,
      approved=true,
    ),
  )
  assert_eq(execute_queue.items[0].kind, "execute-command-message")
  assert_eq(
    execute_queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now/execute-sidecar",
  )
}
