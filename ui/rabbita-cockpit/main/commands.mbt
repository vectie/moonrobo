///|
using @rabbita {type Cmd}

///|
fn parse_snapshot_payload(
  json : Json,
) -> Result[@cockpit.CockpitSnapshot, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid cockpit snapshot: \{error}")
  }
}

///|
fn fetch_snapshot(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, @cockpit.CockpitSnapshot] = Json(
    fn(result) { dispatch(SnapshotLoaded(result)) },
    parse_snapshot_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_moonstat_payload(
  json : Json,
) -> Result[@moonstat.MoonroboStatus, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid Moonstat status: \{error}")
  }
}

///|
fn fetch_moonstat_status(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, @moonstat.MoonroboStatus] = Json(
    fn(result) { dispatch(MoonstatLoaded(result)) },
    parse_moonstat_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_runtime_supervisor_payload(
  json : Json,
) -> Result[RuntimeSupervisorStatus, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid runtime supervisor status: \{error}")
  }
}

///|
fn fetch_runtime_supervisor_status(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeSupervisorStatus] = Json(
    fn(result) { dispatch(RuntimeSupervisorLoaded(result)) },
    parse_runtime_supervisor_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_runtime_health_payload(json : Json) -> Result[RuntimeHealthResult, String] {
  match json {
    {
      "persisted": persisted,
      "runtime_health_path": String(runtime_health_path),
      "latest_runtime_health_path": String(latest_runtime_health_path),
      "record": {
        "status": String(status),
        "telemetry_ok": telemetry_ok,
        "telemetry_status": String(telemetry_status),
        "telemetry_message": String(telemetry_message),
        "telemetry_frame_id": String(telemetry_frame_id),
        ..
      },
      ..
    } =>
      Ok({
        status,
        persisted: persisted.stringify(),
        runtime_health_path,
        latest_runtime_health_path,
        telemetry_ok: telemetry_ok.stringify(),
        telemetry_status,
        telemetry_message,
        telemetry_frame_id,
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime health response")
  }
}

///|
fn fetch_runtime_health(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeHealthResult] = Json(
    fn(result) { dispatch(RuntimeHealthLoaded(result)) },
    parse_runtime_health_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_runtime_log_payload(json : Json) -> Result[RuntimeLogResult, String] {
  match json {
    {
      "active": active,
      "running": running,
      "status": String(status),
      "log_path": String(log_path),
      "exists": exists,
      "truncated": truncated,
      "line_count": line_count,
      "max_lines": max_lines,
      "tail": String(tail),
      ..
    } =>
      Ok({
        active: active.stringify(),
        running: running.stringify(),
        status,
        log_path,
        exists: exists.stringify(),
        truncated: truncated.stringify(),
        line_count: line_count.stringify(),
        max_lines: max_lines.stringify(),
        tail,
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime log response")
  }
}

///|
fn fetch_runtime_log(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeLogResult] = Json(
    fn(result) { dispatch(RuntimeLogLoaded(result)) },
    parse_runtime_log_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_runtime_validation_payload(
  json : Json,
) -> Result[RuntimeValidationResult, String] {
  match json {
    {
      "persisted": persisted,
      "report_path": String(report_path),
      "latest_report_path": String(latest_report_path),
      "report": {
        "status": String(status),
        "ready_for_live_sdk": ready_for_live_sdk,
        "pass_count": pass_count,
        "fail_count": fail_count,
        "check_count": check_count,
        ..
      },
      ..
    } =>
      Ok({
        status,
        ready_for_live_sdk: ready_for_live_sdk.stringify(),
        persisted: persisted.stringify(),
        report_path,
        latest_report_path,
        pass_count: pass_count.stringify(),
        fail_count: fail_count.stringify(),
        check_count: check_count.stringify(),
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime validation response")
  }
}

///|
fn fetch_runtime_validation(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeValidationResult] = Json(
    fn(result) { dispatch(RuntimeValidationLoaded(result)) },
    parse_runtime_validation_payload,
  )
  @http.get(url, expect~)
}

///|
struct PlatformReadinessResult {
  report : @readiness.PlatformReadinessReport
  plan : @readiness.PlatformReadinessPlan?
}

///|
fn parse_platform_readiness_payload(
  json : Json,
) -> Result[PlatformReadinessResult, String] {
  match json {
    { "report": report_json, "plan": plan_json, .. } => {
      let report : @readiness.PlatformReadinessReport = @json.from_json(
        report_json,
      ) catch {
        error => return Err("Invalid platform readiness report: \{error}")
      }
      let plan : @readiness.PlatformReadinessPlan = @json.from_json(plan_json) catch {
        error => return Err("Invalid platform readiness plan: \{error}")
      }
      Ok({ report, plan: Some(plan) })
    }
    { "report": report, .. } =>
      Ok({ report: @json.from_json(report), plan: None }) catch {
        error => Err("Invalid platform readiness report: \{error}")
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform readiness response")
  }
}

///|
fn fetch_platform_readiness(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, PlatformReadinessResult] = Json(
    fn(result) { dispatch(PlatformReadinessLoaded(result)) },
    parse_platform_readiness_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_platform_bootstrap_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "after": {
        "status": String(status),
        "pass_count": pass_count,
        "fail_count": fail_count,
        ..
      },
      "steps": Array(steps),
      ..
    } =>
      Ok(
        command_result(
          "Platform bootstrap \{status}; \{pass_count.stringify()} pass / \{fail_count.stringify()} fail; \{steps.length()} step(s)",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform bootstrap response")
  }
}

///|
fn submit_platform_bootstrap(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(PlatformBootstrapped(result)) },
    parse_platform_bootstrap_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_runtime_launch_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "script_path": String(script_path),
      "receipt_path": String(receipt_path),
      "receipt": { "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "Runtime launch \{status}: \{script_path} receipt \{receipt_path}",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime launch response")
  }
}

///|
fn submit_runtime_launch(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(RuntimeLaunchPrepared(result)) },
    parse_runtime_launch_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_runtime_start_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "pid": pid,
      "status": String(status),
      "script_path": String(script_path),
      ..
    } =>
      Ok(command_result("Runtime \{status}: pid \{pid.stringify()} \{script_path}"))
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime start response")
  }
}

///|
fn submit_runtime_start(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(RuntimeStarted(result)) },
    parse_runtime_start_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_runtime_stop_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "pid": pid,
      "status": String(status),
      "stopped": stopped,
      ..
    } =>
      Ok(
        command_result(
          "Runtime stop \{status}: pid \{pid.stringify()} stopped \{stopped.stringify()}",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime stop response")
  }
}

///|
fn submit_runtime_stop(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(RuntimeStopped(result)) },
    parse_runtime_stop_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_runtime_emergency_stop_payload(
  json : Json,
) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "event": { "request_id": String(request_id), .. },
      "receipt_path": String(receipt_path),
      "dispatch_path": String(dispatch_path),
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "Emergency stop \{status}: request \{request_id} receipt \{receipt_id} evidence \{receipt_path} dispatch \{dispatch_path}",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime emergency stop response")
  }
}

///|
fn submit_runtime_emergency_stop(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(RuntimeEmergencyStopped(result)) },
    parse_runtime_emergency_stop_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_next_action_payload(
  json : Json,
) -> Result[@work_queue.AgentNextActionPlan, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid next action plan: \{error}")
  }
}

