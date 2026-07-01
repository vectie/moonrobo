///|
pub(all) struct MoonDataValidationQuery {
  status : String
  severity : String
  rule_id : String
  artifact_kind : String
  artifact_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataValidationList {
  root : String
  query : MoonDataValidationQuery
  validation_count : Int
  validations : Array[@moondata_core.ValidationReport]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn validation_query(
  status? : String = "",
  severity? : String = "",
  rule_id? : String = "",
  artifact_kind? : String = "",
  artifact_id? : String = "",
) -> MoonDataValidationQuery {
  { status, severity, rule_id, artifact_kind, artifact_id }
}

///|
fn validation_query_has_filters(query : MoonDataValidationQuery) -> Bool {
  query.status != "" ||
  query.severity != "" ||
  query.rule_id != "" ||
  query.artifact_kind != "" ||
  query.artifact_id != ""
}

///|
fn validation_query_has_finding_filters(
  query : MoonDataValidationQuery,
) -> Bool {
  query.severity != "" ||
  query.rule_id != "" ||
  query.artifact_kind != "" ||
  query.artifact_id != ""
}

///|
fn finding_matches(
  finding : @moondata_core.ValidationFinding,
  query : MoonDataValidationQuery,
) -> Bool {
  if query.severity != "" && finding.severity != query.severity {
    return false
  }
  if query.rule_id != "" && finding.rule_id != query.rule_id {
    return false
  }
  if query.artifact_kind != "" && finding.artifact_kind != query.artifact_kind {
    return false
  }
  query.artifact_id == "" || finding.artifact_id == query.artifact_id
}

///|
fn validation_findings_match(
  findings : Array[@moondata_core.ValidationFinding],
  query : MoonDataValidationQuery,
) -> Bool {
  if !validation_query_has_finding_filters(query) {
    return true
  }
  for finding in findings {
    if finding_matches(finding, query) {
      return true
    }
  }
  false
}

///|
fn validation_matches(
  report : @moondata_core.ValidationReport,
  query : MoonDataValidationQuery,
) -> Bool {
  if query.status != "" && report.status != query.status {
    return false
  }
  validation_findings_match(report.findings, query)
}

///|
fn validation_refs(
  root : String,
  validations : Array[@moondata_core.ValidationReport],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for report in validations {
    refs.push(
      @moondata_core.moondata_ref(
        "validation-report",
        report.validation_report_id,
        @moondata_store.validation_report_path(
          root,
          report.validation_report_id,
        ),
        "\{report.status} \{report.finding_count} finding(s)",
      ),
    )
  }
  refs
}

///|
pub fn list_validations(
  root : String,
  query? : MoonDataValidationQuery = validation_query(),
) -> Result[MoonDataValidationList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let validations : Array[@moondata_core.ValidationReport] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      let report = match
        @moondata_store.read_validation_report(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if validation_query_has_filters(query) {
        validation_matches(report, query)
      } else {
        true
      }
      if matches {
        validations.push(report)
      }
    }
  }
  let refs = validation_refs(root, validations)
  Ok({
    root,
    query,
    validation_count: validations.length(),
    validations,
    refs,
    summary: "MoonData validations: \{validations.length()} match(es)",
  })
}
