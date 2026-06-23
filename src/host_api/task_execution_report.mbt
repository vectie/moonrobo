///|
pub(all) struct TaskExecutionProofRecord {
  snapshot_path : String
  snapshot : @core.TaskExecutionSnapshot
  status : String
  verified : Bool
  message : String
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
  {
    snapshot_path,
    snapshot,
    status: proof.status,
    verified: proof.verified,
    message: proof.message,
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
