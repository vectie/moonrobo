///|
pub(all) enum PipelineNextAction {
  Execute
  CollectDryRun
  RequestApproval
  Stop
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PipelineResult {
  intent : @core.CommandIntent
  verdict : @core.SafetyVerdict
  receipt : @core.RunReceipt
  next_action : PipelineNextAction
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn next_action_for_verdict(
  verdict : @core.SafetyVerdict,
) -> PipelineNextAction {
  match verdict.decision {
    Allow => Execute
    DryRunRequired => CollectDryRun
    ApprovalRequired => RequestApproval
    Deny => Stop
  }
}

///|
pub fn evaluate_request(
  profile : @core.RobotProfile,
  bridge_health : @core.BridgeHealth,
  intent : @core.CommandIntent,
  receipt_id : @core.ReceiptId,
  now_ms : Int64,
  approval_id? : String,
  dry_run_receipt_id? : @core.ReceiptId,
  developer_gate? : Bool = false,
) -> PipelineResult {
  let context : @core.SafetyContext = {
    profile,
    bridge_health,
    approval_id,
    dry_run_receipt_id,
    developer_gate,
  }
  let verdict = @core.evaluate_intent(context, intent)
  let receipt = @core.receipt_from_verdict(
    receipt_id,
    bridge_health.bridge_id,
    intent,
    verdict,
    now_ms,
  )
  { intent, verdict, receipt, next_action: next_action_for_verdict(verdict) }
}

///|
pub fn observe_telemetry_intent(
  intent_id : @core.IntentId,
  robot_id : @core.RobotId,
  requester : @core.Requester,
) -> @core.CommandIntent {
  @core.command_intent(intent_id, robot_id, "observe.telemetry", requester)
}

///|
pub fn high_walk_intent(
  intent_id : @core.IntentId,
  robot_id : @core.RobotId,
  requester : @core.Requester,
  x : String,
  yaw : String,
  duration_ms : String,
) -> @core.CommandIntent {
  @core.command_intent(intent_id, robot_id, "control.high.walk", requester, parameters={
    "x": x,
    "yaw": yaw,
    "duration_ms": duration_ms,
  })
}
