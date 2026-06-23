///|
pub(all) struct DryRunEvidence {
  dry_run_receipt_id : ReceiptId
  source_receipt_id : ReceiptId
  bridge_id : BridgeId
  intent : CommandIntent
  verdict : SafetyVerdict
  summary : String
  created_at_ms : Int64
  artifact_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ApprovalRecord {
  approval_id : String
  dry_run_receipt_id : ReceiptId
  intent : CommandIntent
  approved_by : Requester
  note : String
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BridgeDispatchEvidence {
  dispatch_id : String
  request_id : String
  bridge_id : BridgeId
  robot_id : RobotId
  operation : String
  http_method : String
  path : String
  intent_id : IntentId
  receipt_id : ReceiptId
  status : String
  message : String
  created_at_ms : Int64
  runtime_log_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskExecutionSnapshot {
  snapshot_id : String
  task_id : String
  message_path : String
  receipt_path : String
  dispatch_path : String
  memory_path : String
  runtime_health_path : String
  runtime_health_persisted : Bool
  receipt_id : ReceiptId
  receipt_status : RunStatus
  bridge_request_id : String
  bridge_status : String
  runtime_status : String
  runtime_log_path : String
  captured_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskExecutionProof {
  status : String
  verified : Bool
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn dry_run_evidence(
  dry_run_receipt_id : ReceiptId,
  source_receipt : RunReceipt,
  summary : String,
  created_at_ms : Int64,
  artifact_paths? : Array[String] = [],
) -> DryRunEvidence {
  {
    dry_run_receipt_id,
    source_receipt_id: source_receipt.receipt_id,
    bridge_id: source_receipt.bridge_id,
    intent: source_receipt.intent,
    verdict: source_receipt.verdict,
    summary,
    created_at_ms,
    artifact_paths,
  }
}

///|
pub fn task_execution_snapshot(
  snapshot_id : String,
  task_id : String,
  message_path : String,
  receipt_path : String,
  dispatch_path : String,
  memory_path : String,
  receipt : RunReceipt,
  dispatch : BridgeDispatchEvidence,
  captured_at_ms : Int64,
  runtime_health_path? : String = "",
  runtime_status? : String = "",
  runtime_health_persisted? : Bool = false,
  runtime_log_path? : String = "",
) -> TaskExecutionSnapshot {
  {
    snapshot_id,
    task_id,
    message_path,
    receipt_path,
    dispatch_path,
    memory_path,
    runtime_health_path,
    runtime_health_persisted,
    receipt_id: receipt.receipt_id,
    receipt_status: receipt.status,
    bridge_request_id: dispatch.request_id,
    bridge_status: dispatch.status,
    runtime_status,
    runtime_log_path,
    captured_at_ms,
  }
}

///|
pub fn task_execution_proof(
  snapshot : TaskExecutionSnapshot,
) -> TaskExecutionProof {
  if snapshot.receipt_status == Executed &&
    snapshot.bridge_status == "Accepted" &&
    snapshot.runtime_health_persisted &&
    snapshot.runtime_status == "healthy" {
    {
      status: "verified",
      verified: true,
      message: "execution has receipt, bridge dispatch, and healthy post-dispatch runtime proof",
    }
  } else if snapshot.receipt_status == Executed &&
    snapshot.bridge_status == "Accepted" {
    {
      status: "bridge-accepted",
      verified: false,
      message: "execution has receipt and bridge dispatch, but post-dispatch runtime health is not proven healthy",
    }
  } else if snapshot.receipt_status == Failed ||
    snapshot.bridge_status == "Rejected" ||
    snapshot.bridge_status == "Error" {
    {
      status: "failed",
      verified: false,
      message: "execution evidence records a failed receipt or rejected bridge dispatch",
    }
  } else {
    {
      status: "incomplete",
      verified: false,
      message: "execution evidence is missing a completed receipt or accepted bridge dispatch",
    }
  }
}

///|
pub fn approval_record(
  approval_id : String,
  dry_run_receipt_id : ReceiptId,
  intent : CommandIntent,
  approved_by : Requester,
  note : String,
  created_at_ms : Int64,
) -> ApprovalRecord {
  { approval_id, dry_run_receipt_id, intent, approved_by, note, created_at_ms }
}

///|
pub fn bridge_dispatch_evidence(
  dispatch_id : String,
  request_id : String,
  bridge_id : BridgeId,
  robot_id : RobotId,
  operation : String,
  http_method : String,
  path : String,
  intent_id : IntentId,
  receipt_id : ReceiptId,
  status : String,
  message : String,
  created_at_ms : Int64,
  runtime_log_path? : String = "",
) -> BridgeDispatchEvidence {
  {
    dispatch_id,
    request_id,
    bridge_id,
    robot_id,
    operation,
    http_method,
    path,
    intent_id,
    receipt_id,
    status,
    message,
    created_at_ms,
    runtime_log_path,
  }
}
