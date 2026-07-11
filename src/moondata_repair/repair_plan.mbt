///|
pub(all) struct StoredRepairRunResult {
  root : String
  repair_run_id : @moondata_core.RepairRunId
  repair_run_path : String
  catalog_path : String
  catalog_entry_count : Int
  repair_run : @moondata_core.RepairRun
  validation_result : @moondata_validate.StoredValidationResult
} derive(Debug, Eq, ToJson, FromJson)

///|
fn repair_run_id(generated_at_ms : Int64) -> @moondata_core.RepairRunId {
  "repair-\{generated_at_ms}"
}

///|
fn repair_category(rule_id : String) -> String {
  match rule_id {
    "data-ref-missing-local-payload" => "missing-payload"
    "moondata-unmanaged-local-payload" => "unmanaged-payload"
    "data-ref-uri-byte-count-conflict" => "metadata-conflict"
    "data-ref-uri-checksum-conflict" => "metadata-conflict"
    "data-ref-unsafe-local-uri" => "unsafe-ref"
    "robot-model-unsafe-embedded-uri" => "unsafe-ref"
    "data-ref-external-uri" => "external-ref"
    "robot-model-external-package-uri" => "external-ref"
    "robot-model-external-file-uri" => "external-ref"
    "data-ref-outside-payload-root" => "non-payload-ref"
    "data-ref-points-to-manifest" => "manifest-surface-ref"
    "robot-model-undeclared-asset-uri" => "manifest-surface-ref"
    _ => "integrity"
  }
}

///|
fn repair_operation_kind(rule_id : String) -> String {
  match rule_id {
    "data-ref-missing-local-payload" => "restore-or-remove-payload-ref"
    "moondata-unmanaged-local-payload" => "declare-or-remove-payload"
    "data-ref-uri-byte-count-conflict" => "rewrite-payload-metadata"
    "data-ref-uri-checksum-conflict" => "rewrite-payload-metadata"
    "data-ref-unsafe-local-uri" => "rewrite-unsafe-ref"
    "robot-model-unsafe-embedded-uri" => "rewrite-unsafe-ref"
    "data-ref-external-uri" => "materialize-external-ref"
    "robot-model-external-package-uri" => "materialize-external-ref"
    "robot-model-external-file-uri" => "materialize-external-ref"
    "data-ref-outside-payload-root" => "move-ref-to-payload-root"
    "data-ref-points-to-manifest" => "split-manifest-from-payload"
    "robot-model-undeclared-asset-uri" => "declare-or-remove-embedded-asset-ref"
    _ => "repair-integrity"
  }
}

///|
fn repair_target_ref(finding : @moondata_core.ValidationFinding) -> String {
  if finding.artifact_kind == "" {
    finding.artifact_id
  } else if finding.artifact_id == "" {
    finding.artifact_kind
  } else {
    "\{finding.artifact_kind}:\{finding.artifact_id}"
  }
}

///|
fn repair_action(
  index : Int,
  finding : @moondata_core.ValidationFinding,
) -> @moondata_core.RepairAction {
  @moondata_core.repair_action(
    "repair-action-\{index + 1}",
    repair_category(finding.rule_id),
    finding.severity,
    finding.artifact_kind,
    finding.artifact_id,
    finding.rule_id,
    finding.message,
    finding.recommendation,
    operation_kind=repair_operation_kind(finding.rule_id),
    target_ref=repair_target_ref(finding),
  )
}

///|
priv struct RepairCounts {
  mut blocker_count : Int
  mut warning_count : Int
  mut missing_payload_count : Int
  mut unmanaged_payload_count : Int
  mut metadata_conflict_count : Int
  mut unsafe_ref_count : Int
  mut external_ref_count : Int
  mut non_payload_ref_count : Int
  mut manifest_surface_ref_count : Int
}

///|
fn count_action(
  counts : RepairCounts,
  action : @moondata_core.RepairAction,
) -> Unit {
  match action.severity {
    "blocker" => counts.blocker_count += 1
    "warning" => counts.warning_count += 1
    _ => ()
  }
  match action.category {
    "missing-payload" => counts.missing_payload_count += 1
    "unmanaged-payload" => counts.unmanaged_payload_count += 1
    "metadata-conflict" => counts.metadata_conflict_count += 1
    "unsafe-ref" => counts.unsafe_ref_count += 1
    "external-ref" => counts.external_ref_count += 1
    "non-payload-ref" => counts.non_payload_ref_count += 1
    "manifest-surface-ref" => counts.manifest_surface_ref_count += 1
    _ => ()
  }
}

///|
fn repair_counts(actions : Array[@moondata_core.RepairAction]) -> RepairCounts {
  let counts = {
    blocker_count: 0,
    warning_count: 0,
    missing_payload_count: 0,
    unmanaged_payload_count: 0,
    metadata_conflict_count: 0,
    unsafe_ref_count: 0,
    external_ref_count: 0,
    non_payload_ref_count: 0,
    manifest_surface_ref_count: 0,
  }
  for action in actions {
    count_action(counts, action)
  }
  counts
}

///|
fn repair_refs(
  actions : Array[@moondata_core.RepairAction],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for action in actions {
    refs.push(
      @moondata_core.moondata_ref(
        "repair-action",
        action.action_id,
        action.artifact_id,
        "\{action.category} \{action.severity} from \{action.rule_id}",
      ),
    )
  }
  refs
}

///|
fn repair_summary(action_count : Int, counts : RepairCounts) -> String {
  "MoonData repair run: \{action_count} action(s), \{counts.blocker_count} blocker(s), \{counts.warning_count} warning(s), \{counts.missing_payload_count} missing payload(s), \{counts.unmanaged_payload_count} unmanaged payload(s), \{counts.metadata_conflict_count} metadata conflict(s)"
}

///|
fn repair_run_from_report(
  root : String,
  report : @moondata_core.ValidationReport,
) -> @moondata_core.RepairRun {
  let actions : Array[@moondata_core.RepairAction] = []
  for index in 0..<report.findings.length() {
    actions.push(repair_action(index, report.findings[index]))
  }
  let counts = repair_counts(actions)
  @moondata_core.repair_run(
    repair_run_id(report.generated_at_ms),
    root,
    report.validation_report_id,
    report.status,
    report.generated_at_ms,
    actions.length(),
    counts.blocker_count,
    counts.warning_count,
    counts.missing_payload_count,
    counts.unmanaged_payload_count,
    counts.metadata_conflict_count,
    counts.unsafe_ref_count,
    counts.external_ref_count,
    counts.non_payload_ref_count,
    counts.manifest_surface_ref_count,
    actions,
    repair_refs(actions),
    repair_summary(actions.length(), counts),
  )
}

///|
pub fn plan_repairs(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[@moondata_core.RepairRun, @moondata_store.MoonDataStoreIssue] {
  let report = match @moondata_validate.validate_root(root, generated_at_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(repair_run_from_report(root, report))
}

///|
pub fn write_repair_run(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[StoredRepairRunResult, @moondata_store.MoonDataStoreIssue] {
  let validation_result = match
    @moondata_validate.validate_and_write_root(root, generated_at_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let run = repair_run_from_report(root, validation_result.report)
  let persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let rebuilt = match @moondata_index.rebuild_catalog(root, generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    repair_run_id: run.repair_run_id,
    repair_run_path: persisted.path,
    catalog_path: rebuilt.catalog_path,
    catalog_entry_count: rebuilt.entry_count,
    repair_run: run,
    validation_result,
  })
}
