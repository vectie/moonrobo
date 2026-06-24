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
fn task_execution_proof_result(
  execution_count : Json,
  verified_count : Json,
  latest_snapshot_id : String,
  latest_status : String,
  latest_task_id : String,
  latest_bridge_status : String,
  latest_runtime_status : String,
  latest_runtime_health_persisted : String,
) -> TaskExecutionProofResult {
  {
    message: if latest_snapshot_id == "" {
      "No task execution proof snapshots"
    } else {
      "Execution proof \{latest_status}: \{latest_snapshot_id}; \{verified_count.stringify()} verified / \{execution_count.stringify()} total"
    },
    execution_count: execution_count.stringify(),
    verified_count: verified_count.stringify(),
    latest_snapshot_id,
    latest_status,
    latest_task_id,
    latest_bridge_status,
    latest_runtime_status,
    latest_runtime_health_persisted,
  }
}

///|
fn parse_task_execution_proof_payload(
  json : Json,
) -> Result[TaskExecutionProofResult, String] {
  match json {
    {
      "execution_count": execution_count,
      "verified_count": verified_count,
      "latest_snapshot_id": String(latest_snapshot_id),
      "latest": {
        "status": String(latest_status),
        "snapshot": {
          "task_id": String(latest_task_id),
          "bridge_status": String(latest_bridge_status),
          "runtime_status": String(latest_runtime_status),
          "runtime_health_persisted": latest_runtime_health_persisted,
          ..
        },
        ..
      },
      ..
    } =>
      Ok(
        task_execution_proof_result(
          execution_count,
          verified_count,
          latest_snapshot_id,
          latest_status,
          latest_task_id,
          latest_bridge_status,
          latest_runtime_status,
          latest_runtime_health_persisted.stringify(),
        ),
      )
    {
      "execution_count": execution_count,
      "verified_count": verified_count,
      "latest_snapshot_id": String(latest_snapshot_id),
      "latest": Null,
      ..
    } =>
      Ok(
        task_execution_proof_result(
          execution_count,
          verified_count,
          latest_snapshot_id,
          "-",
          "-",
          "-",
          "-",
          "false",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task execution proof response")
  }
}

///|
fn fetch_task_execution_proof(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskExecutionProofResult] = Json(
    fn(result) { dispatch(TaskExecutionProofLoaded(result)) },
    parse_task_execution_proof_payload,
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
      "calibration_path": String(calibration_path),
      "latest_calibration_path": String(latest_calibration_path),
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
        calibration_path,
        latest_calibration_path,
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
fn parse_runtime_validation_session_payload(
  json : Json,
) -> Result[RuntimeValidationSessionResult, String] {
  match json {
    {
      "persisted": persisted,
      "sample_count": sample_count,
      "session_path": String(session_path),
      "latest_session_path": String(latest_session_path),
      "calibration_path": String(calibration_path),
      "latest_calibration_path": String(latest_calibration_path),
      "session": {
        "status": String(status),
        "ready_for_live_sdk": ready_for_live_sdk,
        "required_sample_count": required_sample_count,
        "ready_sample_count": ready_sample_count,
        "blocked_sample_count": blocked_sample_count,
        "first_blocker_code": String(first_blocker_code),
        "mapping_proof": {
          "status": String(mapping_status),
          "stable": mapping_stable,
          "matching_sample_count": mapping_matching_sample_count,
          "mismatch_sample_count": mapping_mismatch_sample_count,
          "message": String(mapping_message),
          ..
        },
        ..
      },
      "calibration": {
        "status": String(calibration_status),
        "action_count": calibration_action_count,
        "blocking_action_count": calibration_blocking_action_count,
        ..
      },
      ..
    } =>
      Ok({
        message: "Validation session \{status}; \{ready_sample_count.stringify()} ready / \{sample_count.stringify()} sample(s)",
        persisted: persisted.stringify(),
        sample_count: sample_count.stringify(),
        session_path,
        latest_session_path,
        calibration_path,
        latest_calibration_path,
        status,
        ready_for_live_sdk: ready_for_live_sdk.stringify(),
        required_sample_count: required_sample_count.stringify(),
        ready_sample_count: ready_sample_count.stringify(),
        blocked_sample_count: blocked_sample_count.stringify(),
        first_blocker_code,
        mapping_status,
        mapping_stable: mapping_stable.stringify(),
        mapping_matching_sample_count: mapping_matching_sample_count.stringify(),
        mapping_mismatch_sample_count: mapping_mismatch_sample_count.stringify(),
        mapping_message,
        calibration_status,
        calibration_action_count: calibration_action_count.stringify(),
        calibration_blocking_action_count: calibration_blocking_action_count.stringify(),
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime validation session response")
  }
}

///|
fn submit_runtime_validation_session(
  dispatch : (Msg) -> Cmd,
  url : String,
) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeValidationSessionResult] = Json(
    fn(result) { dispatch(RuntimeValidationSessionLoaded(result)) },
    parse_runtime_validation_session_payload,
  )
  @http.post(url, Json({ "sample_count": "3" }), expect~)
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
fn parse_moonrobo_live_readiness_payload(
  json : Json,
) -> Result[MoonroboLiveReadinessResult, String] {
  match json {
    {
      "status": String(status),
      "ready_for_live_sdk": ready_for_live_sdk,
      "can_collect_proof": can_collect_proof,
      "can_request_dispatch": can_request_dispatch,
      "physical_execution_allowed": physical_execution_allowed,
      "robot_id": String(robot_id),
      "bridge_id": String(bridge_id),
      "runtime_status": String(runtime_status),
      "runtime_bridge_base_url": String(runtime_bridge_base_url),
      "runtime_health_path": String(runtime_health_path),
      "runtime_validation_session_path": String(runtime_validation_session_path),
      "calibration_status": String(calibration_status),
      "calibration_path": String(calibration_path),
      "calibration_pending_revalidation": calibration_pending_revalidation,
      "proof_session_count": proof_session_count,
      "latest_proof_session_path": String(latest_proof_session_path),
      "next_method": String(next_method),
      "next_route": String(next_route),
      "next_title": String(next_title),
      "message": String(message),
      ..
    } =>
      Ok({
        message,
        status,
        ready_for_live_sdk: ready_for_live_sdk.stringify(),
        can_collect_proof: can_collect_proof.stringify(),
        can_request_dispatch: can_request_dispatch.stringify(),
        physical_execution_allowed: physical_execution_allowed.stringify(),
        robot_id,
        bridge_id,
        runtime_status,
        runtime_bridge_base_url,
        runtime_health_path,
        runtime_validation_session_path,
        calibration_status,
        calibration_path,
        calibration_pending_revalidation: calibration_pending_revalidation.stringify(),
        proof_session_count: proof_session_count.stringify(),
        latest_proof_session_path,
        next_method,
        next_route,
        next_title,
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Moonrobo live readiness response")
  }
}

///|
fn fetch_moonrobo_live_readiness(
  dispatch : (Msg) -> Cmd,
  url : String,
) -> Cmd {
  let expect : @http.Expecting[Cmd, MoonroboLiveReadinessResult] = Json(
    fn(result) { dispatch(MoonroboLiveReadinessLoaded(result)) },
    parse_moonrobo_live_readiness_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_loop_proof_check(json : Json) -> Result[PlatformLoopProofCheckResult, String] {
  match json {
    {
      "code": String(code),
      "label": String(label),
      "ready": ready,
      "evidence_route": String(evidence_route),
      "evidence_path": String(evidence_path),
      "message": String(message),
      ..
    } =>
      Ok({
        code,
        label,
        ready: ready.stringify(),
        evidence_route,
        evidence_path,
        message,
      })
    _ => Err("Invalid loop proof check")
  }
}

///|
fn parse_loop_proof_checks(json : Json) -> Result[Array[PlatformLoopProofCheckResult], String] {
  match json {
    Array(items) =>
      {
        let checks : Array[PlatformLoopProofCheckResult] = []
        for item in items {
          let check = match parse_loop_proof_check(item) {
            Ok(check) => check
            Err(error) => return Err(error)
          }
          checks.push(check)
        }
        Ok(checks)
      }
    _ => Err("Invalid loop proof checks")
  }
}

///|
fn parse_platform_loop_proof_payload(
  json : Json,
) -> Result[PlatformLoopProofResult, String] {
  match json {
    {
      "status": String(status),
      "ready": ready,
      "completed_count": completed_count,
      "total_count": total_count,
      "percent": percent,
      "robot_id": String(robot_id),
      "readiness_status": String(readiness_status),
      "readiness_pass_count": readiness_pass_count,
      "readiness_fail_count": readiness_fail_count,
      "latest_task_execution_path": String(latest_task_execution_path),
      "latest_routine_path": String(latest_routine_path),
      "latest_live_proof_path": String(latest_live_proof_path),
      "next_route": String(next_route),
      "checks": checks_json,
      "message": String(message),
      ..
    } =>
      {
        let checks = match parse_loop_proof_checks(checks_json) {
          Ok(checks) => checks
          Err(error) => return Err(error)
        }
        Ok({
          message,
          status,
          ready: ready.stringify(),
          completed_count: completed_count.stringify(),
          total_count: total_count.stringify(),
          percent: percent.stringify(),
          robot_id,
          readiness_status,
          readiness_pass_count: readiness_pass_count.stringify(),
          readiness_fail_count: readiness_fail_count.stringify(),
          latest_task_execution_path,
          latest_routine_path,
          latest_live_proof_path,
          next_route,
          checks,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform loop proof response")
  }
}

///|
fn fetch_platform_loop_proof(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, PlatformLoopProofResult] = Json(
    fn(result) { dispatch(PlatformLoopProofLoaded(result)) },
    parse_platform_loop_proof_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_platform_prove_loop_payload(
  json : Json,
) -> Result[PlatformLoopProofResult, String] {
  match json {
    {
      "message": String(message),
      "after": after_json,
      ..
    } =>
      {
        let after = match parse_platform_loop_proof_payload(after_json) {
          Ok(after) => after
          Err(error) => return Err(error)
        }
        Ok({ ..after, message })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform prove-loop response")
  }
}

///|
fn parse_platform_proof_session_payload(
  json : Json,
) -> Result[PlatformProofSessionResult, String] {
  match json {
    {
      "session_id": String(session_id),
      "session_path": String(session_path),
      "persisted": persisted,
      "status": String(status),
      "ready": ready,
      "attempted_count": attempted_count,
      "requested_iterations": requested_iterations,
      "stop_reason": String(stop_reason),
      "latest_proof_path": String(latest_proof_path),
      "next_route": String(next_route),
      "message": String(message),
      ..
    } =>
      Ok({
        message,
        session_id,
        session_path,
        persisted: persisted.stringify(),
        status,
        ready: ready.stringify(),
        attempted_count: attempted_count.stringify(),
        requested_iterations: requested_iterations.stringify(),
        stop_reason,
        latest_proof_path,
        next_route,
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform proof-session response")
  }
}

///|
fn parse_platform_proof_sessions_payload(
  json : Json,
) -> Result[PlatformProofSessionListResult, String] {
  match json {
    {
      "session_count": session_count,
      "sessions": Array(items),
      ..
    } =>
      {
        let sessions : Array[PlatformProofSessionResult] = []
        for item in items {
          match parse_platform_proof_session_payload(item) {
            Ok(session) => sessions.push(session)
            Err(error) => return Err(error)
          }
        }
        Ok({
          message: "Loaded \{session_count.stringify()} proof session(s)",
          session_count: session_count.stringify(),
          sessions,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform proof-session list response")
  }
}

///|
fn fetch_platform_proof_sessions(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, PlatformProofSessionListResult] = Json(
    fn(result) { dispatch(ProofSessionsLoaded(result)) },
    parse_platform_proof_sessions_payload,
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
fn parse_platform_advance_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "advanced": advanced,
      "blocked": blocked,
      "reason": String(reason),
      "downstream_status": downstream_status,
      "task_status": {
        "stage": String(stage),
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "Platform advance \{if blocked == true { "blocked" } else if advanced == true { "advanced" } else { "idle" }}; \{stage}; downstream \{downstream_status.stringify()}: \{reason}",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform advance response")
  }
}

///|
fn submit_platform_advance(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(PlatformAdvanced(result)) },
    parse_platform_advance_payload,
  )
  @http.post(url, Json({}), expect~)
}

///|
fn parse_platform_first_loop_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    {
      "blocked": blocked,
      "stopped_reason": String(stopped_reason),
      "step_count": step_count,
      "readiness": {
        "status": String(readiness_status),
        "pass_count": pass_count,
        "fail_count": fail_count,
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "First loop \{if blocked == true { "blocked" } else { "advanced" }} at \{stopped_reason}; \{step_count.stringify()} step(s); readiness \{readiness_status} \{pass_count.stringify()} pass / \{fail_count.stringify()} fail",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform first-loop response")
  }
}

///|
fn platform_first_loop_body(allow_dispatch? : Bool = false) -> Json {
  {
    "task_id": "",
    "max_steps": 6,
    "allow_dispatch": allow_dispatch,
  }
}

///|
fn submit_platform_first_loop(
  dispatch : (Msg) -> Cmd,
  url : String,
  allow_dispatch? : Bool = false,
) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) {
      if allow_dispatch {
        dispatch(FirstLoopDispatched(result))
      } else {
        dispatch(FirstLoopRan(result))
      }
    },
    parse_platform_first_loop_payload,
  )
  @http.post(url, Json(platform_first_loop_body(allow_dispatch~)), expect~)
}

///|
fn task_loop_mapping_result(
  mapping_id : String,
  robot_id : String,
  resident_id : String,
  bridge_id : String,
  runtime_status : String,
  availability : String,
  mapped : String,
  reachable : String,
  latest_task_id : String,
  latest_execution_status : String,
  latest_feedback_status : String,
  latest_command_outcome_status : String,
  verified_execution_count : String,
) -> TaskLoopMappingResult {
  {
    mapping_id,
    robot_id,
    resident_id,
    bridge_id,
    runtime_status,
    availability,
    mapped,
    reachable,
    latest_task_id,
    latest_execution_status,
    latest_feedback_status,
    latest_command_outcome_status,
    verified_execution_count,
  }
}

///|
fn parse_task_loop_mapping(json : Json) -> Result[TaskLoopMappingResult, String] {
  match json {
    {
      "mapping_id": String(mapping_id),
      "robot_id": String(robot_id),
      "resident_id": String(resident_id),
      "bridge_id": String(bridge_id),
      "runtime_status": String(runtime_status),
      "availability": String(mapping_availability),
      "mapped": mapped,
      "reachable": reachable,
      "latest_task_id": String(mapping_latest_task_id),
      "latest_execution_status": String(latest_execution_status),
      "latest_feedback_status": String(latest_feedback_status),
      "latest_command_outcome_status": String(latest_command_outcome_status),
      "verified_execution_count": verified_execution_count,
      ..
    } =>
      Ok(
        task_loop_mapping_result(
          mapping_id,
          robot_id,
          resident_id,
          bridge_id,
          runtime_status,
          mapping_availability,
          mapped.stringify(),
          reachable.stringify(),
          mapping_latest_task_id,
          latest_execution_status,
          latest_feedback_status,
          latest_command_outcome_status,
          verified_execution_count.stringify(),
        ),
      )
    _ => Err("Invalid task-loop mapping")
  }
}

///|
fn task_loop_execution_proof_result(
  execution_count : String,
  verified_count : String,
  latest_snapshot_id : String,
  latest_snapshot_path : String,
  latest_status : String,
  latest_verified : String,
  latest_command_outcome_status : String,
) -> TaskLoopExecutionProofResult {
  {
    execution_count,
    verified_count,
    latest_snapshot_id,
    latest_snapshot_path,
    latest_status,
    latest_verified,
    latest_command_outcome_status,
  }
}

///|
fn empty_task_loop_execution_proof_result(
  execution_count : Json,
  verified_count : Json,
  latest_snapshot_id : String,
) -> TaskLoopExecutionProofResult {
  task_loop_execution_proof_result(
    execution_count.stringify(),
    verified_count.stringify(),
    latest_snapshot_id,
    "-",
    "missing",
    "false",
    "missing",
  )
}

///|
fn parse_task_loop_execution_proof(
  json : Json,
) -> Result[TaskLoopExecutionProofResult, String] {
  match json {
    {
      "execution_count": execution_count,
      "verified_count": verified_count,
      "latest_snapshot_id": String(latest_snapshot_id),
      "latest": {
        "snapshot_path": String(latest_snapshot_path),
        "status": String(latest_status),
        "verified": latest_verified,
        "command_outcome_status": String(latest_command_outcome_status),
        ..
      },
      ..
    } =>
      Ok(
        task_loop_execution_proof_result(
          execution_count.stringify(),
          verified_count.stringify(),
          latest_snapshot_id,
          latest_snapshot_path,
          latest_status,
          latest_verified.stringify(),
          latest_command_outcome_status,
        ),
      )
    {
      "execution_count": execution_count,
      "verified_count": verified_count,
      "latest_snapshot_id": String(latest_snapshot_id),
      "latest": Null,
      ..
    } =>
      Ok(
        empty_task_loop_execution_proof_result(
          execution_count,
          verified_count,
          latest_snapshot_id,
        ),
      )
    _ => Err("Invalid task-loop execution proof")
  }
}

///|
fn parse_task_loop_recovery(json : Json) -> Result[TaskLoopRecoveryResult?, String] {
  match json {
    Null => Ok(None)
    {
      "kind": String(kind),
      "path": String(path),
      "summary": String(summary),
      "step_id": String(step_id),
      "status": String(status),
      ..
    } =>
      Ok(Some({ kind, path, summary, step_id, status }))
    _ => Err("Invalid task-loop recovery")
  }
}

///|
fn parse_task_loop_session(json : Json) -> Result[TaskLoopSessionResult, String] {
  match json {
    {
      "session_id": String(session_id),
      "thread_id": String(thread_id),
      "resident_id": String(resident_id),
      "mapping_id": String(mapping_id),
      "robot_id": String(robot_id),
      "bridge_id": String(bridge_id),
      "task_id": String(task_id),
      "latest_user_text": String(latest_user_text),
      "latest_robo_text": String(latest_robo_text),
      "stage": String(stage),
      "continuation_route": String(continuation_route),
      "dispatch_requested": dispatch_requested,
      "dispatch_ready": dispatch_ready,
      "execution_verified": execution_verified,
      "recovery_kind": String(recovery_kind),
      "recovery_path": String(recovery_path),
      ..
    } =>
      Ok({
        session_id,
        thread_id,
        resident_id,
        mapping_id,
        robot_id,
        bridge_id,
        task_id,
        latest_user_text,
        latest_robo_text,
        stage,
        continuation_route,
        dispatch_requested: dispatch_requested.stringify(),
        dispatch_ready: dispatch_ready.stringify(),
        execution_verified: execution_verified.stringify(),
        recovery_kind,
        recovery_path,
      })
    _ => Err("Invalid task-loop session")
  }
}

///|
fn task_loop_result(
  task_id : String,
  continued : String,
  dispatch_requested : String,
  classification : String,
  task_stage : String,
  task_summary : String,
  task_next_route : String,
  conversation_turn_count : String,
  conversation_latest_task_id : String,
  resident_availability : String,
  first_loop_status : String,
  stopped_reason : String,
  readiness_status : String,
  mapping : TaskLoopMappingResult,
  execution_proof : TaskLoopExecutionProofResult,
  recovery : TaskLoopRecoveryResult?,
  session : TaskLoopSessionResult,
  routine_id? : String = "",
  routine_status? : String = "",
  routine_verified? : String = "",
  routine_path? : String = "",
  routine_memory_updated? : String = "",
  routine_next_route? : String = "",
  proof_status? : String = "",
  proof_verified? : String = "",
  proof_path? : String = "",
  proof_next_route? : String = "",
  proof_auto_feedback_bound? : String = "",
  proof_auto_feedback_verified? : String = "",
  proof_auto_feedback_message? : String = "",
) -> TaskLoopResult {
  {
    message: if proof_status == "" {
      "Task loop \{task_id}; \{task_stage}; mapping \{mapping.runtime_status}/\{mapping.bridge_id}; continued \{continued}; dispatch \{dispatch_requested}; execution \{execution_proof.latest_status}"
    } else {
      "Live proof \{proof_status}; task \{task_id}; \{task_stage}; mapping \{mapping.runtime_status}/\{mapping.bridge_id}; dispatch \{dispatch_requested}; execution \{execution_proof.latest_status}"
    },
    task_id,
    routine_id,
    routine_status,
    routine_verified,
    routine_path,
    routine_memory_updated,
    routine_next_route,
    proof_status,
    proof_verified,
    proof_path,
    proof_next_route,
    proof_auto_feedback_bound,
    proof_auto_feedback_verified,
    proof_auto_feedback_message,
    continued,
    dispatch_requested,
    classification,
    task_stage,
    task_summary,
    task_next_route,
    conversation_turn_count,
    conversation_latest_task_id,
    resident_availability,
    first_loop_status,
    stopped_reason,
    readiness_status,
    mapping,
    execution_proof,
    recovery,
    session,
  }
}

///|
fn parse_platform_task_loop_payload(json : Json) -> Result[TaskLoopResult, String] {
  match json {
    {
      "submitted": _,
      "task_id": String(task_id),
      "continued": continued,
      "dispatch_requested": dispatch_requested,
      "task_message": {
        "message_plan": { "classification": String(classification), .. },
        ..
      },
      "task_status": {
        "stage": String(task_stage),
        "summary": String(task_summary),
        "next_route": String(task_next_route),
        ..
      },
      "conversation": {
        "turn_count": conversation_turn_count,
        "latest_task_id": String(conversation_latest_task_id),
        ..
      },
      "resident": { "availability": String(resident_availability), .. },
      "mapping": mapping_json,
      "execution_proof": execution_proof_json,
      "recovery": recovery_json,
      "session": session_json,
      "first_loop_status": first_loop_status,
      "first_loop": {
        "stopped_reason": String(stopped_reason),
        "readiness": { "status": String(readiness_status), .. },
        ..
      },
      ..
    } =>
      {
        let execution_proof = match
          parse_task_loop_execution_proof(execution_proof_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let recovery = match parse_task_loop_recovery(recovery_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let mapping = match parse_task_loop_mapping(mapping_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let session = match parse_task_loop_session(session_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok(task_loop_result(
          task_id,
          continued.stringify(),
          dispatch_requested.stringify(),
          classification,
          task_stage,
          task_summary,
          task_next_route,
          conversation_turn_count.stringify(),
          conversation_latest_task_id,
          resident_availability,
          first_loop_status.stringify(),
          stopped_reason,
          readiness_status,
          mapping,
          execution_proof,
          recovery,
          session,
        ))
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform task-loop response")
  }
}

///|
fn parse_robo_session_payload(json : Json) -> Result[RoboSessionResult, String] {
  match json {
    {
      "status": String(status),
      "has_task_message": has_task_message,
      "turn_count": turn_count,
      "session": session_json,
      "mapping": mapping_json,
      "execution_proof": execution_proof_json,
      "message": String(message),
      ..
    } =>
      {
        let session = match parse_task_loop_session(session_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let mapping = match parse_task_loop_mapping(mapping_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let execution_proof = match
          parse_task_loop_execution_proof(execution_proof_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok({
          message,
          status,
          has_task_message: has_task_message.stringify(),
          turn_count: turn_count.stringify(),
          session,
          mapping,
          execution_proof,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo session response")
  }
}

///|
fn fetch_robo_session(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RoboSessionResult] = Json(
    fn(result) { dispatch(RoboSessionLoaded(result)) },
    parse_robo_session_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_robo_turn_payload(json : Json) -> Result[RoboTurnResult, String] {
  match json {
    {
      "message": String(message),
      "turn_id": String(turn_id),
      "turn_path": String(turn_path),
      "status": String(status),
      "accepted": accepted,
      "agent_ran": agent_ran,
      "ask": { "task_id": String(task_id), .. },
      "decision": {
        "next_owner": String(next_owner),
        "next_kind": String(next_kind),
        "next_route": String(next_route),
        "can_act": can_act,
        "needs_agent": needs_agent,
        ..
      },
      ..
    } =>
      Ok({
        message,
        turn_id,
        turn_path,
        status,
        accepted: accepted.stringify(),
        agent_ran: agent_ran.stringify(),
        task_id,
        next_owner,
        next_kind,
        next_route,
        can_act: can_act.stringify(),
        needs_agent: needs_agent.stringify(),
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo turn response")
  }
}

///|
fn parse_robo_turn_history_payload(
  json : Json,
) -> Result[RoboTurnHistoryResult, String] {
  match json {
    {
      "turn_count": turn_count,
      "turns": Array(items),
      ..
    } =>
      {
        let turns : Array[RoboTurnResult] = []
        for item in items {
          match parse_robo_turn_payload(item) {
            Ok(turn) => turns.push(turn)
            Err(error) => return Err(error)
          }
        }
        Ok({
          message: "Loaded \{turn_count.stringify()} Robo turn(s)",
          turn_count: turn_count.stringify(),
          turns,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo turn history response")
  }
}

///|
fn fetch_robo_turn_history(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RoboTurnHistoryResult] = Json(
    fn(result) { dispatch(RoboTurnHistoryLoaded(result)) },
    parse_robo_turn_history_payload,
  )
  @http.get(url, expect~)
}

///|
fn submit_robo_turn(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, RoboTurnResult] = Json(
    fn(result) { dispatch(RoboTurnRan(result)) },
    parse_robo_turn_payload,
  )
  @http.post(url, Json(robo_turn_body(model)), expect~)
}

///|
fn parse_platform_live_proof_payload(json : Json) -> Result[TaskLoopResult, String] {
  match json {
    {
      "proof_id": String(_),
      "proof_path": String(proof_path),
      "status": String(proof_status),
      "verified": proof_verified,
      "auto_feedback_bound": auto_feedback_bound,
      "auto_feedback_verified": auto_feedback_verified,
      "auto_feedback_message": String(auto_feedback_message),
      "next_route": String(proof_next_route),
      "effective_loop": effective_loop_json,
      ..
    } =>
      {
        let result = match parse_platform_task_loop_payload(effective_loop_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok({
          ..result,
          message: "Live proof \{proof_status}; task \{result.task_id}; \{result.task_stage}; mapping \{result.mapping.runtime_status}/\{result.mapping.bridge_id}; dispatch \{result.dispatch_requested}; execution \{result.execution_proof.latest_status}",
          proof_status,
          proof_verified: proof_verified.stringify(),
          proof_path,
          proof_next_route,
          proof_auto_feedback_bound: auto_feedback_bound.stringify(),
          proof_auto_feedback_verified: auto_feedback_verified.stringify(),
          proof_auto_feedback_message: auto_feedback_message,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform live-proof response")
  }
}

///|
fn parse_moonclaw_robot_routine_payload(json : Json) -> Result[TaskLoopResult, String] {
  match json {
    {
      "routine_id": String(routine_id),
      "routine_path": String(routine_path),
      "status": String(routine_status),
      "verified": routine_verified,
      "memory_updated": memory_updated,
      "next_route": String(routine_next_route),
      "live_proof": live_proof_json,
      ..
    } =>
      {
        let result = match parse_platform_live_proof_payload(live_proof_json) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok({
          ..result,
          message: "Robot routine \{routine_status}; task \{result.task_id}; memory \{memory_updated.stringify()}; mapping \{result.mapping.runtime_status}/\{result.mapping.bridge_id}; dispatch \{result.dispatch_requested}; execution \{result.execution_proof.latest_status}",
          routine_id,
          routine_status,
          routine_verified: routine_verified.stringify(),
          routine_path,
          routine_memory_updated: memory_updated.stringify(),
          routine_next_route,
        })
      }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid MoonClaw robot routine response")
  }
}

///|
fn parse_platform_runtime_proof_payload(
  json : Json,
) -> Result[CommandResult, String] {
  match json {
    {
      "persisted": true,
      "status": String(status),
      "runtime_ready": runtime_ready,
      "record": { "telemetry_frame_id": String(frame_id), .. },
      "readiness": {
        "status": String(readiness_status),
        "pass_count": pass_count,
        "fail_count": fail_count,
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "Runtime proof \{status}; ready \{runtime_ready.stringify()}; frame \{frame_id}; readiness \{readiness_status} \{pass_count.stringify()} pass / \{fail_count.stringify()} fail",
        ),
      )
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform runtime proof response")
  }
}

///|
fn submit_platform_runtime_proof(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, CommandResult] = Json(
    fn(result) { dispatch(RuntimeProven(result)) },
    parse_platform_runtime_proof_payload,
  )
  @http.post(url, Json(platform_runtime_proof_body(model)), expect~)
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
fn parse_runtime_calibration_action(
  json : Json,
) -> Result[RuntimeCalibrationActionResult, String] {
  match json {
    {
      "action_id": String(action_id),
      "blocker_code": String(blocker_code),
      "severity": String(severity),
      "owner": String(owner),
      "evidence_path": String(evidence_path),
      "summary": String(summary),
      "next_step": String(next_step),
      ..
    } =>
      Ok({
        action_id,
        blocker_code,
        severity,
        owner,
        evidence_path,
        summary,
        next_step,
      })
    _ => Err("Invalid runtime calibration action")
  }
}

///|
fn parse_runtime_calibration_payload(
  json : Json,
) -> Result[RuntimeCalibrationResult, String] {
  match json {
    {
      "plan_id": String(plan_id),
      "status": String(status),
      "runtime_id": String(runtime_id),
      "robot_id": String(robot_id),
      "bridge_id": String(bridge_id),
      "action_count": action_count,
      "blocking_action_count": blocking_action_count,
      "actions": Array(action_jsons),
      ..
    } => {
      let actions : Array[RuntimeCalibrationActionResult] = []
      for action_json in action_jsons {
        match parse_runtime_calibration_action(action_json) {
          Ok(action) => actions.push(action)
          Err(error) => return Err(error)
        }
      }
      Ok({
        message: "Runtime calibration \{status}: \{blocking_action_count.stringify()} blocker(s) / \{action_count.stringify()} action(s)",
        plan_id,
        status,
        runtime_id,
        robot_id,
        bridge_id,
        action_count: action_count.stringify(),
        blocking_action_count: blocking_action_count.stringify(),
        actions,
      })
    }
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime calibration response")
  }
}

///|
fn fetch_runtime_calibration(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeCalibrationResult] = Json(
    fn(result) { dispatch(RuntimeCalibrationLoaded(result)) },
    parse_runtime_calibration_payload,
  )
  @http.get(url, expect~)
}

///|
fn parse_runtime_calibration_resolution_payload(
  json : Json,
) -> Result[RuntimeCalibrationResolutionResult, String] {
  match json {
    {
      "persisted": true,
      "resolution_path": String(resolution_path),
      "latest_resolution_path": String(latest_resolution_path),
      "resolution": {
        "action_id": String(action_id),
        "blocker_code": String(blocker_code),
        "status": String(status),
        "next_validation_route": String(next_validation_route),
        ..
      },
      ..
    } =>
      Ok({
        message: "Runtime calibration \{status}: \{blocker_code}",
        action_id,
        blocker_code,
        status,
        resolution_path,
        latest_resolution_path,
        next_validation_route,
      })
    {
      "code": String(code),
      "message": String(message),
      ..
    } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime calibration resolution response")
  }
}

///|
fn selected_runtime_calibration_action(
  model : AppModel,
) -> RuntimeCalibrationActionResult? {
  match model.latest_runtime_calibration {
    Some(plan) => plan.actions.get(0)
    None => None
  }
}

///|
fn runtime_calibration_resolution_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  let action_id = match selected_runtime_calibration_action(model) {
    Some(action) => action.action_id
    None => ""
  }
  {
    "action_id": action_id,
    "resolved_by": "rabbita",
    "resolved_at_ms": "\{snapshot.telemetry.captured_at_ms}",
    "note": "operator marked runtime calibration action resolved; rerun validation session",
  }
}

///|
fn submit_runtime_calibration_resolution(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, RuntimeCalibrationResolutionResult] = Json(
    fn(result) { dispatch(RuntimeCalibrationResolved(result)) },
    parse_runtime_calibration_resolution_payload,
  )
  @http.post(url, Json(runtime_calibration_resolution_body(model)), expect~)
}

///|
fn runtime_calibration_command_for_action(
  dispatch : (Msg) -> Cmd,
  action : @work_queue.AgentNextAction?,
) -> Cmd {
  match action {
    Some(value) if value.kind == "calibrate-runtime" =>
      fetch_runtime_calibration(dispatch, value.route)
    _ => @rabbita.none
  }
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
fn robot_routine_body(model : AppModel, allow_dispatch? : Bool = false) -> Json {
  {
    "task_message": task_message_body(model),
    "max_steps": 6,
    "allow_dispatch": allow_dispatch,
    "auto_continue": true,
  }
}

///|
fn robo_turn_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "task_message": task_message_body(model),
    "run_agent": true,
    "max_steps": 3,
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "remember": true,
  }
}

///|
fn prove_loop_body(model : AppModel) -> Json {
  {
    "task_message": task_message_body(model),
    "max_steps": 6,
    "allow_dispatch": false,
    "auto_continue": true,
    "bootstrap": true,
  }
}

///|
fn proof_session_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "session_id": "cockpit-proof-session-\{snapshot.telemetry.captured_at_ms}",
    "task_message": task_message_body(model),
    "iterations": 3,
    "max_steps": 8,
    "allow_dispatch": false,
    "auto_continue": true,
    "bootstrap": true,
    "stop_when_ready": true,
  }
}

///|
fn task_loop_continue_task_id(model : AppModel) -> String {
  match model.latest_task_loop {
    Some(result) => result.task_id
    None => model.focused_task_message_task_id
  }
}

///|
fn task_loop_continue_body(model : AppModel, allow_dispatch? : Bool = false) -> Json {
  {
    "task_id": task_loop_continue_task_id(model),
    "max_steps": 6,
    "allow_dispatch": allow_dispatch,
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
fn platform_runtime_proof_body(model : AppModel) -> Json {
  { "telemetry": model.snapshot.telemetry }
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
fn submit_robot_routine(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
  allow_dispatch? : Bool = false,
) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskLoopResult] = Json(
    fn(result) { dispatch(TaskLoopRan(result)) },
    parse_moonclaw_robot_routine_payload,
  )
  @http.post(url, Json(robot_routine_body(model, allow_dispatch~)), expect~)
}

///|
fn submit_platform_prove_loop(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, PlatformLoopProofResult] = Json(
    fn(result) { dispatch(LoopProven(result)) },
    parse_platform_prove_loop_payload,
  )
  @http.post(url, Json(prove_loop_body(model)), expect~)
}

///|
fn submit_platform_proof_session(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  let expect : @http.Expecting[Cmd, PlatformProofSessionResult] = Json(
    fn(result) { dispatch(ProofSessionRan(result)) },
    parse_platform_proof_session_payload,
  )
  @http.post(url, Json(proof_session_body(model)), expect~)
}

///|
fn submit_task_loop_continue(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
  allow_dispatch? : Bool = false,
) -> Cmd {
  let expect : @http.Expecting[Cmd, TaskLoopResult] = Json(
    fn(result) { dispatch(TaskLoopRan(result)) },
    parse_platform_task_loop_payload,
  )
  @http.post(url, Json(task_loop_continue_body(model, allow_dispatch~)), expect~)
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
