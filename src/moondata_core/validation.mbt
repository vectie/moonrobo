///|
pub(all) struct ValidationFinding {
  rule_id : String
  severity : String
  artifact_kind : String
  artifact_id : String
  message : String
  recommendation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ValidationReport {
  validation_report_id : String
  root : String
  generated_at_ms : Int64
  status : String
  catalog_entry_count : Int32
  finding_count : Int32
  blocker_count : Int32
  warning_count : Int32
  findings : Array[ValidationFinding]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn validation_finding(
  rule_id : String,
  severity : String,
  artifact_kind : String,
  artifact_id : String,
  message : String,
  recommendation~ : String = "",
) -> ValidationFinding {
  { rule_id, severity, artifact_kind, artifact_id, message, recommendation, }
}

///|
pub fn validation_report(
  validation_report_id : String,
  root : String,
  generated_at_ms : Int64,
  status : String,
  catalog_entry_count : Int32,
  finding_count : Int32,
  blocker_count : Int32,
  warning_count : Int32,
  findings : Array[ValidationFinding],
) -> ValidationReport {
  {
    validation_report_id,
    root,
    generated_at_ms,
    status,
    catalog_entry_count,
    finding_count,
    blocker_count,
    warning_count,
    findings,
  }
}
