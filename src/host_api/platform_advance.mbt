///|
pub(all) struct PlatformAdvanceRequest {
  task_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformAdvanceResponse {
  advanced : Bool
  blocked : Bool
  reason : String
  work_item : @work_queue.AgentWorkItem?
  downstream_status : Int
  downstream : Json
  task_status : @moonbook.TaskMessageExecutionStatus?
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_advance_path() -> String {
  "/api/moonrobo/advance"
}

///|
fn default_advance_request() -> PlatformAdvanceRequest {
  { task_id: "" }
}

///|
fn decode_platform_advance_request(
  body : String,
) -> Result[PlatformAdvanceRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_advance_request())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-advance",
          platform_advance_path(),
          "failed to parse platform advance JSON",
        ),
      )
  }
  let request : PlatformAdvanceRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-advance",
          platform_advance_path(),
          "failed to decode platform advance contract",
        ),
      )
  }
  Ok(request)
}

///|
fn task_message_work_kind(kind : String) -> Bool {
  match kind {
    "evaluate-command-message"
    | "dry-run-command-message"
    | "approve-command-message"
    | "execute-command-message" => true
    _ => false
  }
}

///|
fn selected_task_work(
  queue : @work_queue.AgentWorkQueue,
  request : PlatformAdvanceRequest,
) -> @work_queue.AgentWorkItem? {
  for item in queue.items {
    if task_message_work_kind(item.kind) &&
      (request.task_id == "" || request.task_id == item.target_id) {
      return Some(item)
    }
  }
  None
}

///|
fn latest_runtime_context(root : String) -> (String, String) {
  match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) => (record.status, record.bridge_base_url)
    _ => ("not-running", "")
  }
}

///|
fn task_status_for_advance(
  root : String,
  task_id : String,
  runtime_status : String,
  runtime_bridge_base_url : String,
) -> @moonbook.TaskMessageExecutionStatus? {
  let path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(_) => return None
  }
  match
    read_task_message_record(
      root,
      path,
      text,
      runtime_status~,
      runtime_bridge_base_url~,
    ) {
    Ok(record) => Some(record.status)
    Err(_) => None
  }
}

///|
fn readiness_for_advance(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> (@readiness.PlatformReadinessReport, @readiness.PlatformReadinessPlan) {
  let report = @readiness.report(root, book)
  (report, @readiness.plan(report))
}

///|
fn advance_response(
  root : String,
  book : @runtime.LoadedRoboBook,
  advanced : Bool,
  blocked : Bool,
  reason : String,
  item : @work_queue.AgentWorkItem?,
  downstream_status : Int,
  downstream : Json,
  task_status : @moonbook.TaskMessageExecutionStatus?,
) -> HostApiResponse {
  let (readiness, readiness_plan) = readiness_for_advance(root, book)
  json_response(
    if blocked {
      409
    } else {
      200
    },
    {
      advanced,
      blocked,
      reason,
      work_item: item,
      downstream_status,
      downstream,
      task_status,
      readiness,
      readiness_plan,
    }.to_json(),
  )
}

///|
fn dispatch_task_action(
  root : String,
  item : @work_queue.AgentWorkItem,
) -> HostApiResponse {
  match item.kind {
    "evaluate-command-message" =>
      moonbook_task_message_evaluate_response(root, item.target_path)
    "dry-run-command-message" =>
      moonbook_task_message_dry_run_response(root, item.target_path)
    "approve-command-message" =>
      moonbook_task_message_approve_response(root, item.target_path)
    "execute-command-message" =>
      moonbook_task_message_execute_response(
        root,
        item.target_path.replace(old="/execute-sidecar", new="/execute"),
      )
    _ =>
      error_response(
        409,
        "unsupported-platform-advance",
        item.target_path,
        "platform advance only handles reviewed MoonBook task-message work",
      )
  }
}

///|
fn physical_dispatch_readiness_blocker(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> @readiness.ReadinessCheck? {
  let report = @readiness.report(root, book)
  for check in report.checks {
    if (
        check.code == "runtime-calibration-clear" ||
        check.code == "runtime-validation-current"
      ) &&
      check.status != "pass" {
      return Some(check)
    }
  }
  None
}

///|
pub fn platform_advance_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_advance_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let queue = match project_agent_work_queue(root, 0L) {
    Ok(queue) => queue
    Err(response) => return response
  }
  let item = match selected_task_work(queue, request) {
    Some(item) => item
    None =>
      return advance_response(
        root,
        book,
        false,
        false,
        "no reviewed task-message work is ready to advance",
        None,
        200,
        { "message": "no reviewed task-message work is ready to advance" },
        None,
      )
  }
  let (runtime_status, runtime_bridge_base_url) = latest_runtime_context(root)
  let status = task_status_for_advance(
    root,
    item.target_id,
    runtime_status,
    runtime_bridge_base_url,
  )
  if item.kind == "execute-command-message" && runtime_status != "healthy" {
    return advance_response(
      root,
      book,
      false,
      true,
      "runtime health is required before physical task-message dispatch",
      Some(item),
      409,
      {
        "code": "runtime-required",
        "message": "start and validate the matching runtime before sidecar execution",
        "runtime_status": runtime_status,
      },
      status,
    )
  }
  if item.kind == "execute-command-message" {
    match physical_dispatch_readiness_blocker(root, book) {
      Some(check) =>
        return advance_response(
          root,
          book,
          false,
          true,
          check.message,
          Some(item),
          409,
          {
            "code": check.code,
            "message": check.message,
            "path": check.path,
            "runtime_status": runtime_status,
          },
          status,
        )
      None => ()
    }
  }
  let downstream = dispatch_task_action(root, item)
  let downstream_json = downstream_json(downstream)
  let advanced = downstream.status >= 200 && downstream.status < 300
  let blocked = !advanced
  let next_status = task_status_for_advance(
    root,
    item.target_id,
    runtime_status,
    runtime_bridge_base_url,
  )
  advance_response(
    root,
    book,
    advanced,
    blocked,
    if advanced {
      "advanced \{item.kind}"
    } else {
      "advance blocked by downstream route"
    },
    Some(item),
    downstream.status,
    downstream_json,
    next_status,
  )
}