///|
fn fetch_next_action(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, @work_queue.AgentNextActionPlan] = Json(
    fn(result) { dispatch(NextActionLoaded(result)) },
    parse_next_action_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_agent_dispatch_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "dispatched": true,
      "action": { "kind": String(kind), "route": String(route), .. },
      "downstream_status": status,
      ..
    } =>
      Ok(command_result("Dispatched \{kind} through \{route} (\{status.stringify()})"))
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid agent dispatch response")
  }
}

///|
fn agent_dispatch_body(action : @work_queue.AgentNextAction?) -> Json {
  match action {
    Some(value) => { "work_id": value.work_id }
    None => {}
  }
}

///|
fn submit_agent_dispatch(
  dispatch : (Msg) -> Cmd,
  url : String,
  action : @work_queue.AgentNextAction?,
) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(NextActionDispatched(result)) },
    parse_agent_dispatch_payload,
  )
  @http.post(url, Json(agent_dispatch_body(action)), expect~)
}

///|
fn task_message_review_result(
  task_id : String,
  classification : String,
  route : String,
  reason : String,
  physical_execution_allowed : String,
  requires_review : String,
  suggested_capability : String,
  goal : String,
  intent_draft : ReviewedIntentDraft?,
) -> TaskMessageReviewResult {
  {
    message: "Loaded task-message review \{task_id} (\{classification})",
    task_id,
    classification,
    route,
    reason,
    physical_execution_allowed,
    requires_review,
    suggested_capability,
    goal,
    intent_draft,
  }
}

