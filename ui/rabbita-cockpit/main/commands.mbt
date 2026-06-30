///|
using @rabbita {type Cmd}

///|
fn[T] parse_response_text(
  text : String,
  parser : (Json) -> Result[T, String],
) -> Result[T, String] {
  let json = @json.parse(text) catch {
    error => return Err("Invalid JSON response: \{error}")
  }
  parser(json)
}

///|
fn[T] http_request_json(
  http_method : String,
  url : String,
  body : Json?,
  dispatch : (Msg) -> Cmd,
  message : (Result[T, String]) -> Msg,
  parser : (Json) -> Result[T, String],
) -> Cmd {
  @cmd.custom_cmd(fn(scheduler : &@cmd.Scheduler) {
    js_fetch_json(
      http_method,
      url,
      body=match body {
        Some(json) => json.stringify()
        None => ""
      },
      succeed=text => {
        scheduler.add(dispatch(message(parse_response_text(text, parser))))
      },
      failed=detail => {
        scheduler.add(dispatch(message(Err("HTTP request failed: \{detail}"))))
      },
    )
  })
}

///|
fn[T] http_get_json(
  url : String,
  dispatch : (Msg) -> Cmd,
  message : (Result[T, String]) -> Msg,
  parser : (Json) -> Result[T, String],
) -> Cmd {
  http_request_json("GET", url, None, dispatch, message, parser)
}

///|
fn[T] http_post_json(
  url : String,
  body : Json,
  dispatch : (Msg) -> Cmd,
  message : (Result[T, String]) -> Msg,
  parser : (Json) -> Result[T, String],
) -> Cmd {
  http_request_json("POST", url, Some(body), dispatch, message, parser)
}

///|
extern "js" fn js_fetch_json(
  http_method : String,
  url : String,
  body~ : String,
  succeed~ : (String) -> Unit,
  failed~ : (String) -> Unit,
) =
  #| (method, url, body, succeed, failed) => {
  #|   const config = { method };
  #|   if (body !== "") {
  #|     config.headers = { "Content-Type": "application/json" };
  #|     config.body = body;
  #|   }
  #|   fetch(url, config)
  #|     .then(response => response.text().then(text => {
  #|       if (response.ok) {
  #|         succeed(text);
  #|       } else {
  #|         failed(response.status + " " + response.statusText + ": " + text);
  #|       }
  #|     }))
  #|     .catch(error => failed(String(error)));
  #| }

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
  http_get_json(
    url,
    dispatch,
    result => SnapshotLoaded(result),
    parse_snapshot_payload,
  )
}

///|
fn parse_urdf_import_payload(json : Json) -> Result[UrdfImportResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF import result: \{error}")
  }
}

///|
fn parse_urdf_editor_document_payload(
  json : Json,
) -> Result[UrdfEditorDocumentResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF editor document: \{error}")
  }
}

///|
fn fetch_urdf_editor_document(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => UrdfEditorDocumentLoaded(result),
    parse_urdf_editor_document_payload,
  )
}

///|
fn parse_urdf_editor_edit_payload(
  json : Json,
) -> Result[UrdfEditorApplyResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF editor edit result: \{error}")
  }
}

///|
fn parse_urdf_editor_history_payload(
  json : Json,
) -> Result[UrdfEditorHistoryResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF editor history: \{error}")
  }
}

///|
fn fetch_urdf_editor_history(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => UrdfEditorHistoryLoaded(result),
    parse_urdf_editor_history_payload,
  )
}

///|
fn parse_urdf_editor_compare_payload(
  json : Json,
) -> Result[UrdfEditorCompareResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF editor compare result: \{error}")
  }
}

///|
fn fetch_urdf_editor_compare(
  dispatch : (Msg) -> Cmd,
  url : String,
  edit_id : String,
  compare_mode : String,
) -> Cmd {
  http_post_json(
    url,
    urdf_editor_compare_body(edit_id, compare_mode),
    dispatch,
    result => UrdfEditorCompareLoaded(result),
    parse_urdf_editor_compare_payload,
  )
}

///|
fn parse_urdf_editor_revert_payload(
  json : Json,
) -> Result[UrdfEditorRevertResult, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid URDF editor revert result: \{error}")
  }
}

///|
fn submit_urdf_import(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    urdf_import_body(model),
    dispatch,
    result => UrdfModelImported(result),
    parse_urdf_import_payload,
  )
}

///|
fn submit_urdf_editor_edit(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
  save~ : Bool,
) -> Cmd {
  http_post_json(
    url,
    urdf_editor_edit_body(model, save~),
    dispatch,
    result => UrdfEditorEditSubmitted(result),
    parse_urdf_editor_edit_payload,
  )
}

///|
fn submit_urdf_editor_session_save(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    urdf_editor_edit_body(model, save=true, command_override="save-session"),
    dispatch,
    result => UrdfEditorEditSubmitted(result),
    parse_urdf_editor_edit_payload,
  )
}

///|
fn submit_urdf_editor_revert(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => UrdfEditorEditReverted(result),
    parse_urdf_editor_revert_payload,
  )
}

///|
fn urdf_editor_restore_body(edit_id : String, source_side : String) -> Json {
  let body : UrdfEditorRestoreRequestBody = { edit_id, source_side }
  body.to_json()
}

