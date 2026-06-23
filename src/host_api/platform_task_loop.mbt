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