///|
fn parse_task_message_review_payload(
  json : Json,
) -> Result[TaskMessageReviewResult, String] {
  match json {
    {
      "plan": {
        "task": {
          "task_id": String(task_id),
          "robot_id": String(robot_id),
          "requested_by": requester,
          "goal": String(goal),
          "now_ms": now_ms,
          ..
        },
        "classification": String(classification),
        "route": String(route),
        "reason": String(reason),
        "physical_execution_allowed": physical_execution_allowed,
        "requires_review": requires_review,
        "suggested_capability": String(suggested_capability),
        "intent_draft": {
          "intent_id": String(intent_id),
          "receipt_id": String(receipt_id),
          "capability": String(capability),
          "parameters": parameters,
          "telemetry_age_ms": telemetry_age_ms,
          "developer_gate": developer_gate,
          ..
        },
        ..
      },
      ..
    } =>
      Ok(
        task_message_review_result(
          task_id,
          classification,
          route,
          reason,
          physical_execution_allowed.stringify(),
          requires_review.stringify(),
          suggested_capability,
          goal,
          Some({
            intent_id,
            robot_id,
            capability,
            parameters,
            requester,
            receipt_id,
            now_ms,
            telemetry_age_ms,
            developer_gate,
          }),
        ),
      )
    {
      "plan": {
        "task": { "task_id": String(task_id), "goal": String(goal), .. },
        "classification": String(classification),
        "route": String(route),
        "reason": String(reason),
        "physical_execution_allowed": physical_execution_allowed,
        "requires_review": requires_review,
        "suggested_capability": String(suggested_capability),
        ..
      },
      ..
    } =>
      Ok(
        task_message_review_result(
          task_id,
          classification,
          route,
          reason,
          physical_execution_allowed.stringify(),
          requires_review.stringify(),
          suggested_capability,
          goal,
          None,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message review response")
  }
}

///|
fn fetch_task_message_review(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskMessageReviewResult] = Json(
    fn(result) { dispatch(TaskMessageReviewLoaded(result)) },
    parse_task_message_review_payload,
  )
  @http.get(url, expect~)
}

///|
fn task_message_status_result(
  task_id : String,
  stage : String,
  summary : String,
  next_route : String,
  runtime_status : String,
  receipt_status : String,
  bridge_status : String,
  evaluated : String,
  dry_run_collected : String,
  approved : String,
  executed : String,
  runtime_required : String,
) -> TaskMessageStatusResult {
  {
    message: "\{stage}: \{summary}",
    task_id,
    stage,
    summary,
    next_route,
    runtime_status,
    receipt_status,
    bridge_status,
    evaluated,
    dry_run_collected,
    approved,
    executed,
    runtime_required,
  }
}

///|
fn parse_task_message_status_payload(
  json : Json,
) -> Result[TaskMessageStatusResult, String] {
  match json {
    {
      "status": {
        "task_id": String(task_id),
        "stage": String(stage),
        "summary": String(summary),
        "next_route": String(next_route),
        "runtime_status": String(runtime_status),
        "receipt_status": String(receipt_status),
        "bridge_status": String(bridge_status),
        "evaluated": evaluated,
        "dry_run_collected": dry_run_collected,
        "approved": approved,
        "executed": executed,
        "runtime_required": runtime_required,
        ..
      },
      ..
    } =>
      Ok(
        task_message_status_result(
          task_id,
          stage,
          summary,
          next_route,
          runtime_status,
          receipt_status,
          bridge_status,
          evaluated.stringify(),
          dry_run_collected.stringify(),
          approved.stringify(),
          executed.stringify(),
          runtime_required.stringify(),
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message status response")
  }
}

///|
fn fetch_task_message_status(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskMessageStatusResult] = Json(
    fn(result) { dispatch(TaskMessageStatusLoaded(result)) },
    parse_task_message_status_payload,
  )
  @http.get(url, expect~)
}

///|
fn command_result(
  message : String,
  dry_run_receipt_id? : String = "",
  approval_id? : String = "",
) -> CommandResult {
  { message, dry_run_receipt_id, approval_id }
}

///|
fn parse_intent_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "result": {
        "next_action": String(next_action),
        "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok(command_result("\{next_action}: \{status} receipt \{receipt_id}"))
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid intent evaluation response")
  }
}

///|
fn parse_dry_run_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "dry_run": { "dry_run_receipt_id": String(dry_run_receipt_id), .. },
      "result": {
        "next_action": String(next_action),
        "receipt": { "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "\{next_action}: \{status} dry run \{dry_run_receipt_id}",
          dry_run_receipt_id~,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid dry-run response")
  }
}

///|
fn parse_approval_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "approval": {
        "approval_id": String(approval_id),
        "dry_run_receipt_id": String(dry_run_receipt_id),
        ..
      },
      "result": {
        "next_action": String(next_action),
        "receipt": { "status": String(status), .. },
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "\{next_action}: \{status} approval \{approval_id}",
          dry_run_receipt_id~,
          approval_id~,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid approval response")
  }
}