///|
fn urdf_editor_compare_body(edit_id : String, compare_mode : String) -> Json {
  let body : UrdfEditorCompareRequestBody = {
    edit_id,
    compare_mode: Some(compare_mode),
  }
  body.to_json()
}

///|
fn submit_urdf_editor_restore(
  dispatch : (Msg) -> Cmd,
  url : String,
  edit_id : String,
  source_side : String,
) -> Cmd {
  http_post_json(
    url,
    urdf_editor_restore_body(edit_id, source_side),
    dispatch,
    result => UrdfEditorEditReverted(result),
    parse_urdf_editor_revert_payload,
  )
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
  http_get_json(
    url,
    dispatch,
    result => MoonstatLoaded(result),
    parse_moonstat_payload,
  )
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
fn fetch_runtime_supervisor_status(
  dispatch : (Msg) -> Cmd,
  url : String,
) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RuntimeSupervisorLoaded(result),
    parse_runtime_supervisor_payload,
  )
}

///|
fn parse_runtime_health_payload(
  json : Json,
) -> Result[RuntimeHealthResult, String] {
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime health response")
  }
}

///|
fn fetch_runtime_health(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RuntimeHealthLoaded(result),
    parse_runtime_health_payload,
  )
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
          execution_count, verified_count, latest_snapshot_id, "-", "-", "-", "-",
          "false",
        ),
      )
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task execution proof response")
  }
}

///|
fn fetch_task_execution_proof(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => TaskExecutionProofLoaded(result),
    parse_task_execution_proof_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime log response")
  }
}

///|
fn fetch_runtime_log(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RuntimeLogLoaded(result),
    parse_runtime_log_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime validation response")
  }
}

///|
fn fetch_runtime_validation(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RuntimeValidationLoaded(result),
    parse_runtime_validation_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime validation session response")
  }
}

///|
fn submit_runtime_validation_session(
  dispatch : (Msg) -> Cmd,
  url : String,
) -> Cmd {
  http_post_json(
    url,
    { "sample_count": "3" },
    dispatch,
    result => RuntimeValidationSessionLoaded(result),
    parse_runtime_validation_session_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform readiness response")
  }
}

///|
fn fetch_platform_readiness(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => PlatformReadinessLoaded(result),
    parse_platform_readiness_payload,
  )
}

///|
fn parse_moonrobo_live_readiness_payload(
  json : Json,
) -> Result[MoonroboLiveReadinessResult, String] {
  match json {
    {
      "status": String(status),
      "ready_for_live_sdk": ready_for_live_sdk,
      "can_run_proof_session": can_run_proof_session,
      "can_submit_gateway_command": can_submit_gateway_command,
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
      "proof_session_auto_feedback_attempted_count": proof_session_auto_feedback_attempted_count,
      "proof_session_auto_feedback_success_count": proof_session_auto_feedback_success_count,
      "proof_session_feedback_closed": proof_session_feedback_closed,
      "proof_session_latest_feedback_status": proof_session_latest_feedback_status,
      "proof_session_latest_feedback_message": String(
        proof_session_latest_feedback_message
      ),
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
        can_run_proof_session: can_run_proof_session.stringify(),
        can_submit_gateway_command: can_submit_gateway_command.stringify(),
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
        proof_session_auto_feedback_attempted_count: proof_session_auto_feedback_attempted_count.stringify(),
        proof_session_auto_feedback_success_count: proof_session_auto_feedback_success_count.stringify(),
        proof_session_feedback_closed: proof_session_feedback_closed.stringify(),
        proof_session_latest_feedback_status: proof_session_latest_feedback_status.stringify(),
        proof_session_latest_feedback_message,
        next_method,
        next_route,
        next_title,
      })
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Moonrobo live readiness response")
  }
}

///|
fn fetch_moonrobo_live_readiness(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => MoonroboLiveReadinessLoaded(result),
    parse_moonrobo_live_readiness_payload,
  )
}

