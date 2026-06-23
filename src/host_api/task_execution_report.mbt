///|
pub(all) struct TaskExecutionProofRecord {
  snapshot_path : String
  snapshot : @core.TaskExecutionSnapshot
  status : String
  verified : Bool
  message : String
  command_outcome_status : String
  command_outcome_verified : Bool
  command_outcome_message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskExecutionProofReport {
  execution_count : Int
  verified_count : Int
  latest_snapshot_id : String
  latest : TaskExecutionProofRecord?
  executions : Array[TaskExecutionProofRecord]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn task_executions_path() -> String {
  "/api/moonrobo/executions"
}

///|
fn task_execution_proof_record(
  snapshot_path : String,
  snapshot : @core.TaskExecutionSnapshot,
) -> TaskExecutionProofRecord {
  let proof = @core.task_execution_proof(snapshot)
  let frame = if snapshot.physical_feedback_path == "" {
    None
  } else {
    match @runtime.read_telemetry_frame_file(snapshot.physical_feedback_path) {
      Ok(frame) => Some(frame)
      Err(_) => None
    }
  }
  let outcome = @core.command_outcome_evidence(snapshot, frame)
  {
    snapshot_path,
    snapshot,
    status: if proof.verified && !outcome.verified {
      "outcome-unconfirmed"
    } else {
      proof.status
    },
    verified: proof.verified && outcome.verified,
    message: proof.message,
    command_outcome_status: outcome.status,
    command_outcome_verified: outcome.verified,
    command_outcome_message: outcome.message,
  }
}

///|
pub fn task_execution_proof_report(
  root : String,
) -> Result[TaskExecutionProofReport, HostApiResponse] {
  let paths = match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let executions : Array[TaskExecutionProofRecord] = []
  for path in paths {
    let snapshot = match @runtime.read_task_execution_snapshot_file(path) {
      Ok(snapshot) => snapshot
      Err(issue) =>
        return Err(error_response(500, issue.code, issue.path, issue.message))
    }
    executions.push(task_execution_proof_record(path, snapshot))
  }
  let mut verified_count = 0
  for execution in executions {
    if execution.verified {
      verified_count += 1
    }
  }
  let latest = if executions.is_empty() {
    None
  } else {
    Some(executions[executions.length() - 1])
  }
  Ok({
    execution_count: executions.length(),
    verified_count,
    latest_snapshot_id: match latest {
      Some(record) => record.snapshot.snapshot_id
      None => ""
    },
    latest,
    executions,
  })
}

///|
pub fn task_executions_response(root : String) -> HostApiResponse {
  match task_execution_proof_report(root) {
    Ok(report) => json_response(200, report.to_json())
    Err(response) => response
  }
}
