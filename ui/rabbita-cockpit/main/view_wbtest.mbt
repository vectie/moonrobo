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
  let (_, failed) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Err("boom")),
    loaded,
  )
  inspect(failed.loading, content="false")
  inspect(failed.error is Some("boom"), content="true")
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
      review_count: "1",
      needs_human_count: "1",
      latest_review_id: "review-cockpit",
      latest_review_summary: "needs review",
      first_step_label: "Open review queue",
      first_step_route: "/api/reviews",
    })),
    refreshing,
  )
  inspect(loaded.refreshing_process_plan, content="false")
  inspect(loaded.process_status.contains("Review process evidence"), content="true")
  inspect(loaded.latest_process_plan is Some(_), content="true")
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
  inspect(html.contains("Refresh Plan"), content="true")
  inspect(html.contains("No process plan loaded"), content="true")
  inspect(html.contains("standing-goal-cockpit"), content="true")
  inspect(html.contains("0.10"), content="true")
  inspect(html.contains("No command submitted"), content="true")
  inspect(html.contains("No observation run submitted"), content="true")
  inspect(html.contains("receipt-cli-plan-walk"), content="true")
  inspect(html.contains("Refresh"), content="true")
}