///|
fn parse_loop_proof_check(
  json : Json,
) -> Result[PlatformLoopProofCheckResult, String] {
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
fn parse_loop_proof_checks(
  json : Json,
) -> Result[Array[PlatformLoopProofCheckResult], String] {
  match json {
    Array(items) => {
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
      "latest_gateway_command_path": String(latest_gateway_command_path),
      "latest_robo_loop_path": String(latest_robo_loop_path),
      "next_route": String(next_route),
      "checks": checks_json,
      "message": String(message),
      ..
    } => {
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
        latest_gateway_command_path,
        latest_robo_loop_path,
        next_route,
        checks,
        auto_feedback_attempted: "",
        auto_feedback_status: "",
        auto_feedback_message: "",
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform loop proof response")
  }
}

///|
fn fetch_platform_loop_proof(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => PlatformLoopProofLoaded(result),
    parse_platform_loop_proof_payload,
  )
}

///|
fn parse_platform_prove_loop_payload(
  json : Json,
) -> Result[PlatformLoopProofResult, String] {
  match json {
    {
      "message": String(message),
      "after": after_json,
      "auto_feedback_attempted": auto_feedback_attempted,
      "auto_feedback_status": auto_feedback_status,
      "auto_feedback_message": String(auto_feedback_message),
      ..
    } => {
      let after = match parse_platform_loop_proof_payload(after_json) {
        Ok(after) => after
        Err(error) => return Err(error)
      }
      Ok({
        ..after,
        message,
        auto_feedback_attempted: auto_feedback_attempted.stringify(),
        auto_feedback_status: auto_feedback_status.stringify(),
        auto_feedback_message,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
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
      "auto_feedback_attempted_count": auto_feedback_attempted_count,
      "auto_feedback_success_count": auto_feedback_success_count,
      "latest_auto_feedback_status": latest_auto_feedback_status,
      "latest_auto_feedback_message": String(latest_auto_feedback_message),
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
        auto_feedback_attempted_count: auto_feedback_attempted_count.stringify(),
        auto_feedback_success_count: auto_feedback_success_count.stringify(),
        latest_auto_feedback_status: latest_auto_feedback_status.stringify(),
        latest_auto_feedback_message,
      })
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform proof-session response")
  }
}

///|
fn parse_platform_proof_sessions_payload(
  json : Json,
) -> Result[PlatformProofSessionListResult, String] {
  match json {
    { "session_count": session_count, "sessions": Array(items), .. } => {
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform proof-session list response")
  }
}

///|
fn parse_live_exercise_payload(
  json : Json,
) -> Result[MoonroboLiveExerciseResult, String] {
  match json {
    {
      "exercise_id": String(exercise_id),
      "exercise_path": String(exercise_path),
      "persisted": persisted,
      "status": String(status),
      "routine": { "status": String(command_status), .. },
      "proof_session": proof_session_json,
      "readiness": { "status": String(readiness_status), .. },
      "memory": { "memory_path": String(memory_path), .. },
      "next_route": String(next_route),
      "message": String(message),
      ..
    } => {
      let proof_session = match
        parse_platform_proof_session_payload(proof_session_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        message,
        exercise_id,
        exercise_path,
        persisted: persisted.stringify(),
        status,
        command_status,
        proof_session_id: proof_session.session_id,
        proof_status: proof_session.status,
        readiness_status,
        memory_path,
        next_route,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Moonrobo live-exercise response")
  }
}

///|
fn parse_live_closure_missing(json : Json) -> Result[Array[String], String] {
  match json {
    Array(items) => {
      let missing : Array[String] = []
      for item in items {
        match item {
          String(value) => missing.push(value)
          _ => return Err("Invalid live-closure missing gate")
        }
      }
      Ok(missing)
    }
    _ => Err("Invalid live-closure missing list")
  }
}

///|
fn parse_live_closure_payload(
  json : Json,
) -> Result[MoonroboLiveClosureResult, String] {
  match json {
    {
      "exercise_count": exercise_count,
      "has_exercise": has_exercise,
      "exercise_id": String(exercise_id),
      "exercise_path": String(exercise_path),
      "closure": {
        "closed": closed,
        "status": String(status),
        "missing_count": missing_count,
        "missing": missing_json,
        ..
      },
      "next_route": String(next_route),
      "message": String(message),
      ..
    } => {
      let missing = match parse_live_closure_missing(missing_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        message,
        exercise_count: exercise_count.stringify(),
        has_exercise: has_exercise.stringify(),
        exercise_id,
        exercise_path,
        closed: closed.stringify(),
        status,
        missing_count: missing_count.stringify(),
        missing,
        next_route,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Moonrobo live-closure response")
  }
}

///|
fn parse_live_exercises_payload(
  json : Json,
) -> Result[MoonroboLiveExerciseHistoryResult, String] {
  match json {
    { "exercise_count": exercise_count, "exercises": Array(items), .. } => {
      let exercises : Array[MoonroboLiveExerciseResult] = []
      for item in items {
        match parse_live_exercise_payload(item) {
          Ok(exercise) => exercises.push(exercise)
          Err(error) => return Err(error)
        }
      }
      Ok({
        message: "Loaded \{exercise_count.stringify()} live exercise(s)",
        exercise_count: exercise_count.stringify(),
        exercises,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Moonrobo live-exercise history response")
  }
}

///|
fn fetch_platform_proof_sessions(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => ProofSessionsLoaded(result),
    parse_platform_proof_sessions_payload,
  )
}

///|
fn fetch_live_closure(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => LiveClosureLoaded(result),
    parse_live_closure_payload,
  )
}

///|
fn fetch_live_exercises(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => LiveExercisesLoaded(result),
    parse_live_exercises_payload,
  )
}

///|
fn parse_platform_bootstrap_payload(
  json : Json,
) -> Result[CommandResult, String] {
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid platform bootstrap response")
  }
}

///|
fn submit_platform_bootstrap(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => PlatformBootstrapped(result),
    parse_platform_bootstrap_payload,
  )
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
fn parse_task_loop_mapping(
  json : Json,
) -> Result[TaskLoopMappingResult, String] {
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
    _ => Err("Invalid Robo mapping")
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
          execution_count, verified_count, latest_snapshot_id,
        ),
      )
    _ => Err("Invalid Robo execution proof")
  }
}

///|
fn parse_task_loop_session(
  json : Json,
) -> Result[TaskLoopSessionResult, String] {
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
    _ => Err("Invalid Robo session")
  }
}

///|
fn parse_robo_session_payload(json : Json) -> Result[RoboSessionResult, String] {
  match json {
    {
      "status": String(status),
      "has_task_message": has_task_message,
      "loop_count": loop_count,
      "turn_count": turn_count,
      "session": session_json,
      "mapping": mapping_json,
      "execution_proof": execution_proof_json,
      "handoff": handoff_json,
      "message": String(message),
      ..
    } => {
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
      let handoff = match parse_robo_handoff_payload(handoff_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        message,
        status,
        has_task_message: has_task_message.stringify(),
        loop_count: loop_count.stringify(),
        turn_count: turn_count.stringify(),
        session,
        mapping,
        execution_proof,
        handoff,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo session response")
  }
}

///|
fn parse_robo_handoff_payload(json : Json) -> Result[RoboHandoffResult, String] {
  match json {
    {
      "status": String(status),
      "can_act": can_act,
      "needs_operator": needs_operator,
      "needs_moonclaw": needs_moonclaw,
      "accepts_task_messages": accepts_task_messages,
      "physical_execution_allowed": physical_execution_allowed,
      "next_owner": String(next_owner),
      "next_method": String(next_method),
      "next_route": String(next_route),
      "target_route": String(target_route),
      "next_kind": String(next_kind),
      "next_title": String(next_title),
      "queue_count": queue_count,
      "readiness_status": String(readiness_status),
      "loop_status": String(loop_status),
      "loop_percent": loop_percent,
      ..
    } =>
      Ok({
        status,
        can_act: can_act.stringify(),
        needs_operator: needs_operator.stringify(),
        needs_moonclaw: needs_moonclaw.stringify(),
        accepts_task_messages: accepts_task_messages.stringify(),
        physical_execution_allowed: physical_execution_allowed.stringify(),
        next_owner,
        next_method,
        next_route,
        target_route,
        next_kind,
        next_title,
        queue_count: queue_count.stringify(),
        readiness_status,
        loop_status,
        loop_percent: loop_percent.stringify(),
      })
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo handoff response")
  }
}

///|
fn fetch_robo_session(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RoboSessionLoaded(result),
    parse_robo_session_payload,
  )
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
      "moonclaw_handoff": moonclaw_handoff,
      "ask": { "task_id": String(task_id), .. },
      "handoff": {
        "next_owner": String(next_owner),
        "next_kind": String(next_kind),
        "next_route": String(next_route),
        "can_act": can_act,
        "needs_moonclaw": needs_moonclaw,
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
        moonclaw_handoff: moonclaw_handoff.stringify(),
        task_id,
        next_owner,
        next_kind,
        next_route,
        can_act: can_act.stringify(),
        needs_moonclaw: needs_moonclaw.stringify(),
      })
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo turn response")
  }
}

///|
fn parse_robo_turn_history_payload(
  json : Json,
) -> Result[RoboTurnHistoryResult, String] {
  match json {
    { "turn_count": turn_count, "turns": Array(items), .. } => {
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo turn history response")
  }
}

///|
fn fetch_robo_turn_history(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RoboTurnHistoryLoaded(result),
    parse_robo_turn_history_payload,
  )
}

///|
fn parse_optional_robo_turn_payload(
  json : Json,
) -> Result[RoboTurnResult?, String] {
  match json {
    Null => Ok(None)
    _ =>
      match parse_robo_turn_payload(json) {
        Ok(turn) => Ok(Some(turn))
        Err(error) => Err(error)
      }
  }
}

///|
fn parse_robo_loop_payload(json : Json) -> Result[RoboLoopResult, String] {
  match json {
    {
      "message": String(message),
      "loop_id": String(loop_id),
      "loop_path": String(loop_path),
      "status": String(status),
      "accepted": accepted,
      "turn": turn_json,
      "handoff": {
        "next_owner": String(final_owner),
        "next_kind": String(final_kind),
        "next_route": String(final_route),
        ..
      },
      ..
    } => {
      let turn = match parse_optional_robo_turn_payload(turn_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        message,
        loop_id,
        loop_path,
        status,
        accepted: accepted.stringify(),
        turn,
        final_owner,
        final_kind,
        final_route,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo loop response")
  }
}

///|
fn parse_robo_loop_history_payload(
  json : Json,
) -> Result[RoboLoopHistoryResult, String] {
  match json {
    { "loop_count": loop_count, "loops": Array(items), .. } => {
      let loops : Array[RoboLoopResult] = []
      for item in items {
        match parse_robo_loop_payload(item) {
          Ok(loop_run) => loops.push(loop_run)
          Err(error) => return Err(error)
        }
      }
      Ok({
        message: "Loaded \{loop_count.stringify()} Robo loop(s)",
        loop_count: loop_count.stringify(),
        loops,
      })
    }
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid Robo loop history response")
  }
}

///|
fn fetch_robo_loop_history(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RoboLoopHistoryLoaded(result),
    parse_robo_loop_history_payload,
  )
}

///|
fn submit_robo_loop(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    robo_loop_body(model),
    dispatch,
    result => RoboLoopRan(result),
    parse_robo_loop_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
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
  http_post_json(
    url,
    platform_runtime_proof_body(model),
    dispatch,
    result => RuntimeProven(result),
    parse_platform_runtime_proof_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime launch response")
  }
}

///|
fn submit_runtime_launch(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => RuntimeLaunchPrepared(result),
    parse_runtime_launch_payload,
  )
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
      Ok(
        command_result(
          "Runtime \{status}: pid \{pid.stringify()} \{script_path}",
        ),
      )
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime start response")
  }
}