///|
fn parse_execution_result_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "execution_snapshot_path": String(snapshot_path),
      "memory": { "memory_path": String(memory_path), .. },
      "runtime_health": { "runtime_health_path": String(runtime_health_path), .. },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "\{bridge_status}: \{status} receipt \{receipt_id} memory \{memory_path} health \{runtime_health_path} snapshot \{snapshot_path}",
        ),
      )
    {
      "persisted": true,
      "execution_snapshot_path": String(snapshot_path),
      "memory": { "memory_path": String(memory_path), .. },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "\{bridge_status}: \{status} receipt \{receipt_id} memory \{memory_path} snapshot \{snapshot_path}",
        ),
      )
    {
      "persisted": true,
      "memory": { "memory_path": String(memory_path), .. },
      "runtime_health": { "runtime_health_path": String(runtime_health_path), .. },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "\{bridge_status}: \{status} receipt \{receipt_id} memory \{memory_path} health \{runtime_health_path}",
        ),
      )
    {
      "persisted": true,
      "memory": { "memory_path": String(memory_path), .. },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(
        command_result(
          "\{bridge_status}: \{status} receipt \{receipt_id} memory \{memory_path}",
        ),
      )
    {
      "persisted": true,
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": { "receipt_id": String(receipt_id), "status": String(status), .. },
      ..
    } =>
      Ok(command_result("\{bridge_status}: \{status} receipt \{receipt_id}"))
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid execution response")
  }
}

///|
fn parse_review_resolution_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "review": {
        "review_id": String(review_id),
        "disposition": String(disposition),
        "summary": String(summary),
        ..
      },
      ..
    } =>
      Ok(command_result("\{disposition}: \{review_id} \{summary}"))
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid review resolution response")
  }
}

///|
fn observation_result(
  session_id : String,
  status : String,
  frame_count : String,
  latest_frame_id : String,
  resident_availability : String,
) -> ObservationRunResult {
  {
    message: "\{status}: \{frame_count} frames in \{session_id}",
    session_id,
    status,
    frame_count,
    latest_frame_id,
    resident_availability,
  }
}

///|
fn task_message_result(
  task_id : String,
  session_id : String,
  classification : String,
  next_route : String,
  requires_review : String,
  memory_path : String,
  card_count : String,
  resident_availability : String,
) -> TaskMessageResult {
  {
    message: if session_id == "-" {
      "Accepted \{task_id}; \{classification} via \{next_route}; remembered \{card_count} card(s)"
    } else {
      "Accepted \{task_id}; observing \{session_id}; remembered \{card_count} card(s)"
    },
    task_id,
    session_id,
    classification,
    next_route,
    requires_review,
    memory_path,
    card_count,
    resident_availability,
  }
}

///|
fn moonclaw_plan_result(
  action : String,
  summary : String,
  review_count : String,
  needs_human_count : String,
  run_id? : String = "-",
  record_path? : String = "-",
  evidence_route? : String = "-",
  latest_review_id? : String = "-",
  latest_review_summary? : String = "No review evidence queued",
  replay_route? : String = "-",
  replay_frame_count? : String = "-",
  review_path? : String = "-",
  first_step_label? : String = "-",
  first_step_route? : String = "-",
) -> MoonClawPlanResult {
  {
    action,
    summary,
    run_id,
    record_path,
    evidence_route,
    review_count,
    needs_human_count,
    latest_review_id,
    latest_review_summary,
    replay_route,
    replay_frame_count,
    review_path,
    first_step_label,
    first_step_route,
  }
}

