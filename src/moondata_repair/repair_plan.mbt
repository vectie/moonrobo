///|
pub(all) struct MoonDataRepairAction {
  action_id : String
  category : String
  severity : String
  artifact_kind : String
  artifact_id : String
  rule_id : String
  reason : String
  recommendation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataRepairPlan {
  root : String
  validation_report_id : String
  validation_status : String
  generated_at_ms : Int64
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
  actions : Array[MoonDataRepairAction]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

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
    _ => "integrity"
  }
}

///|
fn repair_action(
  index : Int,
  finding : @moondata_core.ValidationFinding,
) -> MoonDataRepairAction {
  {
    action_id: "repair-\{index + 1}",
    category: repair_category(finding.rule_id),
    severity: finding.severity,
    artifact_kind: finding.artifact_kind,
    artifact_id: finding.artifact_id,
    rule_id: finding.rule_id,
    reason: finding.message,
    recommendation: finding.recommendation,
  }
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
fn count_action(counts : RepairCounts, action : MoonDataRepairAction) -> Unit {
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
fn repair_counts(actions : Array[MoonDataRepairAction]) -> RepairCounts {
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
  actions : Array[MoonDataRepairAction],
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
  "MoonData repair plan: \{action_count} action(s), \{counts.blocker_count} blocker(s), \{counts.warning_count} warning(s), \{counts.missing_payload_count} missing payload(s), \{counts.unmanaged_payload_count} unmanaged payload(s), \{counts.metadata_conflict_count} metadata conflict(s)"
}

///|
pub fn plan_repairs(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[MoonDataRepairPlan, @moondata_store.MoonDataStoreIssue] {
  let report = match @moondata_validate.validate_root(root, generated_at_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let actions : Array[MoonDataRepairAction] = []
  for index in 0..<report.findings.length() {
    actions.push(repair_action(index, report.findings[index]))
  }
  let counts = repair_counts(actions)
  Ok({
    root,
    validation_report_id: report.validation_report_id,
    validation_status: report.status,
    generated_at_ms: report.generated_at_ms,
    action_count: actions.length(),
    blocker_count: counts.blocker_count,
    warning_count: counts.warning_count,
    missing_payload_count: counts.missing_payload_count,
    unmanaged_payload_count: counts.unmanaged_payload_count,
    metadata_conflict_count: counts.metadata_conflict_count,
    unsafe_ref_count: counts.unsafe_ref_count,
    external_ref_count: counts.external_ref_count,
    non_payload_ref_count: counts.non_payload_ref_count,
    manifest_surface_ref_count: counts.manifest_surface_ref_count,
    actions,
    refs: repair_refs(actions),
    summary: repair_summary(actions.length(), counts),
  })
}