///|
fn submit_runtime_start(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => RuntimeStarted(result),
    parse_runtime_start_payload,
  )
}

///|
fn parse_runtime_stop_payload(json : Json) -> Result[CommandResult, String] {
  match json {
    { "pid": pid, "status": String(status), "stopped": stopped, .. } =>
      Ok(
        command_result(
          "Runtime stop \{status}: pid \{pid.stringify()} stopped \{stopped.stringify()}",
        ),
      )
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime stop response")
  }
}

///|
fn submit_runtime_stop(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => RuntimeStopped(result),
    parse_runtime_stop_payload,
  )
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
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
      ..
    } =>
      Ok(
        command_result(
          "Emergency stop \{status}: request \{request_id} receipt \{receipt_id} evidence \{receipt_path} dispatch \{dispatch_path}",
        ),
      )
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime emergency stop response")
  }
}

///|
fn submit_runtime_emergency_stop(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_post_json(
    url,
    {},
    dispatch,
    result => RuntimeEmergencyStopped(result),
    parse_runtime_emergency_stop_payload,
  )
}

///|
fn parse_platform_queue_payload(
  json : Json,
) -> Result[@platform_queue.RobotPlatformQueue, String] {
  Ok(@json.from_json(json)) catch {
    error => Err("Invalid platform queue: \{error}")
  }
}

