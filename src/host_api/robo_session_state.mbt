///|
pub(all) struct RoboExecutionProof {
  execution_count : Int
  verified_count : Int
  latest_snapshot_id : String
  latest : TaskExecutionProofRecord?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboSessionState {
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
fn robo_session_task_message_record(
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
fn robo_session_conversation(
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
fn robo_execution_proof(
  root : String,
) -> Result[RoboExecutionProof, HostApiResponse] {
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
fn robo_session_latest_turn(
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
fn robo_execution_verified(proof : RoboExecutionProof) -> Bool {
  match proof.latest {
    Some(record) => record.verified
    None => false
  }
}
