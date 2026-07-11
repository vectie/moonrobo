///|
fn count_repair_action_severity(
  actions : Array[@moondata_core.RepairAction],
  severity : String,
) -> Int {
  let mut count = 0
  for action in actions {
    if action.severity == severity {
      count += 1
    }
  }
  count
}

///|
fn count_repair_action_category(
  actions : Array[@moondata_core.RepairAction],
  category : String,
) -> Int {
  let mut count = 0
  for action in actions {
    if action.category == category {
      count += 1
    }
  }
  count
}

///|
fn add_repair_count_mismatch(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  field : String,
  expected : Int,
  actual : Int,
) -> Unit {
  if expected == actual {
    return
  }
  findings.push(
    @moondata_core.validation_finding(
      "repair-run-count-mismatch",
      "blocker",
      entry.artifact_kind,
      entry.artifact_id,
      "repair run \{field} \{expected} does not match \{actual} action(s)",
      recommendation="rewrite the repair run from the current validation report",
    ),
  )
}

///|
fn add_repair_source_validation_mismatch(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  rule_id : String,
  message : String,
) -> Unit {
  findings.push(
    @moondata_core.validation_finding(
      rule_id,
      "blocker",
      entry.artifact_kind,
      entry.artifact_id,
      message,
      recommendation="rewrite the repair run from the validation report it cites",
    ),
  )
}