///|
fn fetch_platform_queue(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => WorkQueueLoaded(result),
    parse_platform_queue_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid runtime calibration response")
  }
}

///|
fn fetch_runtime_calibration(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => RuntimeCalibrationLoaded(result),
    parse_runtime_calibration_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
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
  http_post_json(
    url,
    runtime_calibration_resolution_body(model),
    dispatch,
    result => RuntimeCalibrationResolved(result),
    parse_runtime_calibration_resolution_payload,
  )
}

///|
fn runtime_calibration_command_for_queue(
  dispatch : (Msg) -> Cmd,
  queue : @platform_queue.RobotPlatformQueue,
) -> Cmd {
  if queue.items.is_empty() {
    @rabbita.none
  } else {
    let value = queue.items[0]
    if value.kind == "calibrate-runtime" {
      fetch_runtime_calibration(dispatch, value.target_path)
    } else {
      @rabbita.none
    }
  }
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message review response")
  }
}

///|
fn fetch_task_message_review(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => TaskMessageReviewLoaded(result),
    parse_task_message_review_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message status response")
  }
}

///|
fn fetch_task_message_status(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => TaskMessageStatusLoaded(result),
    parse_task_message_status_payload,
  )
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
        "receipt": {
          "receipt_id": String(receipt_id),
          "status": String(status),
          ..
        },
        ..
      },
      ..
    } => Ok(command_result("\{next_action}: \{status} receipt \{receipt_id}"))
    { "code": String(code), "message": String(message), .. } =>
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
    { "code": String(code), "message": String(message), .. } =>
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
    { "code": String(code), "message": String(message), .. } =>
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
      "runtime_health": {
        "runtime_health_path": String(runtime_health_path),
        ..
      },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
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
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
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
      "runtime_health": {
        "runtime_health_path": String(runtime_health_path),
        ..
      },
      "bridge_response": { "status": String(bridge_status), .. },
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
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
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
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
      "receipt": {
        "receipt_id": String(receipt_id),
        "status": String(status),
        ..
      },
      ..
    } => Ok(command_result("\{bridge_status}: \{status} receipt \{receipt_id}"))
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid execution response")
  }
}

///|
fn parse_review_resolution_payload(
  json : Json,
) -> Result[CommandResult, String] {
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
    } => Ok(command_result("\{disposition}: \{review_id} \{summary}"))
    { "code": String(code), "message": String(message), .. } =>
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
  inline_conversation? : TaskConversationResult? = None,
  inline_loop_proof? : PlatformLoopProofResult? = None,
  inline_live_readiness? : MoonroboLiveReadinessResult? = None,
  inline_handoff? : RoboHandoffResult? = None,
) -> TaskMessageResult {
  {
    message: match inline_handoff {
      Some(handoff) =>
        "Accepted \{task_id}; Robo handoff \{handoff.status}; next \{handoff.next_owner} \{handoff.next_route}; loop \{handoff.loop_status} \{handoff.loop_percent}%"
      None =>
        if session_id == "-" {
          "Accepted \{task_id}; \{classification} via \{next_route}; remembered \{card_count} card(s)"
        } else {
          "Accepted \{task_id}; observing \{session_id}; remembered \{card_count} card(s)"
        }
    },
    task_id,
    session_id,
    classification,
    next_route,
    requires_review,
    memory_path,
    card_count,
    resident_availability,
    inline_conversation,
    inline_loop_proof,
    inline_live_readiness,
    inline_handoff,
  }
}

///|
fn moonclaw_context_result(
  surface : String,
  summary : String,
  review_count : String,
  needs_human_count : String,
  latest_review_id? : String = "-",
  latest_review_summary? : String = "No review evidence queued",
  next_label? : String = "-",
  next_route? : String = "-",
) -> MoonClawContextResult {
  {
    surface,
    summary,
    review_count,
    needs_human_count,
    latest_review_id,
    latest_review_summary,
    next_label,
    next_route,
  }
}

