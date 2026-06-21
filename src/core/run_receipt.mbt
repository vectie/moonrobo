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
