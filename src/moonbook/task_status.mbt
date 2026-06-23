///|
pub(all) struct TaskMessageExecutionEvidence {
  evaluated_receipt : @core.RunReceipt?
  dry_run : @core.DryRunEvidence?
  approval : @core.ApprovalRecord?
  execution_receipt : @core.RunReceipt?
  bridge_dispatch : @core.BridgeDispatchEvidence?
  runtime_status : String
  runtime_bridge_base_url : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TaskMessageExecutionStatus {
  task_id : String
  message_id : String
  classification : String
  stage : String
  summary : String
  next_route : String
  message_path : String
  requires_review : Bool
  runtime_required : Bool
  runtime_status : String
  runtime_bridge_base_url : String
  evaluated : Bool
  dry_run_collected : Bool
  approved : Bool
  dispatched : Bool
  executed : Bool
  receipt_id : String
  receipt_status : String
  bridge_status : String
  evidence_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn task_message_dry_run_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "dry-run-\{draft.intent_id}-\{now_ms}"
}

///|
pub fn task_message_approval_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "approval-\{draft.intent_id}-\{now_ms}"
}

///|
pub fn task_message_execution_receipt_id(
  draft : @task.RobotTaskIntentDraft,
) -> String {
  "receipt-\{draft.intent_id}-executed"
}

///|
pub fn task_message_bridge_dispatch_id(
  draft : @task.RobotTaskIntentDraft,
  now_ms : Int64,
) -> String {
  "dispatch-request-execute-\{draft.intent_id}-\{now_ms}"
}

///|
pub fn task_message_execution_evidence(
  evaluated_receipt? : @core.RunReceipt? = None,
  dry_run? : @core.DryRunEvidence? = None,
  approval? : @core.ApprovalRecord? = None,
  execution_receipt? : @core.RunReceipt? = None,
  bridge_dispatch? : @core.BridgeDispatchEvidence? = None,
  runtime_status? : String = "unknown",
  runtime_bridge_base_url? : String = "",
) -> TaskMessageExecutionEvidence {
  {
    evaluated_receipt,
    dry_run,
    approval,
    execution_receipt,
    bridge_dispatch,
    runtime_status,
    runtime_bridge_base_url,
  }
}

///|
fn run_status_text(status : @core.RunStatus) -> String {
  match status {
    Denied => "denied"
    WaitingForApproval => "waiting-for-approval"
    WaitingForDryRun => "waiting-for-dry-run"
    ReadyForExecution => "ready-for-execution"
    Executed => "executed"
    Failed => "failed"
  }
}

///|
fn latest_receipt(evidence : TaskMessageExecutionEvidence) -> @core.RunReceipt? {
  match evidence.execution_receipt {
    Some(receipt) => Some(receipt)
    None => evidence.evaluated_receipt
  }
}

///|
fn runtime_ready(status : String) -> Bool {
  status == "unknown" ||
  status == "running" ||
  status == "running-unprobed" ||
  status == "healthy"
}

///|
fn stage_for(
  plan : @task.RobotTaskMessagePlan,
  evidence : TaskMessageExecutionEvidence,
) -> (String, String, String) {
  if !plan.requires_review {
    ("accepted", "", "Task message was accepted without command review.")
  } else if plan.intent_draft is None {
    (
      "needs-review",
      "/api/moonbook/task-messages/\{plan.task.task_id}",
      "Task message needs operator review before a command intent exists.",
    )
  } else if evidence.evaluated_receipt is None {
    (
      "needs-evaluation",
      "/api/moonbook/task-messages/\{plan.task.task_id}/evaluate",
      "Evaluate the message-derived intent through the safety pipeline.",
    )
  } else if evidence.dry_run is None {
    (
      "needs-dry-run",
      "/api/moonbook/task-messages/\{plan.task.task_id}/dry-run",
      "Collect dry-run evidence for the message-derived intent.",
    )
  } else if evidence.approval is None {
    (
      "needs-approval",
      "/api/moonbook/task-messages/\{plan.task.task_id}/approve",
      "Record operator approval for the reviewed task message.",
    )
  } else if evidence.execution_receipt is None ||
    evidence.bridge_dispatch is None {
    if evidence.runtime_status == "bridge-unhealthy" {
      (
        "runtime-unhealthy", "/api/runtime/health", "The physical runtime process is active but bridge telemetry is not reachable.",
      )
    } else if !runtime_ready(evidence.runtime_status) {
      (
        "runtime-required", "/api/runtime/supervisor/start", "Start the matching physical runtime supervisor before sidecar execution.",
      )
    } else {
      (
        "ready-to-dispatch",
        "/api/moonbook/task-messages/\{plan.task.task_id}/execute-sidecar",
        "Dry-run and approval evidence are present; dispatch through the supervised sidecar.",
      )
    }
  } else {
    match evidence.execution_receipt {
      Some(receipt) =>
        match receipt.status {
          Executed =>
            (
              "completed", "", "Task message has an executed receipt and bridge dispatch evidence.",
            )
          Failed =>
            (
              "failed",
              "/api/moonbook/task-messages/\{plan.task.task_id}/status",
              "Task message has a failed execution receipt; inspect bridge response evidence.",
            )
          _ =>
            (
              "dispatched",
              "/api/moonbook/task-messages/\{plan.task.task_id}/status",
              "Task message has bridge dispatch evidence; inspect receipt status.",
            )
        }
      None =>
        (
          "dispatched",
          "/api/moonbook/task-messages/\{plan.task.task_id}/status",
          "Task message has bridge dispatch evidence; inspect receipt status.",
        )
    }
  }
}