///|
fn moonclaw_routine_run_result(
  run_id : String,
  status : String,
  invoked : String,
  record_path : String,
  plan_status : String,
  plan_owner : String,
  step_count : String,
  next_kind? : String = "-",
  next_route? : String = "-",
  error_code? : String = "",
  error_message? : String = "",
) -> MoonClawRoutineRunResult {
  let message = if error_code == "" {
    "MoonClaw routine \{status}; run \{run_id} persisted at \{record_path}"
  } else {
    "MoonClaw routine \{status}: \{error_code} \{error_message}; run \{run_id} persisted at \{record_path}"
  }
  {
    message,
    run_id,
    status,
    invoked,
    record_path,
    plan_status,
    plan_owner,
    step_count,
    next_kind,
    next_route,
    error_code,
    error_message,
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid observation run response")
  }
}

///|
fn parse_task_message_payload(json : Json) -> Result[TaskMessageResult, String] {
  match json {
    {
      "accepted": true,
      "submitted": submitted_json,
      "conversation": conversation_json,
      "loop_proof": loop_proof_json,
      "live_readiness": live_readiness_json,
      "handoff": handoff_json,
      ..
    } => {
      let submitted = match parse_task_message_payload(submitted_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let conversation = match
        parse_task_conversation_payload(conversation_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let loop_proof = match
        parse_platform_loop_proof_payload(loop_proof_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let live_readiness = match
        parse_moonrobo_live_readiness_payload(live_readiness_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let handoff = match parse_robo_handoff_payload(handoff_json) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(
        task_message_result(
          submitted.task_id,
          submitted.session_id,
          submitted.classification,
          submitted.next_route,
          submitted.requires_review,
          submitted.memory_path,
          submitted.card_count,
          submitted.resident_availability,
          inline_conversation=Some(conversation),
          inline_loop_proof=Some(loop_proof),
          inline_live_readiness=Some(live_readiness),
          inline_handoff=Some(handoff),
        ),
      )
    }
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
    { "code": String(code), "message": String(message), .. } =>
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
        "task": { "task_id": String(task_id), "goal": String(goal), .. },
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
    { "message_count": message_count, "messages": Array(message_json), .. } => {
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task-message ledger response")
  }
}

///|
fn fetch_task_messages(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => TaskMessagesLoaded(result),
    parse_task_message_ledger_payload,
  )
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
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid task conversation response")
  }
}

///|
fn fetch_task_conversation(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => TaskConversationLoaded(result),
    parse_task_conversation_payload,
  )
}

///|
fn parse_moonclaw_context_payload(
  json : Json,
) -> Result[MoonClawContextResult, String] {
  match json {
    {
      "context": {
        "robot_id": String(robot_id),
        "review_count": review_count,
        "needs_human_count": needs_human_count,
        "latest_review": {
          "review_id": String(review_id),
          "summary": String(review_summary),
          ..
        },
        "memory": { "card_count": memory_card_count, .. },
        "tool_registry": { "capability_count": capability_count, .. },
        "gateway": {
          "status": String(gateway_status),
          "next_route": String(next_route),
          "next_title": String(next_title),
          ..
        },
        ..
      },
      ..
    } =>
      Ok(
        moonclaw_context_result(
          "Context",
          "MoonClaw context for \{robot_id}: gateway \{gateway_status}; memory \{memory_card_count.stringify()} card(s); \{capability_count.stringify()} registered capability/capabilities.",
          review_count.stringify(),
          needs_human_count.stringify(),
          latest_review_id=review_id,
          latest_review_summary=review_summary,
          next_label=next_title,
          next_route~,
        ),
      )
    {
      "context": {
        "robot_id": String(robot_id),
        "review_count": review_count,
        "needs_human_count": needs_human_count,
        "memory": { "card_count": memory_card_count, .. },
        "tool_registry": { "capability_count": capability_count, .. },
        "gateway": {
          "status": String(gateway_status),
          "next_route": String(next_route),
          "next_title": String(next_title),
          ..
        },
        ..
      },
      ..
    } =>
      Ok(
        moonclaw_context_result(
          "Context",
          "MoonClaw context for \{robot_id}: gateway \{gateway_status}; memory \{memory_card_count.stringify()} card(s); \{capability_count.stringify()} registered capability/capabilities.",
          review_count.stringify(),
          needs_human_count.stringify(),
          next_label=next_title,
          next_route~,
        ),
      )
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => Err("Invalid MoonClaw context response")
  }
}

///|
fn parse_moonclaw_routine_run_record(
  json : Json,
  error_code? : String = "",
  error_message? : String = "",
) -> Result[MoonClawRoutineRunResult, String] {
  match json {
    {
      "run_id": String(run_id),
      "status": String(status),
      "invoked": invoked,
      "record_path": String(record_path),
      "plan": {
        "status": String(plan_status),
        "owner": String(plan_owner),
        "step_count": step_count,
        "next_step": {
          "kind": String(next_kind),
          "route": String(next_route),
          ..
        },
        ..
      },
      ..
    } =>
      Ok(
        moonclaw_routine_run_result(
          run_id,
          status,
          invoked.stringify(),
          record_path,
          plan_status,
          plan_owner,
          step_count.stringify(),
          next_kind~,
          next_route~,
          error_code~,
          error_message~,
        ),
      )
    {
      "run_id": String(run_id),
      "status": String(status),
      "invoked": invoked,
      "record_path": String(record_path),
      "plan": {
        "status": String(plan_status),
        "owner": String(plan_owner),
        "step_count": step_count,
        ..
      },
      ..
    } =>
      Ok(
        moonclaw_routine_run_result(
          run_id,
          status,
          invoked.stringify(),
          record_path,
          plan_status,
          plan_owner,
          step_count.stringify(),
          error_code~,
          error_message~,
        ),
      )
    _ => Err("Invalid MoonClaw routine run record")
  }
}

///|
fn parse_moonclaw_routine_run_payload(
  json : Json,
) -> Result[MoonClawRoutineRunResult, String] {
  match json {
    {
      "error": { "code": String(code), "message": String(message), .. },
      "run": run_json,
      ..
    } =>
      parse_moonclaw_routine_run_record(
        run_json,
        error_code=code,
        error_message=message,
      )
    { "error": { "code": String(code), "message": String(message), .. }, .. } =>
      Err("\{code}: \{message}")
    { "code": String(code), "message": String(message), .. } =>
      Err("\{code}: \{message}")
    _ => parse_moonclaw_routine_run_record(json)
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
  let parsed = @string.parse_int(model.observation_frame_count) catch { _ => 3 }
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
fn urdf_import_body(model : AppModel) -> Json {
  { "source_path": model.urdf_import_source, "import_id": "", "activate": true }
}

///|
fn optional_text(value : String) -> String? {
  let trimmed = value.trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some(trimmed)
  }
}

///|
fn optional_int(value : String) -> Int? {
  let trimmed = value.trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some(@string.parse_int(trimmed) catch { _ => 0 })
  }
}

///|
fn optional_double(value : String) -> Double? {
  let trimmed = value.trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some(@string.parse_double(trimmed) catch { _ => 0.0 })
  }
}

///|
fn urdf_editor_edit_body(
  model : AppModel,
  save~ : Bool,
  command_override? : String = "",
) -> Json {
  let origin : @urdf_editor.UrdfOriginPatch = {
    xyz: model.urdf_editor_xyz,
    rpy: model.urdf_editor_rpy,
  }
  let axis : @urdf_editor.UrdfAxisPatch = { xyz: model.urdf_editor_axis_xyz }
  let limit : @urdf_editor.UrdfLimitPatch = {
    lower: optional_double(model.urdf_editor_limit_lower),
    upper: optional_double(model.urdf_editor_limit_upper),
    effort: optional_double(model.urdf_editor_limit_effort),
    velocity: optional_double(model.urdf_editor_limit_velocity),
  }
  let dynamics : @urdf_editor.UrdfDynamicsPatch = {
    damping: optional_double(model.urdf_editor_dynamics_damping),
    friction: optional_double(model.urdf_editor_dynamics_friction),
  }
  let mimic : @urdf_editor.UrdfMimicPatch = {
    target_joint: model.urdf_editor_mimic_joint.trim().to_owned(),
    multiplier: optional_double(model.urdf_editor_mimic_multiplier),
    offset: optional_double(model.urdf_editor_mimic_offset),
  }
  let calibration : @urdf_editor.UrdfCalibrationPatch = {
    rising: optional_double(model.urdf_editor_calibration_rising),
    falling: optional_double(model.urdf_editor_calibration_falling),
  }
  let safety_controller : @urdf_editor.UrdfSafetyControllerPatch = {
    soft_lower_limit: optional_double(model.urdf_editor_safety_soft_lower),
    soft_upper_limit: optional_double(model.urdf_editor_safety_soft_upper),
    k_position: optional_double(model.urdf_editor_safety_k_position),
    k_velocity: optional_double(model.urdf_editor_safety_k_velocity),
  }
  let inertial : @urdf_editor.UrdfInertialPatch = {
    origin: Some(origin),
    mass: optional_double(model.urdf_editor_inertial_mass),
    ixx: optional_double(model.urdf_editor_inertial_ixx),
    ixy: optional_double(model.urdf_editor_inertial_ixy),
    ixz: optional_double(model.urdf_editor_inertial_ixz),
    iyy: optional_double(model.urdf_editor_inertial_iyy),
    iyz: optional_double(model.urdf_editor_inertial_iyz),
    izz: optional_double(model.urdf_editor_inertial_izz),
  }
  let material : @urdf_editor.UrdfMaterialPatch = {
    color_rgba: optional_text(model.urdf_editor_material_color_rgba),
    texture_filename: optional_text(model.urdf_editor_material_texture),
  }
  let geometry : @urdf_editor.UrdfGeometryPatch = {
    kind: model.urdf_editor_geometry_kind.trim().to_owned(),
    mesh_filename: optional_text(model.urdf_editor_mesh_filename),
    mesh_scale: optional_text(model.urdf_editor_mesh_scale),
    size: optional_text(model.urdf_editor_geometry_size),
    radius: optional_double(model.urdf_editor_geometry_radius),
    length: optional_double(model.urdf_editor_geometry_length),
  }
  let extension : @urdf_editor.UrdfExtensionPatch = {
    raw_source: model.urdf_editor_extension_raw_source,
  }
  let link_create : @urdf_editor.UrdfLinkCreatePatch = {
    name: model.urdf_editor_link_name.trim().to_owned(),
  }
  let joint_create : @urdf_editor.UrdfJointCreatePatch = {
    name: model.urdf_editor_joint_name.trim().to_owned(),
    joint_type: model.urdf_editor_joint_type.trim().to_owned(),
    parent_link: model.urdf_editor_link_name.trim().to_owned(),
    child_link: model.urdf_editor_child_link_name.trim().to_owned(),
    origin: Some(origin),
    axis: Some(axis),
    limit: Some(limit),
  }
  let visual_create : @urdf_editor.UrdfVisualCreatePatch = {
    link_name: model.urdf_editor_link_name.trim().to_owned(),
    origin: Some(origin),
    geometry,
  }
  let collision_create : @urdf_editor.UrdfCollisionCreatePatch = {
    link_name: model.urdf_editor_link_name.trim().to_owned(),
    origin: Some(origin),
    geometry,
  }
  let command = if command_override.trim() == "" {
    model.urdf_editor_command.trim().to_owned()
  } else {
    command_override
  }
  let body : UrdfEditorEditRequestBody = {
    command,
    joint_name: optional_text(model.urdf_editor_joint_name),
    link_name: optional_text(model.urdf_editor_link_name),
    new_name: optional_text(model.urdf_editor_new_name),
    selected_node_id: optional_text(model.urdf_editor_selected_node_id),
    session: model.urdf_editor_session,
    material_node_id: optional_text(model.urdf_editor_selected_node_id),
    visual_index: optional_int(model.urdf_editor_visual_index),
    collision_index: optional_int(model.urdf_editor_collision_index),
    origin: Some(origin),
    axis: Some(axis),
    limit: Some(limit),
    dynamics: Some(dynamics),
    mimic: Some(mimic),
    calibration: Some(calibration),
    safety_controller: Some(safety_controller),
    inertial: Some(inertial),
    material: Some(material),
    geometry: Some(geometry),
    extension: Some(extension),
    link_create: Some(link_create),
    joint_create: Some(joint_create),
    visual_create: Some(visual_create),
    collision_create: Some(collision_create),
    save,
  }
  body.to_json()
}

///|
fn robo_turn_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "task_message": task_message_body(model),
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "remember": true,
  }
}

