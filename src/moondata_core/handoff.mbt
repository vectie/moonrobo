///|
pub(all) struct HandoffDossier {
  handoff_dossier_id : HandoffDossierId
  version_id : DatasetVersionId
  source_ready : Bool
  source_readiness_status : String
  source_validation_report_id : String
  source_validation_status : String
  source_validation_generated_at_ms : Int64
  source_validation_catalog_entry_count : Int
  source_validation_covers_catalog : Bool
  source_validation_finding_count : Int
  source_validation_blocker_count : Int
  source_validation_warning_count : Int
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
  ref_count : Int
  refs : Array[MoonDataRef]
  validation_findings : Array[ValidationFinding]
  generated_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn handoff_dossier(
  handoff_dossier_id : HandoffDossierId,
  version_id : DatasetVersionId,
  source_ready : Bool,
  source_readiness_status : String,
  source_validation_report_id : String,
  source_validation_status : String,
  source_validation_generated_at_ms : Int64,
  source_validation_catalog_entry_count : Int,
  source_validation_covers_catalog : Bool,
  source_validation_finding_count : Int,
  source_validation_blocker_count : Int,
  source_validation_warning_count : Int,
  output_ref_count : Int,
  total_output_byte_count : Int64,
  output_checksums : Array[String],
  refs : Array[MoonDataRef],
  validation_findings : Array[ValidationFinding],
  generated_at_ms : Int64,
  summary : String,
) -> HandoffDossier {
  {
    handoff_dossier_id,
    version_id,
    source_ready,
    source_readiness_status,
    source_validation_report_id,
    source_validation_status,
    source_validation_generated_at_ms,
    source_validation_catalog_entry_count,
    source_validation_covers_catalog,
    source_validation_finding_count,
    source_validation_blocker_count,
    source_validation_warning_count,
    output_ref_count,
    total_output_byte_count,
    output_checksums,
    ref_count: refs.length(),
    refs,
    validation_findings,
    generated_at_ms,
    summary,
  }
}
