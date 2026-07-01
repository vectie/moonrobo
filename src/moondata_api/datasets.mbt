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
  source_ref_count : Int
  capture_ref_count : Int
  episode_count : Int
  data_ref_count : Int
  total_data_byte_count : Int64
  latest_dataset_id : String
  latest_dataset_status : String
  latest_dataset_created_at_ms : Int64
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
priv struct DatasetListSummary {
  source_ref_count : Int
  capture_ref_count : Int
  episode_count : Int
  data_ref_count : Int
  total_data_byte_count : Int64
  latest_dataset_id : String
  latest_dataset_status : String
  latest_dataset_created_at_ms : Int64
}

///|
fn dataset_list_summary(
  datasets : Array[@moondata_core.DatasetManifest],
) -> DatasetListSummary {
  let mut source_ref_count = 0
  let mut capture_ref_count = 0
  let mut episode_count = 0
  let mut data_ref_count = 0
  let mut total_data_byte_count = 0L
  let mut latest_id = ""
  let mut latest_status = "undiscovered"
  let mut latest_created_at_ms = -1L
  for dataset in datasets {
    source_ref_count += dataset.source_ids.length()
    capture_ref_count += dataset.capture_ids.length()
    episode_count += dataset.episode_ids.length()
    data_ref_count += dataset.data_refs.length()
    for data_ref in dataset.data_refs {
      total_data_byte_count += data_ref.byte_count
    }
    if dataset.created_at_ms > latest_created_at_ms {
      latest_id = dataset.dataset_id
      latest_status = dataset.status
      latest_created_at_ms = dataset.created_at_ms
    }
  }
  if latest_id == "" {
    return {
      source_ref_count,
      capture_ref_count,
      episode_count,
      data_ref_count,
      total_data_byte_count,
      latest_dataset_id: "",
      latest_dataset_status: "undiscovered",
      latest_dataset_created_at_ms: 0L,
    }
  }
  {
    source_ref_count,
    capture_ref_count,
    episode_count,
    data_ref_count,
    total_data_byte_count,
    latest_dataset_id: latest_id,
    latest_dataset_status: latest_status,
    latest_dataset_created_at_ms: latest_created_at_ms,
  }
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
  let evidence = dataset_list_summary(datasets)
  Ok({
    root,
    query,
    dataset_count: datasets.length(),
    source_ref_count: evidence.source_ref_count,
    capture_ref_count: evidence.capture_ref_count,
    episode_count: evidence.episode_count,
    data_ref_count: evidence.data_ref_count,
    total_data_byte_count: evidence.total_data_byte_count,
    latest_dataset_id: evidence.latest_dataset_id,
    latest_dataset_status: evidence.latest_dataset_status,
    latest_dataset_created_at_ms: evidence.latest_dataset_created_at_ms,
    datasets,
    refs,
    summary: "MoonData datasets: \{datasets.length()} match(es), \{evidence.episode_count} episode(s), \{evidence.data_ref_count} data ref(s), \{evidence.total_data_byte_count} byte(s), latest \{evidence.latest_dataset_status}",
  })
}
