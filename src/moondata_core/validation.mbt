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
  catalog_entry_count : Int
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  findings : Array[ValidationFinding]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn validation_finding(
  rule_id : String,
  severity : String,
  artifact_kind : String,
  artifact_id : String,
  message : String,
  recommendation? : String = "",
) -> ValidationFinding {
  { rule_id, severity, artifact_kind, artifact_id, message, recommendation }
}

///|
pub fn validation_report(
  validation_report_id : String,
  root : String,
  generated_at_ms : Int64,
  status : String,
  catalog_entry_count : Int,
  finding_count : Int,
  blocker_count : Int,
  warning_count : Int,
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
