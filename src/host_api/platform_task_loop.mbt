///|
pub(all) struct PlatformTaskLoopRequest {
  task_message : @task.RobotTaskMessageRequest
  max_steps : Int
  allow_dispatch : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformTaskLoopExecutionProof {
  execution_count : Int
  verified_count : Int
  latest_snapshot_id : String
  latest : TaskExecutionProofRecord?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformTaskLoopRecovery {
  kind : String
  path : String
  summary : String
  step_id : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformTaskLoopSession {
  session_id : String
  thread_id : String
  resident_id : String
  mapping_id : String
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  task_id : String
  latest_user_text : String
  latest_robo_text : String
  stage : String
  continuation_route : String
  dispatch_requested : Bool
  dispatch_ready : Bool
  execution_verified : Bool
  recovery_kind : String
  recovery_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformTaskLoopResponse {
  submitted : Bool
  task_id : String
  dispatch_requested : Bool
  task_message : MoontownTaskMessageResponse
  task_status : @moonbook.TaskMessageExecutionStatus
  conversation : @moonbook.MoonBookConversationThread
  resident : @resident.ResidentRobotAgent
  mapping : @resident.DigitalPhysicalMapping
  execution_proof : PlatformTaskLoopExecutionProof
  recovery : PlatformTaskLoopRecovery?
  session : PlatformTaskLoopSession
  first_loop_status : Int
  first_loop : PlatformFirstLoopResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_task_loop_path() -> String {
  "/api/moonrobo/task-loop"
}

///|
fn normalize_task_loop_request(
  request : PlatformTaskLoopRequest,
) -> PlatformTaskLoopRequest {
  {
    task_message: request.task_message,
    max_steps: if request.max_steps < 1 {
      1
    } else if request.max_steps > 12 {
      12
    } else {
      request.max_steps
    },
    allow_dispatch: request.allow_dispatch,
  }
}

///|
pub fn decode_platform_task_loop_request(
  body : String,
) -> Result[PlatformTaskLoopRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-task-loop",
          platform_task_loop_path(),
          "failed to parse platform task-loop JSON",
        ),
      )
  }
  let request : PlatformTaskLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-task-loop",
          platform_task_loop_path(),
          "failed to decode platform task-loop contract",
        ),
      )
  }
  Ok(normalize_task_loop_request(request))
}

///|
fn decode_task_loop_message_response(
  response : HostApiResponse,
) -> Result[MoontownTaskMessageResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-platform-task-loop-message",
          platform_task_loop_path(),
          "task-message ingress returned invalid JSON",
        ),
      )
  }
  let result : MoontownTaskMessageResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-platform-task-loop-message",
          platform_task_loop_path(),
          "task-message ingress returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
fn decode_task_loop_first_loop_response(
  response : HostApiResponse,
) -> Result[PlatformFirstLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-platform-task-loop-first-loop",
          platform_task_loop_path(),
          "first-loop returned invalid JSON",
        ),
      )
  }
  let result : PlatformFirstLoopResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-platform-task-loop-first-loop",
          platform_task_loop_path(),
          "first-loop returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
pub fn platform_task_loop_first_loop_body(
  request : PlatformTaskLoopRequest,
  task_id : String,
  allow_dispatch? : Bool = false,
) -> String {
  PlatformFirstLoopRequest::{
    task_id,
    max_steps: request.max_steps,
    allow_dispatch,
  }
  .to_json()
  .stringify()
}

