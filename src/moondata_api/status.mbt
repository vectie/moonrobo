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
    root, catalog, latest_validation_report_id, latest_validation_status,
  )
}

///|
fn latest_validation_status_from_store(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> (String, String) {
  let mut latest_id = ""
  let mut latest_status = ""
  let mut latest_generated_at_ms = -1L
  let mut missing_id = ""
  for entry in catalog.entries {
    if entry.artifact_kind == "validation-report" {
      match @moondata_store.read_validation_report(root, entry.artifact_id) {
        Ok(report) =>
          if report.generated_at_ms > latest_generated_at_ms {
            latest_id = report.validation_report_id
            latest_status = report.status
            latest_generated_at_ms = report.generated_at_ms
          }
        Err(_) => if missing_id == "" { missing_id = entry.artifact_id }
      }
    }
  }
  if latest_id == "" {
    if missing_id == "" {
      ("", "unvalidated")
    } else {
      (missing_id, "missing")
    }
  } else if latest_generated_at_ms < catalog.generated_at_ms {
    (latest_id, "stale")
  } else {
    (latest_id, latest_status)
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
  let (latest_validation_report_id, latest_validation_status) = latest_validation_status_from_store(
    root, catalog,
  )
  Ok(
    status_from_catalog_status(
      root, catalog, latest_validation_report_id, latest_validation_status,
    ),
  )
}
