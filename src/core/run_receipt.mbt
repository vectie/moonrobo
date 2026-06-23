///|
pub(all) enum RunStatus {
  Denied
  WaitingForApproval
  WaitingForDryRun
  ReadyForExecution
  Executed
  Failed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RunReceipt {
  receipt_id : ReceiptId
  robot_id : RobotId
  bridge_id : BridgeId
  intent : CommandIntent
  verdict : SafetyVerdict
  status : RunStatus
  started_at_ms : Int64
  ended_at_ms : Int64?
  telemetry_frame_count : Int
  artifact_paths : Array[String]
  bridge_error : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn receipt_status_for_verdict(verdict : SafetyVerdict) -> RunStatus {
  match verdict.decision {
    Allow => ReadyForExecution
    Deny => Denied
    ApprovalRequired => WaitingForApproval
    DryRunRequired => WaitingForDryRun
  }
}

///|
pub fn receipt_from_verdict(
  receipt_id : ReceiptId,
  bridge_id : BridgeId,
  intent : CommandIntent,
  verdict : SafetyVerdict,
  started_at_ms : Int64,
) -> RunReceipt {
  {
    receipt_id,
    robot_id: intent.robot_id,
    bridge_id,
    intent,
    verdict,
    status: receipt_status_for_verdict(verdict),
    started_at_ms,
    ended_at_ms: None,
    telemetry_frame_count: 0,
    artifact_paths: [],
    bridge_error: None,
  }
}

///|
pub fn executed_receipt(
  receipt_id : ReceiptId,
  ready_receipt : RunReceipt,
  ended_at_ms : Int64,
  telemetry_frame_count? : Int = 0,
  artifact_paths? : Array[String] = [],
  bridge_error? : String,
) -> RunReceipt {
  {
    ..ready_receipt,
    receipt_id,
    status: Executed,
    ended_at_ms: Some(ended_at_ms),
    telemetry_frame_count,
    artifact_paths,
    bridge_error,
  }
}

///|
pub fn failed_receipt(
  receipt_id : ReceiptId,
  ready_receipt : RunReceipt,
  ended_at_ms : Int64,
  bridge_error : String,
  telemetry_frame_count? : Int = 0,
  artifact_paths? : Array[String] = [],
) -> RunReceipt {
  {
    ..ready_receipt,
    receipt_id,
    status: Failed,
    ended_at_ms: Some(ended_at_ms),
    telemetry_frame_count,
    artifact_paths,
    bridge_error: Some(bridge_error),
  }
}