///|
fn parse_first_step(steps : Json) -> (String, String) {
  match steps {
    [{ "label": String(label), "route": String(route), .. }, ..] =>
      (label, route)
    _ => ("-", "-")
  }
}

///|
fn parse_observation_run_payload(
  json : Json,
) -> Result[ObservationRunResult, String] {
  match json {
    {
      "persisted": true,
      "plan": { "session_id": String(session_id), .. },
      "replay": {
        "status": String(status),
        "telemetry_frame_count": frame_count,
        "latest_frame_id": String(latest_frame_id),
        ..
      },
      "resident": { "availability": String(availability), .. },
      ..
    } =>
      Ok(
        observation_result(
          session_id,
          status,
          frame_count.stringify(),
          latest_frame_id,
          availability,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid observation run response")
  }
}

///|
fn parse_task_message_payload(json : Json) -> Result[TaskMessageResult, String] {
  match json {
    {
      "persisted": true,
      "message_plan": {
        "task": { "task_id": String(task_id), .. },
        "classification": String(classification),
        "route": String(route),
        "requires_review": requires_review,
        ..
      },
      "plan": { "session_id": String(session_id), .. },
      "resident": { "availability": String(availability), .. },
      "memory": {
        "memory_path": String(memory_path),
        "pack": { "card_count": card_count, .. },
        ..
      },
      ..
    } =>
      Ok(
        task_message_result(
          task_id,
          session_id,
          classification,
          route,
          requires_review.stringify(),
          memory_path,
          card_count.stringify(),
          availability,
        ),
      )
    {
      "persisted": true,
      "message_plan": {
        "task": { "task_id": String(task_id), .. },
        "classification": String(classification),
        "route": String(route),
        "requires_review": requires_review,
        ..
      },
      "resident": { "availability": String(availability), .. },
      "memory": {
        "memory_path": String(memory_path),
        "pack": { "card_count": card_count, .. },
        ..
      },
      ..
    } =>
      Ok(
        task_message_result(
          task_id,
          "-",
          classification,
          route,
          requires_review.stringify(),
          memory_path,
          card_count.stringify(),
          availability,
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task message response")
  }
}

///|
fn task_message_ledger_item(
  task_id : String,
  goal : String,
  classification : String,
  stage : String,
  route : String,
  next_route : String,
  evaluated : String,
  dry_run_collected : String,
  approved : String,
  executed : String,
  requires_review : String,
  physical_execution_allowed : String,
  message_path : String,
) -> TaskMessageLedgerItem {
  {
    task_id,
    goal,
    classification,
    stage,
    route,
    next_route,
    evaluated,
    dry_run_collected,
    approved,
    executed,
    requires_review,
    physical_execution_allowed,
    message_path,
  }
}

///|
fn parse_task_message_ledger_item(
  json : Json,
) -> Result[TaskMessageLedgerItem, String] {
  match json {
    {
      "message_path": String(message_path),
      "plan": {
        "task": {
          "task_id": String(task_id),
          "goal": String(goal),
          ..
        },
        "classification": String(classification),
        "route": String(route),
        "requires_review": requires_review,
        "physical_execution_allowed": physical_execution_allowed,
        ..
      },
      "status": {
        "stage": String(stage),
        "next_route": String(next_route),
        "evaluated": evaluated,
        "dry_run_collected": dry_run_collected,
        "approved": approved,
        "executed": executed,
        ..
      },
      ..
    } =>
      Ok(
        task_message_ledger_item(
          task_id,
          goal,
          classification,
          stage,
          route,
          next_route,
          evaluated.stringify(),
          dry_run_collected.stringify(),
          approved.stringify(),
          executed.stringify(),
          requires_review.stringify(),
          physical_execution_allowed.stringify(),
          message_path,
        ),
      )
    _ => Err("Invalid task-message ledger item")
  }
}

///|
fn parse_task_message_ledger_payload(
  json : Json,
) -> Result[TaskMessageLedgerResult, String] {
  match json {
    {
      "message_count": message_count,
      "messages": Array(message_json),
      ..
    } => {
      let messages : Array[TaskMessageLedgerItem] = []
      for item_json in message_json {
        match parse_task_message_ledger_item(item_json) {
          Ok(item) => messages.push(item)
          Err(error) => return Err(error)
        }
      }
      let count = message_count.stringify()
      Ok({
        message: "Loaded \{count} task message(s)",
        message_count: count,
        messages,
      })
    }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message ledger response")
  }
}

///|
fn fetch_task_messages(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskMessageLedgerResult] = Json(
    fn(result) { dispatch(TaskMessagesLoaded(result)) },
    parse_task_message_ledger_payload,
  )
  @http.get(url, expect~)
}

///|
fn task_conversation_turn(
  turn_id : String,
  task_id : String,
  created_at_ms : String,
  user_text : String,
  robo_text : String,
  classification : String,
  stage : String,
  next_route : String,
  requires_review : String,
  physical_execution_allowed : String,
) -> TaskConversationTurn {
  {
    turn_id,
    task_id,
    created_at_ms,
    user_text,
    robo_text,
    classification,
    stage,
    next_route,
    requires_review,
    physical_execution_allowed,
  }
}

///|
fn parse_task_conversation_turn(
  json : Json,
) -> Result[TaskConversationTurn, String] {
  match json {
    {
      "turn_id": String(turn_id),
      "task_id": String(task_id),
      "created_at_ms": created_at_ms,
      "user_text": String(user_text),
      "robo_text": String(robo_text),
      "classification": String(classification),
      "stage": String(stage),
      "next_route": String(next_route),
      "requires_review": requires_review,
      "physical_execution_allowed": physical_execution_allowed,
      ..
    } =>
      Ok(
        task_conversation_turn(
          turn_id,
          task_id,
          created_at_ms.stringify(),
          user_text,
          robo_text,
          classification,
          stage,
          next_route,
          requires_review.stringify(),
          physical_execution_allowed.stringify(),
        ),
      )
    _ => Err("Invalid task conversation turn")
  }
}

///|
fn parse_task_conversation_payload(
  json : Json,
) -> Result[TaskConversationResult, String] {
  match json {
    {
      "conversation": {
        "turn_count": turn_count,
        "latest_task_id": String(latest_task_id),
        "turns": Array(turn_json),
        ..
      },
      ..
    } => {
      let turns : Array[TaskConversationTurn] = []
      for item_json in turn_json {
        match parse_task_conversation_turn(item_json) {
          Ok(turn) => turns.push(turn)
          Err(error) => return Err(error)
        }
      }
      let count = turn_count.stringify()
      Ok({
        message: "Loaded \{count} Robo conversation turn(s)",
        turn_count: count,
        latest_task_id,
        turns,
      })
    }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task conversation response")
  }
}

///|
fn fetch_task_conversation(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskConversationResult] = Json(
    fn(result) { dispatch(TaskConversationLoaded(result)) },
    parse_task_conversation_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_moonclaw_context_payload(
  json : Json,
) -> Result[MoonClawPlanResult, String] {
  match json {
    {
      "result": {
        "context": {
          "review_count": review_count,
          "needs_human_count": needs_human_count,
          "latest_review": {
            "review_id": String(review_id),
            "summary": String(review_summary),
            ..
          },
          ..
        },
        "plan": {
          "action": String(action),
          "summary": String(summary),
          "steps": steps,
          ..
        },
        ..
      },
      ..
    } => {
      let (label, route) = parse_first_step(steps)
      Ok(
        moonclaw_plan_result(
          action,
          summary,
          review_count.stringify(),
          needs_human_count.stringify(),
          latest_review_id=review_id,
          latest_review_summary=review_summary,
          first_step_label=label,
          first_step_route=route,
        ),
      )
    }
    {
      "result": {
        "context": {
          "review_count": review_count,
          "needs_human_count": needs_human_count,
          ..
        },
        "plan": {
          "action": String(action),
          "summary": String(summary),
          "steps": steps,
          ..
        },
        ..
      },
      ..
    } => {
      let (label, route) = parse_first_step(steps)
      Ok(
        moonclaw_plan_result(
          action,
          summary,
          review_count.stringify(),
          needs_human_count.stringify(),
          first_step_label=label,
          first_step_route=route,
        ),
      )
    }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid MoonClaw context response")
  }
}

///|
fn parse_moonclaw_run_next_payload(
  json : Json,
) -> Result[MoonClawPlanResult, String] {
  match json {
    {
      "run_id": String(run_id),
      "record_path": String(record_path),
      "result": {
        "outcome": String(outcome),
        "message": String(message),
        "observation_run": {
          "plan": { "session_id": String(session_id), .. },
          "replay": { "telemetry_frame_count": replay_frame_count, .. },
          "review": {
            "review_id": String(review_id),
            "summary": String(review_summary),
            ..
          },
          "review_path": String(review_path),
          ..
        },
        "planning": {
          "context": {
            "review_count": review_count,
            "needs_human_count": needs_human_count,
            ..
          },
          "plan": {
            "action": String(action),
            "steps": steps,
            ..
          },
          ..
        },
        ..
      },
      ..
    } => {
      let (label, route) = parse_first_step(steps)
      Ok(
        moonclaw_plan_result(
          action,
          "\{outcome}: \{message}",
          review_count.stringify(),
          needs_human_count.stringify(),
          run_id~,
          record_path~,
          evidence_route="/api/moonclaw/runs/\{run_id}",
          latest_review_id=review_id,
          latest_review_summary=review_summary,
          replay_route="/api/replays/\{session_id}",
          replay_frame_count=replay_frame_count.stringify(),
          review_path~,
          first_step_label=label,
          first_step_route=route,
        ),
      )
    }
    {
      "run_id": String(run_id),
      "record_path": String(record_path),
      "result": {
        "outcome": String(outcome),
        "message": String(message),
        "planning": {
          "context": {
            "review_count": review_count,
            "needs_human_count": needs_human_count,
            "latest_review": {
              "review_id": String(review_id),
              "summary": String(review_summary),
              ..
            },
            ..
          },
          "plan": {
            "action": String(action),
            "steps": steps,
            ..
          },
          ..
        },
        ..
      },
      ..
    } => {
      let (label, route) = parse_first_step(steps)
      Ok(
        moonclaw_plan_result(
          action,
          "\{outcome}: \{message}",
          review_count.stringify(),
          needs_human_count.stringify(),
          run_id~,
          record_path~,
          latest_review_id=review_id,
          latest_review_summary=review_summary,
          first_step_label=label,
          first_step_route=route,
        ),
      )
    }
    {
      "run_id": String(run_id),
      "record_path": String(record_path),
      "result": {
        "outcome": String(outcome),
        "message": String(message),
        "planning": {
          "context": {
            "review_count": review_count,
            "needs_human_count": needs_human_count,
            ..
          },
          "plan": {
            "action": String(action),
            "steps": steps,
            ..
          },
          ..
        },
        ..
      },
      ..
    } => {
      let (label, route) = parse_first_step(steps)
      Ok(
        moonclaw_plan_result(
          action,
          "\{outcome}: \{message}",
          review_count.stringify(),
          needs_human_count.stringify(),
          run_id~,
          record_path~,
          first_step_label=label,
          first_step_route=route,
        ),
      )
    }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid MoonClaw run-next response")
  }
}

///|
fn walk_intent_body(
  model : AppModel,
  receipt_id? : String = "receipt-cockpit-walk",
) -> Json {
  let snapshot = model.snapshot
  {
    "intent_id": "intent-cockpit-walk",
    "robot_id": snapshot.robot.robot_id,
    "capability": "control.high.walk",
    "parameters": {
      "x": model.walk_x,
      "yaw": model.walk_yaw,
      "duration_ms": model.walk_duration_ms,
    },
    "requester": { "kind": "operator", "id": "cockpit" },
    "receipt_id": receipt_id,
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "approval_id": model.approval_id,
    "dry_run_receipt_id": model.dry_run_receipt_id,
    "developer_gate": false,
    "telemetry_age_ms": match snapshot.bridge.telemetry_age_ms {
      Some(age) => age
      None => -1
    },
  }
}

///|
fn reviewed_intent_body(
  draft : ReviewedIntentDraft,
  approval_id : String,
  dry_run_receipt_id : String,
  receipt_id : String,
) -> Json {
  {
    "intent_id": draft.intent_id,
    "robot_id": draft.robot_id,
    "capability": draft.capability,
    "parameters": draft.parameters,
    "requester": draft.requester,
    "receipt_id": receipt_id,
    "now_ms": draft.now_ms,
    "approval_id": approval_id,
    "dry_run_receipt_id": dry_run_receipt_id,
    "developer_gate": draft.developer_gate,
    "telemetry_age_ms": draft.telemetry_age_ms,
  }
}

///|
fn active_intent_body(
  model : AppModel,
  receipt_id? : String = "receipt-cockpit-walk",
) -> Json {
  match model.active_reviewed_intent {
    Some(draft) =>
      reviewed_intent_body(
        draft,
        model.approval_id,
        model.dry_run_receipt_id,
        receipt_id,
      )
    None => walk_intent_body(model, receipt_id~)
  }
}

///|
fn intent_submission_action(url : String) -> String {
  if url == default_dry_run_url() || url.has_suffix("/dry-run") {
    "dry-run"
  } else if url == default_approval_url() || url.has_suffix("/approve") {
    "approve"
  } else if url == default_execute_url() ||
    url.has_suffix("/execute") ||
    url.has_suffix("/execute-sidecar") {
    "execute"
  } else {
    "evaluate"
  }
}

///|
fn observation_frame_count(model : AppModel) -> Int {
  let parsed = @string.parse_int(model.observation_frame_count) catch {
    _ => 3
  }
  if parsed < 1 {
    1
  } else if parsed > 20 {
    20
  } else {
    parsed
  }
}

///|
fn observation_run_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "task_id": model.observation_task_id,
    "robot_id": snapshot.robot.robot_id,
    "requester": { "kind": "operator", "id": "cockpit" },
    "goal": "cockpit bounded observation run",
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "frame_count": observation_frame_count(model),
    "frame_interval_ms": "1",
  }
}

///|
fn task_message_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "message_id": "cockpit-\{snapshot.telemetry.captured_at_ms}",
    "robot_id": snapshot.robot.robot_id,
    "requested_by": { "kind": "operator", "id": "cockpit" },
    "message": model.task_message,
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
  }
}