///|
fn repair_findings_match_actions(
  findings : Array[@moondata_core.ValidationFinding],
  actions : Array[@moondata_core.RepairAction],
) -> Bool {
  if findings.length() != actions.length() {
    return false
  }
  for finding in findings {
    let mut found = false
    for action in actions {
      if action.rule_id == finding.rule_id &&
        action.severity == finding.severity &&
        action.artifact_kind == finding.artifact_kind &&
        action.artifact_id == finding.artifact_id &&
        action.reason == finding.message &&
        action.recommendation == finding.recommendation {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
fn add_repair_source_validation_consistency_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  run : @moondata_core.RepairRun,
) -> Unit {
  if run.validation_report_id == "" {
    return
  }
  let report_json = match
    referenced_manifest_json(
      findings,
      entries,
      "validation-report",
      run.validation_report_id,
    ) {
    Some(value) => value
    None => return
  }
  let report : @moondata_core.ValidationReport = @json.from_json(report_json) catch {
    _ => return
  }
  if run.validation_status != report.status {
    add_repair_source_validation_mismatch(
      findings,
      entry,
      "repair-run-validation-status-mismatch",
      "repair run validation status \{run.validation_status} does not match report status \{report.status}",
    )
  }
  if run.generated_at_ms != report.generated_at_ms {
    add_repair_source_validation_mismatch(
      findings,
      entry,
      "repair-run-validation-timestamp-mismatch",
      "repair run timestamp \{run.generated_at_ms} does not match report timestamp \{report.generated_at_ms}",
    )
  }
  if run.action_count != report.finding_count ||
    run.blocker_count != report.blocker_count ||
    run.warning_count != report.warning_count {
    add_repair_source_validation_mismatch(
      findings, entry, "repair-run-validation-count-mismatch", "repair run action and severity counts do not match the cited validation report",
    )
  }
  if !repair_findings_match_actions(report.findings, run.actions) {
    add_repair_source_validation_mismatch(
      findings, entry, "repair-run-validation-action-mismatch", "repair run actions do not match the cited validation report findings",
    )
  }
}

///|
fn add_repair_run_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let run : @moondata_core.RepairRun = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, run.repair_run_id)
  if run.validation_report_id != "" {
    add_missing_catalog_ref(
      findings,
      entries,
      entry,
      "validation-report",
      run.validation_report_id,
      "validation_report_id",
    )
  }
  add_repair_count_mismatch(
    findings,
    entry,
    "action_count",
    run.action_count,
    run.actions.length(),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "blocker_count",
    run.blocker_count,
    count_repair_action_severity(run.actions, "blocker"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "warning_count",
    run.warning_count,
    count_repair_action_severity(run.actions, "warning"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "missing_payload_count",
    run.missing_payload_count,
    count_repair_action_category(run.actions, "missing-payload"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "unmanaged_payload_count",
    run.unmanaged_payload_count,
    count_repair_action_category(run.actions, "unmanaged-payload"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "metadata_conflict_count",
    run.metadata_conflict_count,
    count_repair_action_category(run.actions, "metadata-conflict"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "unsafe_ref_count",
    run.unsafe_ref_count,
    count_repair_action_category(run.actions, "unsafe-ref"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "external_ref_count",
    run.external_ref_count,
    count_repair_action_category(run.actions, "external-ref"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "non_payload_ref_count",
    run.non_payload_ref_count,
    count_repair_action_category(run.actions, "non-payload-ref"),
  )
  add_repair_count_mismatch(
    findings,
    entry,
    "manifest_surface_ref_count",
    run.manifest_surface_ref_count,
    count_repair_action_category(run.actions, "manifest-surface-ref"),
  )
  add_repair_source_validation_consistency_findings(
    findings, entries, entry, run,
  )
}

///|
fn repair_run_action(
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
fn add_repair_receipt_mismatch(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  rule_id : String,
  message : String,
) -> Unit {
  findings.push(
    @moondata_core.validation_finding(
      rule_id,
      "blocker",
      entry.artifact_kind,
      entry.artifact_id,
      message,
      recommendation="rewrite the repair receipt from the repair run action it records",
    ),
  )
}

///|
fn validation_report_entry_count_covers_catalog(
  entries : Array[@moondata_core.CatalogEntry],
  report : @moondata_core.ValidationReport,
) -> Bool {
  report.catalog_entry_count == entries.length() ||
  (
    report.catalog_entry_count + 1 == entries.length() &&
    catalog_has(entries, "validation-report", report.validation_report_id)
  )
}

///|
fn add_repair_receipt_validation_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  receipt : @moondata_core.RepairReceipt,
) -> Unit {
  if receipt.validation_report_id == "" {
    return
  }
  let report_json = match
    referenced_manifest_json(
      findings,
      entries,
      "validation-report",
      receipt.validation_report_id,
    ) {
    Some(value) => value
    None => return
  }
  let report : @moondata_core.ValidationReport = @json.from_json(report_json) catch {
    _ => return
  }
  if receipt.status == "applied" && report.status != "passed" {
    add_repair_receipt_mismatch(
      findings,
      entry,
      "repair-receipt-validation-not-passed",
      "applied repair receipt cites validation report \{receipt.validation_report_id} with status \{report.status}",
    )
  }
  if receipt.status == "applied" &&
    !validation_report_entry_count_covers_catalog(entries, report) {
    add_repair_receipt_mismatch(
      findings,
      entry,
      "repair-receipt-validation-catalog-stale",
      "applied repair receipt cites validation report \{receipt.validation_report_id} covering \{report.catalog_entry_count} catalog entries, but current catalog has \{entries.length()} entries",
    )
  }
  if report.generated_at_ms < receipt.applied_at_ms {
    add_repair_receipt_mismatch(
      findings,
      entry,
      "repair-receipt-validation-before-repair",
      "repair receipt cites validation report \{receipt.validation_report_id} generated before receipt application time",
    )
  }
}

///|
fn add_repair_receipt_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let receipt : @moondata_core.RepairReceipt = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, receipt.repair_receipt_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "repair-run",
    receipt.repair_run_id,
    "repair_run_id",
  )
  if receipt.validation_report_id != "" {
    add_missing_catalog_ref(
      findings,
      entries,
      entry,
      "validation-report",
      receipt.validation_report_id,
      "validation_report_id",
    )
  }
  add_repair_receipt_validation_findings(findings, entries, entry, receipt)
  let run_json = match
    referenced_manifest_json(
      findings,
      entries,
      "repair-run",
      receipt.repair_run_id,
    ) {
    Some(value) => value
    None => return
  }
  let run : @moondata_core.RepairRun = @json.from_json(run_json) catch {
    _ => return
  }
  match repair_run_action(run, receipt.action_id) {
    Some(action) => {
      if receipt.operation_kind != action.operation_kind {
        add_repair_receipt_mismatch(
          findings,
          entry,
          "repair-receipt-operation-mismatch",
          "repair receipt operation \{receipt.operation_kind} does not match action operation \{action.operation_kind}",
        )
      }
      if receipt.target_ref != action.target_ref {
        add_repair_receipt_mismatch(
          findings,
          entry,
          "repair-receipt-target-mismatch",
          "repair receipt target \{receipt.target_ref} does not match action target \{action.target_ref}",
        )
      }
    }
    None =>
      add_repair_receipt_mismatch(
        findings,
        entry,
        "repair-receipt-action-missing",
        "repair receipt references missing action \{receipt.action_id} in repair run \{receipt.repair_run_id}",
      )
  }
  add_moondata_ref_findings(
    findings,
    entries,
    entry,
    receipt.evidence_refs,
    "evidence_refs",
  )
}
