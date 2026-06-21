///|
pub(all) struct PolicyProposal {
  proposal_id : String
  policy_id : String
  episode_id : String
  robot_id : @core.RobotId
  capability : @core.CapabilityId
  parameters : Map[String, String]
  confidence : Double
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PolicyEvaluationReceipt {
  evaluation_id : String
  proposal : PolicyProposal
  intent : @core.CommandIntent
  result : @pipeline.PipelineResult
  quality_report : @dataset.DatasetQualityReport?
  gate_status : String
  physical_execution_allowed : Bool
  reason : String
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn policy_requester(policy_id : String) -> @core.Requester {
  { kind: "policy", id: policy_id }
}

///|
pub fn intent_from_proposal(
  profile : @core.RobotProfile,
  proposal : PolicyProposal,
) -> @core.CommandIntent {
  @core.command_intent(
    "intent-\{proposal.proposal_id}",
    if proposal.robot_id == "" {
      profile.id
    } else {
      proposal.robot_id
    },
    proposal.capability,
    policy_requester(proposal.policy_id),
    parameters=proposal.parameters,
  )
}

///|
fn quality_blocks(report : @dataset.DatasetQualityReport?) -> Bool {
  match report {
    Some(value) => !value.passed
    None => false
  }
}

///|
fn gate_status(
  result : @pipeline.PipelineResult,
  quality_report : @dataset.DatasetQualityReport?,
) -> String {
  if quality_blocks(quality_report) {
    return "blocked-quality"
  }
  match result.next_action {
    Execute => "proposal-only"
    CollectDryRun => "requires-dry-run"
    RequestApproval => "requires-approval"
    Stop => "blocked-safety"
  }
}

///|
fn gate_reason(
  result : @pipeline.PipelineResult,
  quality_report : @dataset.DatasetQualityReport?,
) -> String {
  if quality_blocks(quality_report) {
    return "dataset quality blockers prevent policy proposal review"
  }
  "policy proposals are review-only and cannot execute hardware directly: \{result.verdict.detail}"
}

///|
pub fn evaluate_proposal(
  profile : @core.RobotProfile,
  bridge_health : @core.BridgeHealth,
  proposal : PolicyProposal,
  evaluation_id : String,
  receipt_id : @core.ReceiptId,
  now_ms : Int64,
  quality_report : @dataset.DatasetQualityReport?,
) -> PolicyEvaluationReceipt {
  let intent = intent_from_proposal(profile, proposal)
  let result = @pipeline.evaluate_request(
    profile, bridge_health, intent, receipt_id, now_ms,
  )
  {
    evaluation_id,
    proposal,
    intent,
    result,
    quality_report,
    gate_status: gate_status(result, quality_report),
    physical_execution_allowed: false,
    reason: gate_reason(result, quality_report),
    created_at_ms: now_ms,
  }
}

///|
pub fn evaluation_json(
  evaluation : PolicyEvaluationReceipt,
  indent? : Int = 2,
) -> String {
  evaluation.to_json().stringify(indent~)
}
