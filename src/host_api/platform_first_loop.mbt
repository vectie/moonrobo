///|
pub(all) struct PlatformFirstLoopRequest {
  task_id : String
  max_steps : Int
  allow_dispatch : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformFirstLoopStep {
  step_id : String
  route : String
  status : String
  http_status : Int
  message : String
  stage : String
  advanced : Bool
  blocked : Bool
  physical_execution_allowed : Bool
  recovery_kind : String
  recovery_path : String
  recovery_summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformFirstLoopResponse {
  advanced : Bool
  blocked : Bool
  stopped_reason : String
  step_count : Int
  steps : Array[PlatformFirstLoopStep]
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_first_loop_path() -> String {
  "/api/moonrobo/first-loop"
}

///|
fn default_first_loop_request() -> PlatformFirstLoopRequest {
  { task_id: "", max_steps: 6, allow_dispatch: false }
}

///|
fn decode_platform_first_loop_request(
  body : String,
) -> Result[PlatformFirstLoopRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_first_loop_request())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-first-loop",
          platform_first_loop_path(),
          "failed to parse platform first-loop JSON",
        ),
      )
  }
  let request : PlatformFirstLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-first-loop",
          platform_first_loop_path(),
          "failed to decode platform first-loop contract",
        ),
      )
  }
  Ok({
    task_id: request.task_id,
    max_steps: if request.max_steps < 1 {
      1
    } else if request.max_steps > 12 {
      12
    } else {
      request.max_steps
    },
    allow_dispatch: request.allow_dispatch,
  })
}

///|
fn readiness_for_first_loop(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> (@readiness.PlatformReadinessReport, @readiness.PlatformReadinessPlan) {
  let report = @readiness.report(root, book)
  (report, @readiness.plan(report))
}

///|
fn readiness_check_failed(
  report : @readiness.PlatformReadinessReport,
  code : String,
) -> Bool {
  report.checks.any(check => check.code == code && check.status != "pass")
}

///|
fn bootstrap_needed(report : @readiness.PlatformReadinessReport) -> Bool {
  readiness_check_failed(report, "tool-registry-ready") ||
  readiness_check_failed(report, "moonbook-memory-ready") ||
  readiness_check_failed(report, "task-message-present")
}

///|
fn first_loop_step(
  step_id : String,
  route : String,
  status : String,
  http_status : Int,
  message : String,
  stage? : String = "",
  advanced? : Bool = false,
  blocked? : Bool = false,
  physical_execution_allowed? : Bool = false,
  recovery_kind? : String = "",
  recovery_path? : String = "",
  recovery_summary? : String = "",
) -> PlatformFirstLoopStep {
  {
    step_id,
    route,
    status,
    http_status,
    message,
    stage,
    advanced,
    blocked,
    physical_execution_allowed,
    recovery_kind,
    recovery_path,
    recovery_summary,
  }
}

///|
fn first_loop_response(
  root : String,
  book : @runtime.LoadedRoboBook,
  steps : Array[PlatformFirstLoopStep],
  stopped_reason : String,
  blocked : Bool,
) -> HostApiResponse {
  let (readiness, readiness_plan) = readiness_for_first_loop(root, book)
  json_response(
    if blocked {
      409
    } else {
      200
    },
    {
      advanced: steps.any(step => step.advanced),
      blocked,
      stopped_reason,
      step_count: steps.length(),
      steps,
      readiness,
      readiness_plan,
    }.to_json(),
  )
}

///|
fn decode_advance_result(
  response : HostApiResponse,
) -> Result[PlatformAdvanceResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-platform-advance-result",
          platform_first_loop_path(),
          "platform advance returned invalid JSON",
        ),
      )
  }
  let result : PlatformAdvanceResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-platform-advance-result",
          platform_first_loop_path(),
          "platform advance returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
fn advance_stage(result : PlatformAdvanceResponse) -> String {
  match result.task_status {
    Some(status) => status.stage
    None => ""
  }
}

///|
fn advance_message(result : PlatformAdvanceResponse) -> String {
  if result.reason != "" {
    result.reason
  } else {
    match result.downstream {
      { "message": String(message), .. } => message
      _ => "platform advance returned no message"
    }
  }
}

///|
fn advance_step(
  response : HostApiResponse,
  result : PlatformAdvanceResponse,
) -> PlatformFirstLoopStep {
  let action_kind = match result.action {
    Some(action) => action.kind
    None => "advance"
  }
  first_loop_step(
    action_kind,
    platform_advance_path(),
    if result.blocked {
      "blocked"
    } else if result.advanced {
      "advanced"
    } else {
      "idle"
    },
    response.status,
    advance_message(result),
    stage=advance_stage(result),
    advanced=result.advanced,
    blocked=result.blocked,
    physical_execution_allowed=match result.action {
      Some(action) => action.kind == "execute-command-message"
      None => false
    },
  )
}

///|
fn selected_first_loop_action(
  root : String,
  request : PlatformFirstLoopRequest,
) -> @work_queue.AgentNextAction? {
  let queue = match project_agent_work_queue(root, 0L) {
    Ok(queue) => queue
    Err(_) => return None
  }
  match selected_task_work(queue, { task_id: request.task_id }) {
    Some(item) => Some(@work_queue.action_for_item(item))
    None => None
  }
}

///|
pub fn platform_first_loop_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_first_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let steps : Array[PlatformFirstLoopStep] = []
  let (initial, _) = readiness_for_first_loop(root, book)
  if bootstrap_needed(initial) {
    let bootstrap = platform_bootstrap_response(root, "{}")
    steps.push(
      first_loop_step(
        "bootstrap",
        platform_bootstrap_path(),
        if bootstrap.status >= 200 && bootstrap.status < 300 {
          "advanced"
        } else {
          "blocked"
        },
        bootstrap.status,
        "bootstrapped non-physical platform substrate",
        advanced=bootstrap.status >= 200 && bootstrap.status < 300,
        blocked=bootstrap.status < 200 || bootstrap.status >= 300,
      ),
    )
    if bootstrap.status < 200 || bootstrap.status >= 300 {
      return first_loop_response(root, book, steps, "bootstrap-blocked", true)
    }
  }
  for _ in 0..<request.max_steps {
    let action = selected_first_loop_action(root, request)
    match action {
      Some(action) if action.kind == "execute-command-message" &&
        !request.allow_dispatch => {
        let (runtime_status, _) = latest_runtime_context(root)
        if runtime_status == "healthy" &&
          physical_dispatch_readiness_blocker(root, book) is None {
          steps.push(
            first_loop_step(
              "dispatch-ready",
              platform_advance_path(),
              "blocked",
              409,
              "runtime proof is ready; explicit dispatch approval is required before physical execution",
              stage="ready-to-dispatch",
              blocked=true,
              physical_execution_allowed=true,
            ),
          )
          return first_loop_response(root, book, steps, "dispatch-ready", true)
        }
      }
      _ => ()
    }
    let advance = platform_advance_response(
      root,
      { task_id: request.task_id }.to_json().stringify(),
    )
    let result = match decode_advance_result(advance) {
      Ok(result) => result
      Err(response) => return response
    }
    let step = advance_step(advance, result)
    steps.push(step)
    if result.blocked {
      return first_loop_response(root, book, steps, "advance-blocked", true)
    }
    if !result.advanced {
      return first_loop_response(root, book, steps, "no-work", false)
    }
    if result.task_status is Some({ stage: "completed", .. }) {
      return first_loop_response(root, book, steps, "completed", false)
    }
  }
  first_loop_response(root, book, steps, "max-steps", false)
}
