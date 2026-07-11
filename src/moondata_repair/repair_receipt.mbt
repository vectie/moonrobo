///|
pub(all) struct StoredRepairReceiptResult {
  root : String
  repair_receipt_id : @moondata_core.RepairReceiptId
  repair_receipt_path : String
  catalog_path : String
  catalog_entry_count : Int
  repair_receipt : @moondata_core.RepairReceipt
} derive(Debug, Eq, ToJson, FromJson)

///|
fn receipt_issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn repair_receipt_id(
  repair_run_id : @moondata_core.RepairRunId,
  action_id : String,
  applied_at_ms : Int64,
) -> @moondata_core.RepairReceiptId {
  "repair-receipt-\{repair_run_id}-\{action_id}-\{applied_at_ms}"
}

///|
fn repair_action_by_id(
  run : @moondata_core.RepairRun,
  action_id : String,
) -> @moondata_core.RepairAction? {
  for action in run.actions {
    if action.action_id == action_id {
      return Some(action)
    }
  }
  None
}

///|
fn receipt_summary(
  status : String,
  action : @moondata_core.RepairAction,
) -> String {
  "MoonData repair receipt: \{status} \{action.operation_kind} for \{action.target_ref}"
}

///|
pub fn record_repair_receipt(
  root : String,
  repair_run_id : @moondata_core.RepairRunId,
  action_id : String,
  status : String,
  actor : String,
  applied_at_ms : Int64,
  validation_report_id? : String = "",
  evidence_refs? : Array[@moondata_core.MoonDataRef] = [],
) -> Result[StoredRepairReceiptResult, @moondata_store.MoonDataStoreIssue] {
  let run = match @moondata_store.read_repair_run(root, repair_run_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let action = match repair_action_by_id(run, action_id) {
    Some(value) => value
    None =>
      return Err(
        receipt_issue(
          "repair-action-not-found",
          @moondata_store.repair_run_path(root, repair_run_id),
          "repair run \{repair_run_id} does not contain action \{action_id}",
        ),
      )
  }
  let receipt = @moondata_core.repair_receipt(
    repair_receipt_id(repair_run_id, action_id, applied_at_ms),
    repair_run_id,
    action.action_id,
    action.operation_kind,
    action.target_ref,
    status,
    actor,
    applied_at_ms,
    validation_report_id,
    evidence_refs~,
    summary=receipt_summary(status, action),
  )
  let persisted = match @moondata_store.write_repair_receipt(root, receipt) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let rebuilt = match @moondata_index.rebuild_catalog(root, applied_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    repair_receipt_id: receipt.repair_receipt_id,
    repair_receipt_path: persisted.path,
    catalog_path: rebuilt.catalog_path,
    catalog_entry_count: rebuilt.entry_count,
    repair_receipt: receipt,
  })
}
