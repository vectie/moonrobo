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
    capability_count: 3,
    review_count: 0,
    command_path: "/tmp/sdk-e1",
    town_route: "/town/residents/robot:noetix-e1-lab-01",
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
test "work queue surfaces command task messages for operator review" {
  let plan = @task.plan_task_message(
    @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1"),
    @task.task_message_request(
      "walk-now",
      "noetix-e1-lab-01",
      @core.operator_requester("rabbita"),
      "walk forward",
      50L,
    ),
  ).unwrap()
  let queue = @work_queue.project(
    "noetix-e1-lab-01",
    resident("ready"),
    [],
    [
      @work_queue.task_message_work_evidence(
        "/tmp/moonbook/task-messages/message-walk-now.json", plan,
      ),
    ],
    [],
    [],
    44L,
  )
  assert_eq(queue.item_count, 2)
  assert_true(queue.next_item is Some({ kind: "review-command-message", .. }))
  assert_eq(
    queue.items[0].target_path,
    "/api/moonbook/task-messages/message-walk-now",
  )
  let action = @work_queue.next_action_plan(queue).action.unwrap()
  assert_eq(action.http_method, "GET")
  assert_eq(action.execution_mode, "operator-review")
  assert_true(!action.physical_execution_allowed)
}
