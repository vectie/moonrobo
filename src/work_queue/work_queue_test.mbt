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
    execution_count: 0,
    verified_execution_count: 0,
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
    bridge_status: "Accepted",
    runtime_status: "",
    runtime_health_persisted: false,
    telemetry_frame_id: "",
    physical_feedback_status: "missing",
    physical_feedback_verified: false,
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
test "work queue prioritizes unverified execution proof before observation" {
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
  assert_true(queue.next_item is Some({ kind: "verify-execution", .. }))
  assert_eq(queue.items[0].target_path, "/api/moonrobo/executions")
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.kind, "verify-execution")
  assert_eq(action.http_method, "GET")
  assert_eq(action.route, "/api/moonrobo/executions")
  assert_eq(action.execution_mode, "read-only")
  assert_true(!action.physical_execution_allowed)
}

///|
test "work queue prioritizes bridge and review before observation" {
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
  assert_true(queue.next_item is Some({ kind: "connect-bridge", .. }))
  assert_eq(queue.items[1].kind, "review-evidence")
  let plan = @work_queue.next_action_plan(queue)
  assert_true(plan.action is Some({ http_method: "GET", .. }))
  assert_true(plan.action is Some({ route: "/api/bridge/sidecar", .. }))
  assert_true(plan.action is Some({ body_template: None, .. }))
  assert_true(plan.action is Some({ physical_execution_allowed: false, .. }))
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
