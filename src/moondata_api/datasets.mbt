///|
pub(all) struct MoonDataDatasetQuery {
  kind : String
  status : String
  source_id : String
  capture_id : String
  episode_id : String
  data_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDatasetList {
  root : String
  query : MoonDataDatasetQuery
  dataset_count : Int
  datasets : Array[@moondata_core.DatasetManifest]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn dataset_query(
  kind? : String = "",
  status? : String = "",
  source_id? : String = "",
  capture_id? : String = "",
  episode_id? : String = "",
  data_kind? : String = "",
) -> MoonDataDatasetQuery {
  { kind, status, source_id, capture_id, episode_id, data_kind }
}

///|
fn dataset_query_has_filters(query : MoonDataDatasetQuery) -> Bool {
  query.kind != "" ||
  query.status != "" ||
  query.source_id != "" ||
  query.capture_id != "" ||
  query.episode_id != "" ||
  query.data_kind != ""
}

///|
fn dataset_contains_id(ids : Array[String], id : String) -> Bool {
  for candidate in ids {
    if candidate == id {
      return true
    }
  }
  false
}

///|
fn dataset_has_data_kind(
  dataset : @moondata_core.DatasetManifest,
  data_kind : String,
) -> Bool {
  if data_kind == "" {
    return true
  }
  for data_ref in dataset.data_refs {
    if data_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn dataset_matches(
  dataset : @moondata_core.DatasetManifest,
  query : MoonDataDatasetQuery,
) -> Bool {
  if query.kind != "" && dataset.kind != query.kind {
    return false
  }
  if query.status != "" && dataset.status != query.status {
    return false
  }
  if query.source_id != "" &&
    !dataset_contains_id(dataset.source_ids, query.source_id) {
    return false
  }
  if query.capture_id != "" &&
    !dataset_contains_id(dataset.capture_ids, query.capture_id) {
    return false
  }
  if query.episode_id != "" &&
    !dataset_contains_id(dataset.episode_ids, query.episode_id) {
    return false
  }
  dataset_has_data_kind(dataset, query.data_kind)
}

///|
fn dataset_kind_from_path(path : String) -> String {
  if path.contains("/datasets/raw/") {
    "raw"
  } else if path.contains("/datasets/curated/") {
    "curated"
  } else {
    "canonical"
  }
}

///|
fn dataset_refs(
  root : String,
  datasets : Array[@moondata_core.DatasetManifest],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for dataset in datasets {
    refs.push(
      @moondata_core.moondata_ref(
        "dataset",
        dataset.dataset_id,
        @moondata_store.dataset_kind_path(
          root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "\{dataset.kind} dataset \{dataset.status}",
      ),
    )
  }
  refs
}

///|
pub fn list_datasets(
  root : String,
  query? : MoonDataDatasetQuery = dataset_query(),
) -> Result[MoonDataDatasetList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let datasets : Array[@moondata_core.DatasetManifest] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "dataset" {
      let dataset = match
        @moondata_store.read_dataset_kind(
          root,
          dataset_kind_from_path(entry.manifest_path),
          entry.artifact_id,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if dataset_query_has_filters(query) {
        dataset_matches(dataset, query)
      } else {
        true
      }
      if matches {
        datasets.push(dataset)
      }
    }
  }
  let refs = dataset_refs(root, datasets)
  Ok({
    root,
    query,
    dataset_count: datasets.length(),
    datasets,
    refs,
    summary: "MoonData datasets: \{datasets.length()} match(es)",
  })
}
