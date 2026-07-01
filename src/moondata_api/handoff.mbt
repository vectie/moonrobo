///|
pub(all) struct MoonDataHandoff {
  root : String
  version_id : @moondata_core.DatasetVersionId
  ready : Bool
  readiness_status : String
  validation_report_id : String
  validation_status : String
  validation_generated_at_ms : Int64
  validation_catalog_entry_count : Int
  validation_covers_catalog : Bool
  validation_finding_count : Int
  validation_blocker_count : Int
  validation_warning_count : Int
  repair_count : Int
  repair_receipt_count : Int
  repair_work_count : Int
  repair_open_count : Int
  repair_applied_count : Int
  repair_applied_unvalidated_count : Int
  repair_failed_count : Int
  repair_pending_count : Int
  validation_findings : Array[@moondata_core.ValidationFinding]
  status : MoonDataStatus
  context : MoonDataContext
  artifacts : MoonDataArtifactList
  lineage : MoonDataLineageGraph
  slice : MoonDataDatasetSlice?
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
  output_refs : Array[@moondata_core.DataRef]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn push_unique_ref(
  refs : Array[@moondata_core.MoonDataRef],
  candidate : @moondata_core.MoonDataRef,
) -> Unit {
  for existing in refs {
    if existing.artifact_kind == candidate.artifact_kind &&
      existing.artifact_id == candidate.artifact_id {
      return
    }
  }
  refs.push(candidate)
}

///|
fn add_refs(
  refs : Array[@moondata_core.MoonDataRef],
  candidates : Array[@moondata_core.MoonDataRef],
) -> Unit {
  for candidate in candidates {
    push_unique_ref(refs, candidate)
  }
}

///|
fn handoff_refs(
  context : MoonDataContext,
  artifacts : MoonDataArtifactList,
  lineage : MoonDataLineageGraph,
  slice : MoonDataDatasetSlice?,
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  add_refs(refs, context.refs)
  add_refs(refs, artifacts.refs)
  add_refs(refs, lineage.refs)
  match slice {
    Some(value) => add_refs(refs, value.refs)
    None => ()
  }
  refs
}

///|
fn handoff_summary(
  status : MoonDataStatus,
  lineage : MoonDataLineageGraph,
  slice : MoonDataDatasetSlice?,
  readiness_status : String,
  output_ref_count : Int,
  total_output_byte_count : Int64,
) -> String {
  let slice_text = match slice {
    Some(value) => "slice \{value.version_id} \{value.status}"
    None => "no version slice"
  }
  "MoonData handoff \{readiness_status}: \{status.entry_count} cataloged artifact(s), validation \{status.latest_validation_status}, \{status.latest_validation_blocker_count} blocker(s), \{status.latest_validation_warning_count} warning(s), repair work \{status.repair_work_count} action(s), \{status.repair_open_count} open, \{status.repair_applied_unvalidated_count} applied without validation, \{lineage.lineage_count} lineage graph(s), \{output_ref_count} output ref(s), \{total_output_byte_count} byte(s), \{slice_text}"
}

///|
fn normalized_validation_status(status : MoonDataStatus) -> String {
  if status.latest_validation_status == "missing" {
    "missing-validation"
  } else if status.latest_validation_status == "passed" &&
    status.latest_validation_covers_catalog &&
    status_has_repair_pressure(status) {
    "repair-pressure"
  } else if status.latest_validation_status == "" {
    "unvalidated"
  } else {
    status.latest_validation_status
  }
}

///|
fn handoff_readiness_status(
  status : MoonDataStatus,
  slice : MoonDataDatasetSlice?,
) -> String {
  if !status.ready {
    normalized_validation_status(status)
  } else {
    match slice {
      Some(value) => if value.ready { "ready" } else { value.status }
      None => "ready"
    }
  }
}

///|
fn latest_validation_findings(
  root : String,
  status : MoonDataStatus,
) -> Result[
  Array[@moondata_core.ValidationFinding],
  @moondata_store.MoonDataStoreIssue,
] {
  if status.latest_validation_report_id == "" ||
    status.latest_validation_status == "missing" ||
    status.latest_validation_status == "unvalidated" {
    return Ok([])
  }
  let report = match
    @moondata_store.read_validation_report(
      root,
      status.latest_validation_report_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(report.findings)
}

///|
priv struct HandoffOutputEvidence {
  output_refs : Array[@moondata_core.DataRef]
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
}

///|
fn output_refs_from_export_views(
  exports : Array[MoonDataExportView],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for published in exports {
    for output in published.output_refs {
      refs.push(output)
    }
  }
  refs
}

///|
fn output_refs_from_export_manifests(
  exports : Array[@moondata_core.ExportManifest],
) -> Array[@moondata_core.DataRef] {
  let refs : Array[@moondata_core.DataRef] = []
  for published in exports {
    for output in published.output_refs {
      refs.push(output)
    }
  }
  refs
}

///|
fn handoff_output_evidence(
  root : String,
  slice : MoonDataDatasetSlice?,
) -> Result[HandoffOutputEvidence, @moondata_store.MoonDataStoreIssue] {
  match slice {
    Some(value) => {
      let output_refs = output_refs_from_export_views(value.exports)
      Ok({
        output_refs,
        output_ref_count: value.output_ref_count,
        total_output_byte_count: value.total_output_byte_count,
        output_checksums: value.output_checksums,
      })
    }
    None => {
      let exports = match list_exports(root) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let output_refs = output_refs_from_export_manifests(exports.exports)
      Ok({
        output_refs,
        output_ref_count: exports.output_ref_count,
        total_output_byte_count: exports.total_output_byte_count,
        output_checksums: exports.output_checksums,
      })
    }
  }
}

///|
pub fn read_handoff(
  root : String,
  version_id? : @moondata_core.DatasetVersionId = "",
) -> Result[MoonDataHandoff, @moondata_store.MoonDataStoreIssue] {
  let status = match read_status(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let artifacts = match list_artifacts(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lineage = match read_lineage_graph(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let slice = if version_id == "" {
    None
  } else {
    match read_dataset_slice(root, version_id) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  }
  let context = context_from_status(status)
  let refs = handoff_refs(context, artifacts, lineage, slice)
  let readiness_status = handoff_readiness_status(status, slice)
  let validation_findings = match latest_validation_findings(root, status) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output_evidence = match handoff_output_evidence(root, slice) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    version_id,
    ready: readiness_status == "ready",
    readiness_status,
    validation_report_id: status.latest_validation_report_id,
    validation_status: status.latest_validation_status,
    validation_generated_at_ms: status.latest_validation_generated_at_ms,
    validation_catalog_entry_count: status.latest_validation_catalog_entry_count,
    validation_covers_catalog: status.latest_validation_covers_catalog,
    validation_finding_count: status.latest_validation_finding_count,
    validation_blocker_count: status.latest_validation_blocker_count,
    validation_warning_count: status.latest_validation_warning_count,
    repair_count: status.repair_count,
    repair_receipt_count: status.repair_receipt_count,
    repair_work_count: status.repair_work_count,
    repair_open_count: status.repair_open_count,
    repair_applied_count: status.repair_applied_count,
    repair_applied_unvalidated_count: status.repair_applied_unvalidated_count,
    repair_failed_count: status.repair_failed_count,
    repair_pending_count: status.repair_pending_count,
    validation_findings,
    status,
    context,
    artifacts,
    lineage,
    slice,
    output_ref_count: output_evidence.output_ref_count,
    total_output_byte_count: output_evidence.total_output_byte_count,
    output_checksums: output_evidence.output_checksums,
    output_refs: output_evidence.output_refs,
    refs,
    summary: handoff_summary(
      status,
      lineage,
      slice,
      readiness_status,
      output_evidence.output_ref_count,
      output_evidence.total_output_byte_count,
    ),
  })
}
