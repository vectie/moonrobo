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
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  latest_validation_report_id : String
  latest_validation_status : String
  latest_validation_generated_at_ms : Int64
  latest_validation_catalog_entry_count : Int
  latest_validation_covers_catalog : Bool
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
priv struct ValidationListSummary {
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  latest_validation_report_id : String
  latest_validation_status : String
  latest_validation_generated_at_ms : Int64
  latest_validation_catalog_entry_count : Int
  latest_validation_covers_catalog : Bool
}

///|
fn validation_list_summary(
  catalog : @moondata_core.MoonDataCatalog,
  validations : Array[@moondata_core.ValidationReport],
) -> ValidationListSummary {
  let mut finding_count = 0
  let mut blocker_count = 0
  let mut warning_count = 0
  let mut latest_id = ""
  let mut latest_status = "unvalidated"
  let mut latest_generated_at_ms = -1L
  let mut latest_catalog_entry_count = 0
  for report in validations {
    finding_count += report.finding_count
    blocker_count += report.blocker_count
    warning_count += report.warning_count
    if report.generated_at_ms > latest_generated_at_ms {
      latest_id = report.validation_report_id
      latest_status = report.status
      latest_generated_at_ms = report.generated_at_ms
      latest_catalog_entry_count = report.catalog_entry_count
    }
  }
  if latest_id == "" {
    return {
      finding_count,
      blocker_count,
      warning_count,
      latest_validation_report_id: "",
      latest_validation_status: "unvalidated",
      latest_validation_generated_at_ms: 0L,
      latest_validation_catalog_entry_count: 0,
      latest_validation_covers_catalog: false,
    }
  }
  let covers_catalog = validation_covers_catalog(
    catalog, latest_id, latest_generated_at_ms, latest_catalog_entry_count,
  )
  {
    finding_count,
    blocker_count,
    warning_count,
    latest_validation_report_id: latest_id,
    latest_validation_status: if covers_catalog {
      latest_status
    } else {
      "stale"
    },
    latest_validation_generated_at_ms: latest_generated_at_ms,
    latest_validation_catalog_entry_count: latest_catalog_entry_count,
    latest_validation_covers_catalog: covers_catalog,
  }
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
  let evidence = validation_list_summary(catalog, validations)
  Ok({
    root,
    query,
    validation_count: validations.length(),
    finding_count: evidence.finding_count,
    blocker_count: evidence.blocker_count,
    warning_count: evidence.warning_count,
    latest_validation_report_id: evidence.latest_validation_report_id,
    latest_validation_status: evidence.latest_validation_status,
    latest_validation_generated_at_ms: evidence.latest_validation_generated_at_ms,
    latest_validation_catalog_entry_count: evidence.latest_validation_catalog_entry_count,
    latest_validation_covers_catalog: evidence.latest_validation_covers_catalog,
    validations,
    refs,
    summary: "MoonData validations: \{validations.length()} match(es), \{evidence.finding_count} finding(s), \{evidence.blocker_count} blocker(s), \{evidence.warning_count} warning(s), latest \{evidence.latest_validation_status}",
  })
}