///|
fn moonclaw_run_next_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "task_id": model.observation_task_id,
    "goal": "cockpit next MoonClaw process",
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "frame_count": observation_frame_count(model),
    "frame_interval_ms": "1",
  }
}

///|
fn review_resolution_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "note": "cockpit accepted review evidence",
    "resolved_at_ms": "\{snapshot.telemetry.captured_at_ms}",
  }
}

///|
fn submit_intent(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
  receipt_id? : String = "receipt-cockpit-walk",
) -> Cmd {
  match intent_submission_action(url) {
    "dry-run" => {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(DryRunCollected(result)) },
      parse_dry_run_result_payload,
    )
    @http.post(url, Json(active_intent_body(model, receipt_id~)), expect~)
    }
    "approve" => {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(ApprovalRecorded(result)) },
      parse_approval_result_payload,
    )
    @http.post(url, Json(active_intent_body(model, receipt_id~)), expect~)
    }
    "execute" => {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(ExecutionRecorded(result)) },
      parse_execution_result_payload,
    )
    @http.post(url, Json(active_intent_body(model, receipt_id~)), expect~)
    }
    _ => {
    let expect : @http.Expecting[Cmd, CommandResult] = Json(
      fn(result) { dispatch(IntentEvaluated(result)) },
      parse_intent_result_payload,
    )
    @http.post(url, Json(active_intent_body(model, receipt_id~)), expect~)
    }
  }
}

