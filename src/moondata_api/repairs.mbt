///|
pub(all) struct MoonDataRepairRunQuery {
  validation_report_id : String
  validation_status : String
  operation_kind : String
  target_ref_contains : String
  category : String
  severity : String
  rule_id : String
  artifact_kind : String
  artifact_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataRepairRunList {
  root : String
  query : MoonDataRepairRunQuery
  repair_count : Int
  action_count : Int
  blocker_count : Int
  warning_count : Int
  missing_payload_count : Int
  unmanaged_payload_count : Int
  metadata_conflict_count : Int
  unsafe_ref_count : Int
  external_ref_count : Int
  non_payload_ref_count : Int
  manifest_surface_ref_count : Int
  latest_repair_run_id : String
  latest_repair_generated_at_ms : Int64
  repairs : Array[@moondata_core.RepairRun]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataRepairReceiptQuery {
  repair_run_id : String
  action_id : String
  operation_kind : String
  target_ref_contains : String
  status : String
  actor : String
  validation_report_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataRepairReceiptList {
  root : String
  query : MoonDataRepairReceiptQuery
  receipt_count : Int
  applied_count : Int
  failed_count : Int
  pending_count : Int
  latest_repair_receipt_id : String
  latest_repair_applied_at_ms : Int64
  receipts : Array[@moondata_core.RepairReceipt]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn repair_run_query(
  validation_report_id? : String = "",
  validation_status? : String = "",
  operation_kind? : String = "",
  target_ref_contains? : String = "",
  category? : String = "",
  severity? : String = "",
  rule_id? : String = "",
  artifact_kind? : String = "",
  artifact_id? : String = "",
) -> MoonDataRepairRunQuery {
  {
    validation_report_id,
    validation_status,
    operation_kind,
    target_ref_contains,
    category,
    severity,
    rule_id,
    artifact_kind,
    artifact_id,
  }
}

///|
pub fn repair_receipt_query(
  repair_run_id? : String = "",
  action_id? : String = "",
  operation_kind? : String = "",
  target_ref_contains? : String = "",
  status? : String = "",
  actor? : String = "",
  validation_report_id? : String = "",
) -> MoonDataRepairReceiptQuery {
  {
    repair_run_id,
    action_id,
    operation_kind,
    target_ref_contains,
    status,
    actor,
    validation_report_id,
  }
}

///|
fn repair_run_query_has_filters(query : MoonDataRepairRunQuery) -> Bool {
  query.validation_report_id != "" ||
  query.validation_status != "" ||
  query.operation_kind != "" ||
  query.target_ref_contains != "" ||
  query.category != "" ||
  query.severity != "" ||
  query.rule_id != "" ||
  query.artifact_kind != "" ||
  query.artifact_id != ""
}

///|
fn repair_receipt_matches(
  receipt : @moondata_core.RepairReceipt,
  query : MoonDataRepairReceiptQuery,
) -> Bool {
  if query.repair_run_id != "" && receipt.repair_run_id != query.repair_run_id {
    return false
  }
  if query.action_id != "" && receipt.action_id != query.action_id {
    return false
  }
  if query.operation_kind != "" &&
    receipt.operation_kind != query.operation_kind {
    return false
  }
  if query.target_ref_contains != "" &&
    !receipt.target_ref.contains(query.target_ref_contains) {
    return false
  }
  if query.status != "" && receipt.status != query.status {
    return false
  }
  if query.actor != "" && receipt.actor != query.actor {
    return false
  }
  query.validation_report_id == "" ||
  receipt.validation_report_id == query.validation_report_id
}

///|
fn repair_receipt_query_has_filters(query : MoonDataRepairReceiptQuery) -> Bool {
  query.repair_run_id != "" ||
  query.action_id != "" ||
  query.operation_kind != "" ||
  query.target_ref_contains != "" ||
  query.status != "" ||
  query.actor != "" ||
  query.validation_report_id != ""
}

///|
fn repair_action_matches(
  action : @moondata_core.RepairAction,
  query : MoonDataRepairRunQuery,
) -> Bool {
  if query.operation_kind != "" && action.operation_kind != query.operation_kind {
    return false
  }
  if query.target_ref_contains != "" &&
    !action.target_ref.contains(query.target_ref_contains) {
    return false
  }
  if query.category != "" && action.category != query.category {
    return false
  }
  if query.severity != "" && action.severity != query.severity {
    return false
  }
  if query.rule_id != "" && action.rule_id != query.rule_id {
    return false
  }
  if query.artifact_kind != "" && action.artifact_kind != query.artifact_kind {
    return false
  }
  query.artifact_id == "" || action.artifact_id == query.artifact_id
}

///|
fn repair_actions_match(
  actions : Array[@moondata_core.RepairAction],
  query : MoonDataRepairRunQuery,
) -> Bool {
  if query.category == "" &&
    query.operation_kind == "" &&
    query.target_ref_contains == "" &&
    query.severity == "" &&
    query.rule_id == "" &&
    query.artifact_kind == "" &&
    query.artifact_id == "" {
    return true
  }
  for action in actions {
    if repair_action_matches(action, query) {
      return true
    }
  }
  false
}

///|
fn repair_run_matches(
  run : @moondata_core.RepairRun,
  query : MoonDataRepairRunQuery,
) -> Bool {
  if query.validation_report_id != "" &&
    run.validation_report_id != query.validation_report_id {
    return false
  }
  if query.validation_status != "" &&
    run.validation_status != query.validation_status {
    return false
  }
  repair_actions_match(run.actions, query)
}

///|
fn repair_receipt_refs(
  root : String,
  receipts : Array[@moondata_core.RepairReceipt],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for receipt in receipts {
    refs.push(
      @moondata_core.moondata_ref(
        "repair-receipt",
        receipt.repair_receipt_id,
        @moondata_store.repair_receipt_path(root, receipt.repair_receipt_id),
        receipt.summary,
      ),
    )
  }
  refs
}

///|
priv struct RepairReceiptListSummary {
  applied_count : Int
  failed_count : Int
  pending_count : Int
  latest_repair_receipt_id : String
  latest_repair_applied_at_ms : Int64
}

///|
fn repair_receipt_list_summary(
  receipts : Array[@moondata_core.RepairReceipt],
) -> RepairReceiptListSummary {
  let mut applied_count = 0
  let mut failed_count = 0
  let mut pending_count = 0
  let mut latest_id = ""
  let mut latest_applied_at_ms = -1L
  for receipt in receipts {
    match receipt.status {
      "applied" => applied_count += 1
      "failed" => failed_count += 1
      "pending" => pending_count += 1
      _ => ()
    }
    if receipt.applied_at_ms > latest_applied_at_ms {
      latest_id = receipt.repair_receipt_id
      latest_applied_at_ms = receipt.applied_at_ms
    }
  }
  if latest_id == "" {
    return {
      applied_count,
      failed_count,
      pending_count,
      latest_repair_receipt_id: "",
      latest_repair_applied_at_ms: 0L,
    }
  }
  {
    applied_count,
    failed_count,
    pending_count,
    latest_repair_receipt_id: latest_id,
    latest_repair_applied_at_ms: latest_applied_at_ms,
  }
}

///|
fn repair_run_refs(
  root : String,
  repairs : Array[@moondata_core.RepairRun],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for run in repairs {
    refs.push(
      @moondata_core.moondata_ref(
        "repair-run",
        run.repair_run_id,
        @moondata_store.repair_run_path(root, run.repair_run_id),
        run.summary,
      ),
    )
  }
  refs
}

///|
priv struct RepairRunListSummary {
  action_count : Int
  blocker_count : Int
  warning_count : Int
  missing_payload_count : Int
  unmanaged_payload_count : Int
  metadata_conflict_count : Int
  unsafe_ref_count : Int
  external_ref_count : Int
  non_payload_ref_count : Int
  manifest_surface_ref_count : Int
  latest_repair_run_id : String
  latest_repair_generated_at_ms : Int64
}

///|
fn repair_run_list_summary(
  repairs : Array[@moondata_core.RepairRun],
) -> RepairRunListSummary {
  let mut action_count = 0
  let mut blocker_count = 0
  let mut warning_count = 0
  let mut missing_payload_count = 0
  let mut unmanaged_payload_count = 0
  let mut metadata_conflict_count = 0
  let mut unsafe_ref_count = 0
  let mut external_ref_count = 0
  let mut non_payload_ref_count = 0
  let mut manifest_surface_ref_count = 0
  let mut latest_id = ""
  let mut latest_generated_at_ms = -1L
  for run in repairs {
    action_count += run.action_count
    blocker_count += run.blocker_count
    warning_count += run.warning_count
    missing_payload_count += run.missing_payload_count
    unmanaged_payload_count += run.unmanaged_payload_count
    metadata_conflict_count += run.metadata_conflict_count
    unsafe_ref_count += run.unsafe_ref_count
    external_ref_count += run.external_ref_count
    non_payload_ref_count += run.non_payload_ref_count
    manifest_surface_ref_count += run.manifest_surface_ref_count
    if run.generated_at_ms > latest_generated_at_ms {
      latest_id = run.repair_run_id
      latest_generated_at_ms = run.generated_at_ms
    }
  }
  if latest_id == "" {
    return {
      action_count,
      blocker_count,
      warning_count,
      missing_payload_count,
      unmanaged_payload_count,
      metadata_conflict_count,
      unsafe_ref_count,
      external_ref_count,
      non_payload_ref_count,
      manifest_surface_ref_count,
      latest_repair_run_id: "",
      latest_repair_generated_at_ms: 0L,
    }
  }
  {
    action_count,
    blocker_count,
    warning_count,
    missing_payload_count,
    unmanaged_payload_count,
    metadata_conflict_count,
    unsafe_ref_count,
    external_ref_count,
    non_payload_ref_count,
    manifest_surface_ref_count,
    latest_repair_run_id: latest_id,
    latest_repair_generated_at_ms: latest_generated_at_ms,
  }
}

///|
pub fn list_repair_runs(
  root : String,
  query? : MoonDataRepairRunQuery = repair_run_query(),
) -> Result[MoonDataRepairRunList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repairs : Array[@moondata_core.RepairRun] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "repair-run" {
      let run = match @moondata_store.read_repair_run(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if repair_run_query_has_filters(query) {
        repair_run_matches(run, query)
      } else {
        true
      }
      if matches {
        repairs.push(run)
      }
    }
  }
  let refs = repair_run_refs(root, repairs)
  let evidence = repair_run_list_summary(repairs)
  Ok({
    root,
    query,
    repair_count: repairs.length(),
    action_count: evidence.action_count,
    blocker_count: evidence.blocker_count,
    warning_count: evidence.warning_count,
    missing_payload_count: evidence.missing_payload_count,
    unmanaged_payload_count: evidence.unmanaged_payload_count,
    metadata_conflict_count: evidence.metadata_conflict_count,
    unsafe_ref_count: evidence.unsafe_ref_count,
    external_ref_count: evidence.external_ref_count,
    non_payload_ref_count: evidence.non_payload_ref_count,
    manifest_surface_ref_count: evidence.manifest_surface_ref_count,
    latest_repair_run_id: evidence.latest_repair_run_id,
    latest_repair_generated_at_ms: evidence.latest_repair_generated_at_ms,
    repairs,
    refs,
    summary: "MoonData repair runs: \{repairs.length()} match(es), \{evidence.action_count} action(s), \{evidence.blocker_count} blocker(s), \{evidence.warning_count} warning(s), \{evidence.missing_payload_count} missing payload(s), \{evidence.unmanaged_payload_count} unmanaged payload(s)",
  })
}

///|
pub fn list_repair_receipts(
  root : String,
  query? : MoonDataRepairReceiptQuery = repair_receipt_query(),
) -> Result[MoonDataRepairReceiptList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipts : Array[@moondata_core.RepairReceipt] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "repair-receipt" {
      let receipt = match
        @moondata_store.read_repair_receipt(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if repair_receipt_query_has_filters(query) {
        repair_receipt_matches(receipt, query)
      } else {
        true
      }
      if matches {
        receipts.push(receipt)
      }
    }
  }
  let refs = repair_receipt_refs(root, receipts)
  let evidence = repair_receipt_list_summary(receipts)
  Ok({
    root,
    query,
    receipt_count: receipts.length(),
    applied_count: evidence.applied_count,
    failed_count: evidence.failed_count,
    pending_count: evidence.pending_count,
    latest_repair_receipt_id: evidence.latest_repair_receipt_id,
    latest_repair_applied_at_ms: evidence.latest_repair_applied_at_ms,
    receipts,
    refs,
    summary: "MoonData repair receipts: \{receipts.length()} match(es), \{evidence.applied_count} applied, \{evidence.failed_count} failed, \{evidence.pending_count} pending",
  })
}
