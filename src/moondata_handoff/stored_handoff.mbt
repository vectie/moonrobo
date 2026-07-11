///|
pub(all) struct StoredHandoffRequest {
  root : String
  version_id : @moondata_core.DatasetVersionId
  handoff_dossier_id : @moondata_core.HandoffDossierId
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredHandoffResult {
  root : String
  version_id : @moondata_core.DatasetVersionId
  handoff_dossier_id : @moondata_core.HandoffDossierId
  ready : Bool
  source_readiness_status : String
  source_validation_report_id : String
  source_repair_work_count : Int
  source_repair_open_count : Int
  source_repair_applied_unvalidated_count : Int
  output_ref_count : Int
  total_output_byte_count : Int64
  output_refs : Array[@moondata_core.DataRef]
  ref_count : Int
  catalog_path : String
  catalog_entry_count : Int
  dossier : @moondata_core.HandoffDossier
  dossier_manifest : @moondata_store.PersistedManifest
  validation_result : @moondata_validate.StoredValidationResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn stored_handoff_request(
  root : String,
  generated_at_ms : Int64,
  version_id? : @moondata_core.DatasetVersionId = "",
  handoff_dossier_id? : @moondata_core.HandoffDossierId = "",
) -> StoredHandoffRequest {
  let id = if handoff_dossier_id == "" {
    if version_id == "" {
      "handoff-root-\{generated_at_ms}"
    } else {
      "handoff-\{version_id}-\{generated_at_ms}"
    }
  } else {
    handoff_dossier_id
  }
  { root, version_id, handoff_dossier_id: id, generated_at_ms }
}

///|
fn dossier_summary(
  source : @moondata_api.MoonDataHandoff,
  generated_at_ms : Int64,
) -> String {
  "MoonData handoff dossier \{source.readiness_status}: version \{source.version_id}, validation \{source.validation_status}, repair work \{source.repair_work_count} action(s), \{source.repair_open_count} open, \{source.repair_applied_unvalidated_count} applied without validation, \{source.output_ref_count} output ref(s), \{source.total_output_byte_count} byte(s), generated \{generated_at_ms}"
}

///|
fn handoff_dossier_from_source(
  request : StoredHandoffRequest,
  source : @moondata_api.MoonDataHandoff,
) -> @moondata_core.HandoffDossier {
  @moondata_core.handoff_dossier(
    request.handoff_dossier_id,
    source.version_id,
    source.ready,
    source.readiness_status,
    source.validation_report_id,
    source.validation_status,
    source.validation_generated_at_ms,
    source.validation_catalog_entry_count,
    source.validation_covers_catalog,
    source.validation_finding_count,
    source.validation_blocker_count,
    source.validation_warning_count,
    source.repair_count,
    source.repair_receipt_count,
    source.repair_work_count,
    source.repair_open_count,
    source.repair_applied_count,
    source.repair_applied_unvalidated_count,
    source.repair_failed_count,
    source.repair_pending_count,
    source.output_refs,
    source.refs,
    source.validation_findings,
    request.generated_at_ms,
    dossier_summary(source, request.generated_at_ms),
  )
}

///|
pub fn materialize_stored_handoff(
  request : StoredHandoffRequest,
) -> Result[StoredHandoffResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let source = match
    @moondata_api.read_handoff(request.root, version_id=request.version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dossier = handoff_dossier_from_source(request, source)
  let dossier_manifest = match
    @moondata_store.write_handoff_dossier(request.root, dossier) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let catalog = match
    @moondata_index.rebuild_catalog(request.root, request.generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let validation = match
    @moondata_validate.validate_and_write_root(
      request.root,
      generated_at_ms=request.generated_at_ms + 1L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    version_id: source.version_id,
    handoff_dossier_id: dossier.handoff_dossier_id,
    ready: source.ready && validation.status == "passed",
    source_readiness_status: source.readiness_status,
    source_validation_report_id: source.validation_report_id,
    source_repair_work_count: source.repair_work_count,
    source_repair_open_count: source.repair_open_count,
    source_repair_applied_unvalidated_count: source.repair_applied_unvalidated_count,
    output_ref_count: source.output_ref_count,
    total_output_byte_count: source.total_output_byte_count,
    output_refs: source.output_refs,
    ref_count: dossier.ref_count,
    catalog_path: catalog.catalog_path,
    catalog_entry_count: catalog.entry_count,
    dossier,
    dossier_manifest,
    validation_result: validation,
  })
}
