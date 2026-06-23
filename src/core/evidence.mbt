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
  }
}
