///|
test "sample snapshot keeps imported cockpit contract" {
  let snapshot = sample_snapshot()
  inspect(snapshot.robot.robot_id, content="noetix-e1-lab-01")
  inspect(snapshot.safety.decision, content="dry-run-required")
  inspect(snapshot.sidecar.state, content="missing-command")
  inspect(snapshot.read_only, content="true")
}

///|
test "update handles loaded and failed snapshots" {
  let model = init_model()
  let (_, loaded) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Ok(sample_snapshot())),
    model,
  )
  inspect(loaded.loading, content="false")
  inspect(loaded.error is None, content="true")
  let moonstat = {
    ..sample_moonstat_status(),
    policy_evaluation_count: 2,
    latest_policy_evaluation_id: "policy-eval-cockpit",
    latest_policy_gate_status: "requires-dry-run",
    latest_policy_path: "/api/policies/evaluations/policy-eval-cockpit",
  }
  let (_, status_loaded) = update(
    _ => @rabbita.none,
    MoonstatLoaded(Ok(moonstat)),
    loaded,
  )
  inspect(status_loaded.moonstat_status.policy_evaluation_count, content="2")
  inspect(
    status_loaded.moonstat_status.latest_policy_evaluation_id,
    content="policy-eval-cockpit",
  )
  inspect(
    status_loaded.work_queue_status,
    content="Refreshing agent work queue",
  )
  let queue = {
    ..sample_work_queue(),
    item_count: 2,
    high_priority_count: 1,
  }
  let (_, queue_loaded) = update(
    _ => @rabbita.none,
    WorkQueueLoaded(Ok(queue)),
    status_loaded,
  )
  inspect(queue_loaded.work_queue.item_count, content="2")
  inspect(queue_loaded.work_queue_status, content="Loaded 2 work item(s)")
  let (_, failed) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Err("boom")),
    queue_loaded,
  )
  inspect(failed.loading, content="false")
  inspect(failed.error is Some("boom"), content="true")
  let (_, status_failed) = update(
    _ => @rabbita.none,
    MoonstatLoaded(Err("status unavailable")),
    failed,
  )
  inspect(
    status_failed.process_status.contains("Moonstat status rejected"),
    content="true",
  )
  let (_, queue_failed) = update(
    _ => @rabbita.none,
    WorkQueueLoaded(Err("queue unavailable")),
    status_failed,
  )
  inspect(
    queue_failed.work_queue_status.contains("Work queue rejected"),
    content="true",
  )
}

