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
fn task_execution_proof_status(
  snapshot : @core.TaskExecutionSnapshot,
) -> (String, Bool, String) {
  if snapshot.receipt_status == Executed &&
    snapshot.bridge_status == "Accepted" &&
    snapshot.runtime_health_persisted &&
    snapshot.runtime_status == "healthy" {
    (
      "verified", true, "execution has receipt, bridge dispatch, and healthy post-dispatch runtime proof",
    )
  } else if snapshot.receipt_status == Executed &&
    snapshot.bridge_status == "Accepted" {
    (
      "bridge-accepted", false, "execution has receipt and bridge dispatch, but post-dispatch runtime health is not proven healthy",
    )
  } else if snapshot.receipt_status == Failed ||
    snapshot.bridge_status == "Rejected" ||
    snapshot.bridge_status == "Error" {
    (
      "failed", false, "execution evidence records a failed receipt or rejected bridge dispatch",
    )
  } else {
    (
      "incomplete", false, "execution evidence is missing a completed receipt or accepted bridge dispatch",
    )
  }
}

///|
fn task_execution_proof_record(
  snapshot_path : String,
  snapshot : @core.TaskExecutionSnapshot,
) -> TaskExecutionProofRecord {
  let (status, verified, message) = task_execution_proof_status(snapshot)
  { snapshot_path, snapshot, status, verified, message }
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
