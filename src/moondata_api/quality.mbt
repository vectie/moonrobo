///|
pub(all) struct MoonDataQualityQuery {
  dataset_id : String
  episode_id : String
  status : String
  severity : String
  rule_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataQualityList {
  root : String
  query : MoonDataQualityQuery
  quality_count : Int
  quality_runs : Array[@moondata_core.QualityRun]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn quality_query(
  dataset_id? : String = "",
  episode_id? : String = "",
  status? : String = "",
  severity? : String = "",
  rule_id? : String = "",
) -> MoonDataQualityQuery {
  { dataset_id, episode_id, status, severity, rule_id }
}

///|
fn quality_query_has_filters(query : MoonDataQualityQuery) -> Bool {
  query.dataset_id != "" ||
  query.episode_id != "" ||
  query.status != "" ||
  query.severity != "" ||
  query.rule_id != ""
}

///|
fn quality_has_episode(
  run : @moondata_core.QualityRun,
  episode_id : String,
) -> Bool {
  if episode_id == "" {
    return true
  }
  for candidate in run.episode_ids {
    if candidate == episode_id {
      return true
    }
  }
  false
}

///|
fn quality_findings_match(
  findings : Array[@moondata_core.QualityFinding],
  severity : String,
  rule_id : String,
) -> Bool {
  if severity == "" && rule_id == "" {
    return true
  }
  for finding in findings {
    let severity_matches = severity == "" || finding.severity == severity
    let rule_matches = rule_id == "" || finding.rule_id == rule_id
    if severity_matches && rule_matches {
      return true
    }
  }
  false
}

///|
fn quality_run_matches(
  run : @moondata_core.QualityRun,
  query : MoonDataQualityQuery,
) -> Bool {
  if query.dataset_id != "" && run.dataset_id != query.dataset_id {
    return false
  }
  if query.status != "" && run.status != query.status {
    return false
  }
  if !quality_has_episode(run, query.episode_id) {
    return false
  }
  quality_findings_match(run.findings, query.severity, query.rule_id)
}

///|
fn quality_refs(
  root : String,
  quality_runs : Array[@moondata_core.QualityRun],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for run in quality_runs {
    refs.push(
      @moondata_core.moondata_ref(
        "quality-run",
        run.quality_run_id,
        @moondata_store.quality_run_path(root, run.quality_run_id),
        "\{run.status} \{run.finding_count} finding(s)",
      ),
    )
  }
  refs
}

///|
pub fn list_quality_runs(
  root : String,
  query? : MoonDataQualityQuery = quality_query(),
) -> Result[MoonDataQualityList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let quality_runs : Array[@moondata_core.QualityRun] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "quality-run" {
      let run = match
        @moondata_store.read_quality_run(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if quality_query_has_filters(query) {
        quality_run_matches(run, query)
      } else {
        true
      }
      if matches {
        quality_runs.push(run)
      }
    }
  }
  let refs = quality_refs(root, quality_runs)
  Ok({
    root,
    query,
    quality_count: quality_runs.length(),
    quality_runs,
    refs,
    summary: "MoonData quality runs: \{quality_runs.length()} match(es)",
  })
}