///|
test "update tracks intent evaluation lifecycle" {
  let model = init_model()
  let (_, edited_x) = update(_ => @rabbita.none, UpdateWalkX("0.25"), model)
  inspect(edited_x.walk_x, content="0.25")
  let (_, edited_yaw) = update(_ => @rabbita.none, UpdateWalkYaw("-0.10"), edited_x)
  inspect(edited_yaw.walk_yaw, content="-0.10")
  let (_, edited_duration) = update(
    _ => @rabbita.none,
    UpdateWalkDuration("1500"),
    edited_yaw,
  )
  inspect(edited_duration.walk_duration_ms, content="1500")
  let (_, evaluating) = update(_ => @rabbita.none, EvaluateWalk, model)
  inspect(evaluating.evaluating, content="true")
  inspect(evaluating.intent_status, content="Evaluating walk intent")
  let (_, accepted) = update(
    _ => @rabbita.none,
    IntentEvaluated(Ok({
      message: "CollectDryRun: WaitingForDryRun receipt receipt-cockpit-walk",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    evaluating,
  )
  inspect(accepted.evaluating, content="false")
  inspect(accepted.loading, content="true")
  inspect(accepted.intent_status.contains("CollectDryRun"), content="true")
  let (_, collecting) = update(_ => @rabbita.none, CollectDryRun, accepted)
  inspect(collecting.collecting_dry_run, content="true")
  let (_, dry_run) = update(
    _ => @rabbita.none,
    DryRunCollected(Ok({
      message: "CollectDryRun: WaitingForDryRun dry run dry-run-cockpit",
      dry_run_receipt_id: "dry-run-cockpit",
      approval_id: "",
    })),
    collecting,
  )
  inspect(dry_run.collecting_dry_run, content="false")
  inspect(dry_run.dry_run_receipt_id, content="dry-run-cockpit")
  let (_, approving) = update(_ => @rabbita.none, ApproveWalk, dry_run)
  inspect(approving.approving, content="true")
  let (_, approved) = update(
    _ => @rabbita.none,
    ApprovalRecorded(Ok({
      message: "RequestApproval: WaitingForApproval approval approval-cockpit",
      dry_run_receipt_id: "dry-run-cockpit",
      approval_id: "approval-cockpit",
    })),
    approving,
  )
  inspect(approved.approving, content="false")
  inspect(approved.approval_id, content="approval-cockpit")
  let (_, executing) = update(_ => @rabbita.none, ExecuteWalk, approved)
  inspect(executing.executing, content="true")
  let (_, executed) = update(
    _ => @rabbita.none,
    ExecutionRecorded(Ok({
      message: "Accepted: Executed receipt receipt-cockpit-walk-executed",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    executing,
  )
  inspect(executed.executing, content="false")
  inspect(executed.intent_status.contains("Executed"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    IntentEvaluated(Err("parse-intent-submission: bad input")),
    accepted,
  )
  inspect(rejected.evaluating, content="false")
  inspect(rejected.intent_status.contains("Intent rejected"), content="true")
}

///|
test "update tracks observation run lifecycle" {
  let model = init_model()
  let (_, task_id) = update(
    _ => @rabbita.none,
    UpdateObservationTaskId("inspection-pass-cockpit"),
    model,
  )
  inspect(task_id.observation_task_id, content="inspection-pass-cockpit")
  let (_, frame_count) = update(
    _ => @rabbita.none,
    UpdateObservationFrameCount("5"),
    task_id,
  )
  inspect(frame_count.observation_frame_count, content="5")
  let (_, running) = update(_ => @rabbita.none, RunObservation, frame_count)
  inspect(running.running_observation, content="true")
  inspect(running.observation_status, content="Running observation pipeline")
  let (_, completed) = update(
    _ => @rabbita.none,
    ObservationRunCompleted(Ok({
      message: "Stopped: 5 frames in task-inspection-pass-cockpit-observe",
      session_id: "task-inspection-pass-cockpit-observe",
      status: "Stopped",
      frame_count: "5",
      latest_frame_id: "sdk-task-inspection-pass-cockpit-observe-4",
      resident_availability: "bridge-missing",
    })),
    running,
  )
  inspect(completed.running_observation, content="false")
  inspect(completed.loading, content="true")
  inspect(completed.observation_status.contains("Stopped"), content="true")
  inspect(completed.latest_observation_run is Some(_), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    ObservationRunCompleted(Err("robot profile missing")),
    completed,
  )
  inspect(rejected.running_observation, content="false")
  inspect(
    rejected.observation_status.contains("Observation run rejected"),
    content="true",
  )
}

///|
test "update tracks MoonClaw process plan lifecycle" {
  let model = init_model()
  let (_, refreshing) = update(_ => @rabbita.none, RefreshProcessPlan, model)
  inspect(refreshing.refreshing_process_plan, content="true")
  inspect(refreshing.process_status, content="Refreshing process plan")
  let (_, loaded) = update(
    _ => @rabbita.none,
    ProcessPlanLoaded(Ok({
      action: "ReviewEvidence",
      summary: "Review process evidence before scheduling another robot task",
      run_id: "-",
      record_path: "-",
      evidence_route: "-",
      review_count: "1",
      needs_human_count: "1",
      latest_review_id: "review-cockpit",
      latest_review_summary: "needs review",
      replay_route: "-",
      replay_frame_count: "-",
      review_path: "-",
      first_step_label: "Open review queue",
      first_step_route: "/api/reviews",
    })),
    refreshing,
  )
  inspect(loaded.refreshing_process_plan, content="false")
  inspect(loaded.process_status.contains("Review process evidence"), content="true")
  inspect(loaded.latest_process_plan is Some(_), content="true")
  let (_, accepting) = update(_ => @rabbita.none, AcceptLatestReview, loaded)
  inspect(accepting.resolving_review, content="true")
  inspect(accepting.process_status.contains("review-cockpit"), content="true")
  let (_, accepted) = update(
    _ => @rabbita.none,
    ReviewAccepted(Ok({
      message: "Accepted: review-cockpit Review accepted",
      dry_run_receipt_id: "",
      approval_id: "",
    })),
    accepting,
  )
  inspect(accepted.resolving_review, content="false")
  inspect(accepted.process_status.contains("Accepted"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    ProcessPlanLoaded(Err("context unavailable")),
    loaded,
  )
  inspect(rejected.refreshing_process_plan, content="false")
  inspect(
    rejected.process_status.contains("Process plan rejected"),
    content="true",
  )
}

///|
test "update tracks MoonClaw run-next lifecycle" {
  let model = init_model()
  let (_, running) = update(_ => @rabbita.none, RunNextProcess, model)
  inspect(running.running_next_process, content="true")
  inspect(running.process_status, content="Running next process")
  let (_, completed) = update(
    _ => @rabbita.none,
    NextProcessCompleted(Ok({
      action: "Observe",
      summary: "Observed: Observation process completed",
      run_id: "agent-process-cockpit-run-1",
      record_path: "/tmp/agent-process-cockpit-run-1.json",
      evidence_route: "/api/moonclaw/runs/agent-process-cockpit-run-1",
      review_count: "1",
      needs_human_count: "0",
      latest_review_id: "review-cockpit-run",
      latest_review_summary: "accepted",
      replay_route: "/api/replays/task-cockpit-run-observe",
      replay_frame_count: "3",
      review_path: "/tmp/review-cockpit-run.json",
      first_step_label: "Run bounded observation",
      first_step_route: "/api/moontown/tasks/observe-run",
    })),
    running,
  )
  inspect(completed.running_next_process, content="false")
  inspect(completed.loading, content="true")
  inspect(completed.process_status.contains("Observed"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    NextProcessCompleted(Err("process unavailable")),
    completed,
  )
  inspect(rejected.running_next_process, content="false")
  inspect(rejected.process_status.contains("Next process rejected"), content="true")
}

///|
test "MoonClaw context parser extracts action and review pressure" {
  let fixture = #|{
                #|  "result": {
                #|    "context": {
                #|      "review_count": 1,
                #|      "needs_human_count": 1,
                #|      "latest_review": {
                #|        "review_id": "review-task-observe",
                #|        "summary": "needs review"
                #|      }
                #|    },
                #|    "plan": {
                #|      "action": "ReviewEvidence",
                #|      "summary": "Review process evidence before scheduling another robot task",
                #|      "steps": [
                #|        {
                #|          "label": "Open review queue",
                #|          "route": "/api/reviews",
                #|          "reason": "Process reviews may include linked artifacts"
                #|        }
                #|      ]
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse MoonClaw context fixture")
  }
  let parsed = parse_moonclaw_context_payload(json).unwrap()
  inspect(parsed.action, content="ReviewEvidence")
  inspect(parsed.review_count, content="1")
  inspect(parsed.needs_human_count, content="1")
  inspect(parsed.latest_review_id, content="review-task-observe")
  inspect(parsed.first_step_route, content="/api/reviews")
}

///|
test "MoonClaw run-next parser extracts outcome and planning data" {
  let fixture = #|{
                #|  "run_id": "agent-process-cockpit-run-next-1000",
                #|  "record_path": "/tmp/agent-process-cockpit-run-next-1000.json",
                #|  "result": {
                #|    "outcome": "Observed",
                #|    "message": "Observation process completed: task-cockpit-observe",
                #|    "observation_run": {
                #|      "plan": {
                #|        "session_id": "task-cockpit-observe"
                #|      },
                #|      "replay": {
                #|        "telemetry_frame_count": 4
                #|      },
                #|      "review": {
                #|        "review_id": "review-task-cockpit-observe",
                #|        "summary": "accepted"
                #|      },
                #|      "review_path": "/tmp/review-task-cockpit-observe.json"
                #|    },
                #|    "planning": {
                #|      "context": {
                #|        "review_count": 0,
                #|        "needs_human_count": 0
                #|      },
                #|      "plan": {
                #|        "action": "Observe",
                #|        "steps": [
                #|          {
                #|            "label": "Run bounded observation",
                #|            "route": "/api/moontown/tasks/observe-run"
                #|          }
                #|        ]
                #|      }
                #|    }
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse MoonClaw run-next fixture")
  }
  let parsed = parse_moonclaw_run_next_payload(json).unwrap()
  inspect(parsed.action, content="Observe")
  inspect(parsed.summary.contains("Observed"), content="true")
  inspect(parsed.run_id, content="agent-process-cockpit-run-next-1000")
  inspect(parsed.record_path.contains("agent-process-cockpit"), content="true")
  inspect(parsed.review_count, content="0")
  inspect(parsed.first_step_label, content="Run bounded observation")
  inspect(
    parsed.evidence_route,
    content="/api/moonclaw/runs/agent-process-cockpit-run-next-1000",
  )
  inspect(parsed.replay_route, content="/api/replays/task-cockpit-observe")
  inspect(parsed.replay_frame_count, content="4")
  inspect(parsed.latest_review_id, content="review-task-cockpit-observe")
  inspect(parsed.review_path, content="/tmp/review-task-cockpit-observe.json")
}

///|
test "Moonstat parser extracts policy ledger fields" {
  let fixture = #|{
                #|  "service": "moonrobo",
                #|  "robotbook_root": "examples/noetix-e1",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "ready": true,
                #|  "status": "degraded",
                #|  "bridge_state": "missing-command",
                #|  "availability": "idle",
                #|  "safety_state": "waiting-for-dry-run",
                #|  "receipt_count": 3,
                #|  "observation_count": 1,
                #|  "process_review_count": 0,
                #|  "policy_evaluation_count": 2,
                #|  "pending_review_count": 0,
                #|  "agent_process_run_count": 1,
                #|  "latest_run_id": "agent-process-cockpit",
                #|  "latest_session_id": "session-cockpit",
                #|  "latest_review_id": "-",
                #|  "latest_policy_evaluation_id": "policy-eval-cockpit",
                #|  "latest_policy_gate_status": "requires-dry-run",
                #|  "latest_policy_path": "/api/policies/evaluations/policy-eval-cockpit",
                #|  "latest_replay_path": "/api/replays/session-cockpit",
                #|  "latest_evidence_path": "/api/moonclaw/runs/agent-process-cockpit",
                #|  "generated_at_ms": "42"
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse Moonstat fixture")
  }
  let parsed = parse_moonstat_payload(json).unwrap()
  inspect(parsed.policy_evaluation_count, content="2")
  inspect(parsed.latest_policy_evaluation_id, content="policy-eval-cockpit")
  inspect(parsed.latest_policy_gate_status, content="requires-dry-run")
}

///|
test "work queue parser extracts next item" {
  let fixture = #|{
                #|  "queue_id": "work-queue-noetix-e1-lab-01-0",
                #|  "robot_id": "noetix-e1-lab-01",
                #|  "resident_id": "robot:noetix-e1-lab-01",
                #|  "generated_at_ms": "0",
                #|  "item_count": 1,
                #|  "high_priority_count": 1,
                #|  "next_item": {
                #|    "work_id": "work-noetix-e1-lab-01-connect-bridge",
                #|    "kind": "connect-bridge",
                #|    "priority": 100,
                #|    "title": "Connect robot bridge",
                #|    "summary": "Robot resident cannot launch its bridge command",
                #|    "target_id": "noetix-e1-lab-01",
                #|    "target_path": "/api/bridge/sidecar",
                #|    "reason": "Physical-world agents need read-only bridge health"
                #|  },
                #|  "items": [
                #|    {
                #|      "work_id": "work-noetix-e1-lab-01-connect-bridge",
                #|      "kind": "connect-bridge",
                #|      "priority": 100,
                #|      "title": "Connect robot bridge",
                #|      "summary": "Robot resident cannot launch its bridge command",
                #|      "target_id": "noetix-e1-lab-01",
                #|      "target_path": "/api/bridge/sidecar",
                #|      "reason": "Physical-world agents need read-only bridge health"
                #|    }
                #|  ]
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse work queue fixture")
  }
  let parsed = parse_work_queue_payload(json).unwrap()
  inspect(parsed.item_count, content="1")
  inspect(parsed.next_item is Some({ kind: "connect-bridge", .. }), content="true")
}

///|
test "review resolution parser accepts resolved review payload" {
  let fixture = #|{
                #|  "persisted": true,
                #|  "review": {
                #|    "review_id": "review-cockpit",
                #|    "disposition": "Accepted",
                #|    "summary": "Review accepted: cockpit accepted review evidence"
                #|  }
                #|}
  let json = @json.parse(fixture) catch {
    _ => fail("failed to parse review resolution fixture")
  }
  let parsed = parse_review_resolution_payload(json).unwrap()
  inspect(parsed.message.contains("Accepted: review-cockpit"), content="true")
  inspect(parsed.message.contains("cockpit accepted"), content="true")
}

///|
test "walk intent body uses editable command parameters" {
  let model = {
    ..init_model(),
    walk_x: "0.25",
    walk_yaw: "-0.10",
    walk_duration_ms: "1500",
    dry_run_receipt_id: "dry-run-body",
    approval_id: "approval-body",
  }
  let text = walk_intent_body(model).stringify()
  inspect(text.contains("\"x\":\"0.25\""), content="true")
  inspect(text.contains("\"yaw\":\"-0.10\""), content="true")
  inspect(text.contains("\"duration_ms\":\"1500\""), content="true")
  inspect(text.contains("\"dry_run_receipt_id\":\"dry-run-body\""), content="true")
  inspect(text.contains("\"approval_id\":\"approval-body\""), content="true")
}

///|
test "observation run body uses bounded task parameters" {
  let model = {
    ..init_model(),
    observation_task_id: "inspection-pass-cockpit",
    observation_frame_count: "5",
  }
  let text = observation_run_body(model).stringify()
  inspect(text.contains("\"task_id\":\"inspection-pass-cockpit\""), content="true")
  inspect(text.contains("\"robot_id\":\"noetix-e1-lab-01\""), content="true")
  inspect(text.contains("\"frame_count\":5"), content="true")
  let clamped = { ..model, observation_frame_count: "50" }
  inspect(
    observation_run_body(clamped).stringify().contains("\"frame_count\":20"),
    content="true",
  )
}

///|
test "MoonClaw run-next body uses bounded task parameters" {
  let model = {
    ..init_model(),
    observation_task_id: "moonclaw-cockpit-next",
    observation_frame_count: "4",
  }
  let text = moonclaw_run_next_body(model).stringify()
  inspect(text.contains("\"task_id\":\"moonclaw-cockpit-next\""), content="true")
  inspect(text.contains("\"frame_count\":4"), content="true")
  let clamped = { ..model, observation_frame_count: "0" }
  inspect(
    moonclaw_run_next_body(clamped).stringify().contains("\"frame_count\":1"),
    content="true",
  )
}

///|
test "review resolution body records operator note and capture time" {
  let text = review_resolution_body(init_model()).stringify()
  inspect(text.contains("\"note\":\"cockpit accepted review evidence\""), content="true")
  inspect(text.contains("\"resolved_at_ms\":\"0\""), content="true")
}

///|
#warnings("-alert_unstable")
test "rendered cockpit includes safety and receipt signals" {
  let page = @rabbita.simple_cell(
    model=init_model(),
    update=(_ : Msg, model) => model,
    view=(dispatch, model) => render_app(dispatch, model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("Moonrobo Cockpit"), content="true")
  inspect(html.contains("Safety Gate"), content="true")
  inspect(html.contains("moonrobo-sdk-e1-bridge"), content="true")
  inspect(html.contains("missing-command"), content="true")
  inspect(html.contains("Evaluate Walk"), content="true")
  inspect(html.contains("Collect Dry Run"), content="true")
  inspect(html.contains("Approve"), content="true")
  inspect(html.contains("Execute"), content="true")
  inspect(html.contains("Duration ms"), content="true")
  inspect(html.contains("Observation Run"), content="true")
  inspect(html.contains("Run Observation"), content="true")
  inspect(html.contains("Next Process"), content="true")
  inspect(html.contains("Suite Status"), content="true")
  inspect(html.contains("Agent Queue"), content="true")
  inspect(html.contains("Connect robot bridge"), content="true")
  inspect(html.contains("/api/bridge/sidecar"), content="true")
  inspect(html.contains("Policy Evals"), content="true")
  inspect(html.contains("Run Next"), content="true")
  inspect(html.contains("Refresh Plan"), content="true")
  inspect(html.contains("Accept Review"), content="true")
  inspect(html.contains("Run ID"), content="true")
  inspect(html.contains("Record"), content="true")
  inspect(html.contains("Evidence"), content="true")
  inspect(html.contains("Replay Frames"), content="true")
  inspect(html.contains("Review Path"), content="true")
  inspect(html.contains("No process plan loaded"), content="true")
  inspect(html.contains("standing-goal-cockpit"), content="true")
  inspect(html.contains("0.10"), content="true")
  inspect(html.contains("No command submitted"), content="true")
  inspect(html.contains("No observation run submitted"), content="true")
  inspect(html.contains("receipt-cli-plan-walk"), content="true")
  inspect(html.contains("Refresh"), content="true")
}