///|
pub fn platform_task_loop_compose_response(
  root : String,
  task_message : MoontownTaskMessageResponse,
  first_loop_response : HostApiResponse,
  dispatch_requested? : Bool = false,
) -> HostApiResponse {
  let first_loop = match
    decode_task_loop_first_loop_response(first_loop_response) {
    Ok(result) => result
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let (runtime_status, runtime_bridge_base_url) = latest_runtime_context(root)
  let task_record = match
    task_loop_task_message_record(
      root,
      task_message.message_plan.task.task_id,
      runtime_status,
      runtime_bridge_base_url,
    ) {
    Ok(record) => record
    Err(response) => return response
  }
  let conversation = match
    task_loop_conversation(root, runtime_status, runtime_bridge_base_url) {
    Ok(conversation) => conversation
    Err(response) => return response
  }
  let resident = resident_after_task(root, book)
  let mapping = @resident.digital_physical_mapping(
    book,
    resident,
    runtime_status~,
    runtime_bridge_base_url~,
  )
  let execution_proof = match task_loop_execution_proof(root) {
    Ok(report) => report
    Err(response) => return response
  }
  let recovery = task_loop_recovery(first_loop)
  let session = task_loop_session(
    task_message.message_plan.task.task_id,
    dispatch_requested,
    task_record.status,
    conversation,
    resident,
    mapping,
    execution_proof,
    recovery,
    first_loop,
  )
  json_response(
    first_loop_response.status,
    PlatformTaskLoopResponse::{
      submitted: true,
      task_id: task_message.message_plan.task.task_id,
      dispatch_requested,
      task_message,
      task_status: task_record.status,
      conversation,
      resident,
      mapping,
      execution_proof,
      recovery,
      session,
      first_loop_status: first_loop_response.status,
      first_loop,
    }.to_json(),
  )
}

///|
fn task_loop_task_message_record(
  root : String,
  task_id : String,
  runtime_status : String,
  runtime_bridge_base_url : String,
) -> Result[MoonBookTaskMessageRecord, HostApiResponse] {
  let path = @runtime.moonbook_task_message_path(root, task_id)
  let text = match @runtime.read_moonbook_task_message_json(root, task_id) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  read_task_message_record(
    root,
    path,
    text,
    runtime_status~,
    runtime_bridge_base_url~,
  )
}

///|
fn task_loop_conversation(
  root : String,
  runtime_status : String,
  runtime_bridge_base_url : String,
) -> Result[@moonbook.MoonBookConversationThread, HostApiResponse] {
  let paths = match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let turns : Array[@moonbook.MoonBookConversationTurn] = []
  for path in paths {
    let text = match @runtime.read_moonbook_task_message_json_file(path) {
      Ok(text) => text
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
    let record = match
      read_task_message_record(
        root,
        path,
        text,
        runtime_status~,
        runtime_bridge_base_url~,
      ) {
      Ok(record) => record
      Err(response) => return Err(response)
    }
    turns.push(
      @moonbook.task_message_conversation_turn(
        record.message_path,
        record.plan,
        record.status,
      ),
    )
  }
  Ok(@moonbook.task_message_conversation_thread(turns))
}

///|
fn task_loop_execution_proof(
  root : String,
) -> Result[PlatformTaskLoopExecutionProof, HostApiResponse] {
  match task_execution_proof_report(root) {
    Ok(report) =>
      Ok({
        execution_count: report.execution_count,
        verified_count: report.verified_count,
        latest_snapshot_id: report.latest_snapshot_id,
        latest: report.latest,
      })
    Err(response) => Err(response)
  }
}

///|
fn task_loop_recovery(
  first_loop : PlatformFirstLoopResponse,
) -> PlatformTaskLoopRecovery? {
  let mut recovery : PlatformTaskLoopRecovery? = None
  for step in first_loop.steps {
    if step.recovery_kind != "" || step.recovery_path != "" {
      recovery = Some({
        kind: step.recovery_kind,
        path: step.recovery_path,
        summary: if step.recovery_summary == "" {
          step.message
        } else {
          step.recovery_summary
        },
        step_id: step.step_id,
        status: step.status,
      })
    }
  }
  recovery
}

///|
fn task_loop_latest_turn(
  conversation : @moonbook.MoonBookConversationThread,
  task_id : String,
) -> @moonbook.MoonBookConversationTurn? {
  let mut latest : @moonbook.MoonBookConversationTurn? = None
  for turn in conversation.turns {
    if turn.task_id == task_id {
      return Some(turn)
    }
    match latest {
      Some(current) if current.created_at_ms > turn.created_at_ms => ()
      _ => latest = Some(turn)
    }
  }
  latest
}

///|
fn task_loop_dispatch_ready(first_loop : PlatformFirstLoopResponse) -> Bool {
  first_loop.stopped_reason == "dispatch-ready" ||
  first_loop.steps.any(step => step.physical_execution_allowed && step.blocked)
}

///|
fn task_loop_execution_verified(proof : PlatformTaskLoopExecutionProof) -> Bool {
  match proof.latest {
    Some(record) => record.verified
    None => false
  }
}

///|
fn task_loop_session(
  task_id : String,
  dispatch_requested : Bool,
  status : @moonbook.TaskMessageExecutionStatus,
  conversation : @moonbook.MoonBookConversationThread,
  resident : @resident.ResidentRobotAgent,
  mapping : @resident.DigitalPhysicalMapping,
  proof : PlatformTaskLoopExecutionProof,
  recovery : PlatformTaskLoopRecovery?,
  first_loop : PlatformFirstLoopResponse,
) -> PlatformTaskLoopSession {
  let latest = task_loop_latest_turn(conversation, task_id)
  let (recovery_kind, recovery_path) = match recovery {
    Some(recovery) => (recovery.kind, recovery.path)
    None => ("", "")
  }
  {
    session_id: "robo-session:\{resident.resident_id}",
    thread_id: conversation.thread_id,
    resident_id: resident.resident_id,
    mapping_id: mapping.mapping_id,
    robot_id: mapping.robot_id,
    bridge_id: mapping.bridge_id,
    task_id,
    latest_user_text: match latest {
      Some(turn) => turn.user_text
      None => ""
    },
    latest_robo_text: match latest {
      Some(turn) => turn.robo_text
      None => status.summary
    },
    stage: status.stage,
    continuation_route: if recovery_path != "" {
      recovery_path
    } else {
      status.next_route
    },
    dispatch_requested,
    dispatch_ready: task_loop_dispatch_ready(first_loop),
    execution_verified: task_loop_execution_verified(proof),
    recovery_kind,
    recovery_path,
  }
}

///|
pub fn platform_task_loop_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_task_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let task_message_response = moontown_task_message_response(
    root,
    request.task_message.to_json().stringify(),
  )
  if task_message_response.status < 200 || task_message_response.status >= 300 {
    return task_message_response
  }
  let task_message = match
    decode_task_loop_message_response(task_message_response) {
    Ok(result) => result
    Err(response) => return response
  }
  let first_loop = platform_first_loop_response(
    root,
    platform_task_loop_first_loop_body(
      request,
      task_message.message_plan.task.task_id,
      allow_dispatch=request.allow_dispatch,
    ),
  )
  platform_task_loop_compose_response(
    root,
    task_message,
    first_loop,
    dispatch_requested=request.allow_dispatch,
  )
}