///|
fn robo_loop_body(model : AppModel) -> Json {
  let snapshot = model.snapshot
  {
    "loop_id": "rabbita-robo-loop-\{snapshot.telemetry.captured_at_ms}",
    "turn": robo_turn_body(model),
    "now_ms": "\{snapshot.telemetry.captured_at_ms}",
    "remember": true,
  }
}

///|
fn prove_loop_body(model : AppModel) -> Json {
  {
    "task_message": task_message_body(model),
    "max_steps": 6,
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
    "bootstrap": true,
    "stop_when_ready": true,
  }
}

///|
fn platform_runtime_proof_body(model : AppModel) -> Json {
  { "telemetry": model.snapshot.telemetry }
}

///|
fn moonclaw_routine_run_body(model : AppModel) -> Json {
  {
    "moonrobo_url": model.moonrobo_gateway_url,
    "now_ms": "\{model.snapshot.telemetry.captured_at_ms}",
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
    "dry-run" =>
      http_post_json(
        url,
        active_intent_body(model, receipt_id~),
        dispatch,
        result => DryRunCollected(result),
        parse_dry_run_result_payload,
      )
    "approve" =>
      http_post_json(
        url,
        active_intent_body(model, receipt_id~),
        dispatch,
        result => ApprovalRecorded(result),
        parse_approval_result_payload,
      )
    "execute" =>
      http_post_json(
        url,
        active_intent_body(model, receipt_id~),
        dispatch,
        result => ExecutionRecorded(result),
        parse_execution_result_payload,
      )
    _ =>
      http_post_json(
        url,
        active_intent_body(model, receipt_id~),
        dispatch,
        result => IntentEvaluated(result),
        parse_intent_result_payload,
      )
  }
}