///|
fn append_path_if(paths : Array[String], present : Bool, path : String) -> Unit {
  if present {
    paths.push(path)
  }
}

///|
fn evidence_paths(
  message_path : String,
  plan : @task.RobotTaskMessagePlan,
  evidence : TaskMessageExecutionEvidence,
) -> Array[String] {
  let paths = [message_path]
  match plan.intent_draft {
    Some(draft) => {
      append_path_if(
        paths,
        evidence.evaluated_receipt is Some(_),
        "/runs/receipts/\{draft.receipt_id}.json",
      )
      append_path_if(
        paths,
        evidence.dry_run is Some(_),
        "/runs/dry-runs/\{task_message_dry_run_id(draft, plan.task.now_ms)}.json",
      )
      append_path_if(
        paths,
        evidence.approval is Some(_),
        "/runs/approvals/\{task_message_approval_id(draft, plan.task.now_ms)}.json",
      )
      append_path_if(
        paths,
        evidence.execution_receipt is Some(_),
        "/runs/receipts/\{task_message_execution_receipt_id(draft)}.json",
      )
      append_path_if(
        paths,
        evidence.bridge_dispatch is Some(_),
        "/runs/bridge-dispatches/\{task_message_bridge_dispatch_id(draft, plan.task.now_ms)}.json",
      )
    }
    None => ()
  }
  paths
}

///|
pub fn project_task_message_execution_status(
  message_path : String,
  plan : @task.RobotTaskMessagePlan,
  evidence : TaskMessageExecutionEvidence,
) -> TaskMessageExecutionStatus {
  let (stage, next_route, summary) = stage_for(plan, evidence)
  let receipt = latest_receipt(evidence)
  let receipt_id = match receipt {
    Some(value) => value.receipt_id
    None =>
      match plan.intent_draft {
        Some(draft) => draft.receipt_id
        None => ""
      }
  }
  let receipt_status = match receipt {
    Some(value) => run_status_text(value.status)
    None => "missing"
  }
  let bridge_status = match evidence.bridge_dispatch {
    Some(dispatch) => dispatch.status
    None => "missing"
  }
  {
    task_id: plan.task.task_id,
    message_id: plan.message_id,
    classification: plan.classification,
    stage,
    summary,
    next_route,
    message_path,
    requires_review: plan.requires_review,
    runtime_required: stage == "runtime-required" ||
    stage == "runtime-unhealthy",
    runtime_status: evidence.runtime_status,
    runtime_bridge_base_url: evidence.runtime_bridge_base_url,
    evaluated: evidence.evaluated_receipt is Some(_),
    dry_run_collected: evidence.dry_run is Some(_),
    approved: evidence.approval is Some(_),
    dispatched: evidence.bridge_dispatch is Some(_),
    executed: match evidence.execution_receipt {
      Some(receipt) => receipt.status == Executed
      None => false
    },
    receipt_id,
    receipt_status,
    bridge_status,
    evidence_paths: evidence_paths(message_path, plan, evidence),
  }
}