///|
fn submit_observation_run(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, ObservationRunResult] = Json(
    fn(result) { dispatch(ObservationRunCompleted(result)) },
    parse_observation_run_payload,
  )
  @http.post(url, Json(observation_run_body(model)), expect~)
}

///|
fn submit_task_message(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskMessageResult] = Json(
    fn(result) { dispatch(TaskMessageSubmitted(result)) },
    parse_task_message_payload,
  )
  @http.post(url, Json(task_message_body(model)), expect~)
}

///|
fn fetch_moonclaw_context(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, MoonClawPlanResult] = Json(
    fn(result) { dispatch(ProcessPlanLoaded(result)) },
    parse_moonclaw_context_payload,
  )
  @http.get(url, expect~)
}

///|
fn submit_moonclaw_run_next(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, MoonClawPlanResult] = Json(
    fn(result) { dispatch(NextProcessCompleted(result)) },
    parse_moonclaw_run_next_payload,
  )
  @http.post(url, Json(moonclaw_run_next_body(model)), expect~)
}

///|
fn submit_review_resolution(
  dispatch : (Msg) -> Cmd,
  review_id : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(ReviewAccepted(result)) },
    parse_review_resolution_payload,
  )
  @http.post(
    "/api/reviews/\{review_id}/resolve",
    Json(review_resolution_body(model)),
    expect~,
  )
}