///|
fn submit_observation_run(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    observation_run_body(model),
    dispatch,
    result => ObservationRunCompleted(result),
    parse_observation_run_payload,
  )
}

///|
fn submit_task_message(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    task_message_body(model),
    dispatch,
    result => TaskMessageSubmitted(result),
    parse_task_message_payload,
  )
}

///|
fn submit_platform_prove_loop(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    prove_loop_body(model),
    dispatch,
    result => LoopProven(result),
    parse_platform_prove_loop_payload,
  )
}

///|
fn submit_platform_proof_session(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    proof_session_body(model),
    dispatch,
    result => ProofSessionRan(result),
    parse_platform_proof_session_payload,
  )
}

///|
fn fetch_moonclaw_context(dispatch : (Msg) -> Cmd, url : String) -> Cmd {
  http_get_json(
    url,
    dispatch,
    result => MoonClawContextLoaded(result),
    parse_moonclaw_context_payload,
  )
}

///|
fn submit_moonclaw_routine_run(
  dispatch : (Msg) -> Cmd,
  url : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    url,
    moonclaw_routine_run_body(model),
    dispatch,
    result => MoonClawRoutineRan(result),
    parse_moonclaw_routine_run_payload,
  )
}

///|
fn submit_review_resolution(
  dispatch : (Msg) -> Cmd,
  review_id : String,
  model : AppModel,
) -> Cmd {
  http_post_json(
    "/api/reviews/\{review_id}/resolve",
    review_resolution_body(model),
    dispatch,
    result => ReviewAccepted(result),
    parse_review_resolution_payload,
  )
}
