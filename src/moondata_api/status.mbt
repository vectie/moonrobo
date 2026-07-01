///|
pub(all) struct MoonDataStatus {
  root : String
  catalog_path : String
  generated_at_ms : Int64
  ready : Bool
  entry_count : Int
  dataset_count : Int
  quality_count : Int
  curation_count : Int
  annotation_count : Int
  replay_count : Int
  export_count : Int
  validation_count : Int
  latest_validation_report_id : String
  latest_validation_status : String
  latest_validation_finding_count : Int
  latest_validation_blocker_count : Int
  latest_validation_warning_count : Int
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn count_kind(catalog : @moondata_core.MoonDataCatalog, kind : String) -> Int {
  let mut count = 0
  for entry in catalog.entries {
    if entry.artifact_kind == kind {
      count += 1
    }
  }
  count
}

///|
fn latest_validation_entry(
  catalog : @moondata_core.MoonDataCatalog,
) -> @moondata_core.CatalogEntry? {
  let mut latest : @moondata_core.CatalogEntry? = None
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      latest = Some(entry)
    }
  }
  latest
}

///|
fn status_from_catalog_status(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  latest_validation_report_id : String,
  latest_validation_status : String,
  latest_validation_finding_count : Int,
  latest_validation_blocker_count : Int,
  latest_validation_warning_count : Int,
) -> MoonDataStatus {
  let dataset_count = count_kind(catalog, "dataset")
  let quality_count = count_kind(catalog, "quality-run")
  let transform_count = count_kind(catalog, "transform-run")
  let version_count = count_kind(catalog, "dataset-version")
  let annotation_count = count_kind(catalog, "annotation-set")
  let replay_count = count_kind(catalog, "replay-artifact")
  let export_count = count_kind(catalog, "export-manifest")
  let validation_count = count_kind(catalog, "validation-report")
  {
    root,
    catalog_path: @moondata_store.catalog_path(root),
    generated_at_ms: catalog.generated_at_ms,
    ready: catalog.entry_count > 0 && latest_validation_status == "passed",
    entry_count: catalog.entry_count,
    dataset_count,
    quality_count,
    curation_count: transform_count + version_count,
    annotation_count,
    replay_count,
    export_count,
    validation_count,
    latest_validation_report_id,
    latest_validation_status,
    latest_validation_finding_count,
    latest_validation_blocker_count,
    latest_validation_warning_count,
    refs: @moondata_core.catalog_refs(catalog),
  }
}

///|
pub fn status_from_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> MoonDataStatus {
  let latest_validation = latest_validation_entry(catalog)
  let latest_validation_report_id = match latest_validation {
    Some(entry) => entry.artifact_id
    None => ""
  }
  let latest_validation_status = match latest_validation {
    Some(_) => "catalog-only"
    None => "unvalidated"
  }
  status_from_catalog_status(
    root, catalog, latest_validation_report_id, latest_validation_status, 0, 0, 0,
  )
}

///|
priv struct LatestValidationSummary {
  validation_report_id : String
  status : String
  finding_count : Int
  blocker_count : Int
  warning_count : Int
}

///|
fn latest_validation_summary_from_store(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> LatestValidationSummary {
  let mut latest_id = ""
  let mut latest_status = ""
  let mut latest_finding_count = 0
  let mut latest_blocker_count = 0
  let mut latest_warning_count = 0
  let mut latest_generated_at_ms = -1L
  let mut missing_id = ""
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      match @moondata_store.read_validation_report(root, entry.artifact_id) {
        Ok(report) =>
          if report.generated_at_ms > latest_generated_at_ms {
            latest_id = report.validation_report_id
            latest_status = report.status
            latest_finding_count = report.finding_count
            latest_blocker_count = report.blocker_count
            latest_warning_count = report.warning_count
            latest_generated_at_ms = report.generated_at_ms
          }
        Err(_) => if missing_id == "" { missing_id = entry.artifact_id }
      }
    }
  }
  if latest_id == "" {
    if missing_id == "" {
      {
        validation_report_id: "",
        status: "unvalidated",
        finding_count: 0,
        blocker_count: 0,
        warning_count: 0,
      }
    } else {
      {
        validation_report_id: missing_id,
        status: "missing",
        finding_count: 0,
        blocker_count: 0,
        warning_count: 0,
      }
    }
  } else if latest_generated_at_ms < catalog.generated_at_ms {
    {
      validation_report_id: latest_id,
      status: "stale",
      finding_count: latest_finding_count,
      blocker_count: latest_blocker_count,
      warning_count: latest_warning_count,
    }
  } else {
    {
      validation_report_id: latest_id,
      status: latest_status,
      finding_count: latest_finding_count,
      blocker_count: latest_blocker_count,
      warning_count: latest_warning_count,
    }
  }
}

///|
pub fn read_status(
  root : String,
) -> Result[MoonDataStatus, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let latest_validation = latest_validation_summary_from_store(root, catalog)
  Ok(
    status_from_catalog_status(
      root,
      catalog,
      latest_validation.validation_report_id,
      latest_validation.status,
      latest_validation.finding_count,
      latest_validation.blocker_count,
      latest_validation.warning_count,
    ),
  )
}
