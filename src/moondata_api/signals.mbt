///|
pub(all) struct MoonDataSignalQuery {
  dataset_id : String
  episode_id : String
  field_path_contains : String
  storage_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataSignalList {
  root : String
  query : MoonDataSignalQuery
  signal_count : Int
  sample_count : Int
  storage_ref_count : Int
  total_storage_byte_count : Int64
  storage_checksums : Array[String]
  signals : Array[@moondata_core.SignalSeries]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn signal_query(
  dataset_id? : String = "",
  episode_id? : String = "",
  field_path_contains? : String = "",
  storage_kind? : String = "",
) -> MoonDataSignalQuery {
  { dataset_id, episode_id, field_path_contains, storage_kind }
}

///|
fn signal_query_has_filters(query : MoonDataSignalQuery) -> Bool {
  query.dataset_id != "" ||
  query.episode_id != "" ||
  query.field_path_contains != "" ||
  query.storage_kind != ""
}

///|
fn signal_matches(
  signal : @moondata_core.SignalSeries,
  query : MoonDataSignalQuery,
) -> Bool {
  if query.dataset_id != "" && signal.dataset_id != query.dataset_id {
    return false
  }
  if query.episode_id != "" && signal.episode_id != query.episode_id {
    return false
  }
  if query.field_path_contains != "" &&
    !signal.field_path.contains(query.field_path_contains) {
    return false
  }
  if query.storage_kind != "" && signal.storage_ref.kind != query.storage_kind {
    return false
  }
  true
}

///|
fn signal_refs(
  root : String,
  signals : Array[@moondata_core.SignalSeries],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for signal in signals {
    refs.push(
      @moondata_core.moondata_ref(
        "signal-series",
        signal.series_id,
        @moondata_store.signal_path(root, signal.series_id),
        "\{signal.field_path} \{signal.sample_count} sample(s)",
      ),
    )
  }
  refs
}

///|
priv struct SignalListSummary {
  sample_count : Int
  storage_ref_count : Int
  total_storage_byte_count : Int64
  storage_checksums : Array[String]
}

///|
fn signal_list_summary(
  signals : Array[@moondata_core.SignalSeries],
) -> SignalListSummary {
  let mut sample_count = 0
  let mut storage_ref_count = 0
  let mut total_storage_byte_count = 0L
  let storage_checksums : Array[String] = []
  for signal in signals {
    sample_count += signal.sample_count
    storage_ref_count += 1
    total_storage_byte_count += signal.storage_ref.byte_count
    push_unique_checksum(storage_checksums, signal.storage_ref.checksum)
  }
  {
    sample_count,
    storage_ref_count,
    total_storage_byte_count,
    storage_checksums,
  }
}

///|
pub fn list_signals(
  root : String,
  query? : MoonDataSignalQuery = signal_query(),
) -> Result[MoonDataSignalList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let signals : Array[@moondata_core.SignalSeries] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "signal-series" {
      let signal = match
        @moondata_store.read_signal_series(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if signal_query_has_filters(query) {
        signal_matches(signal, query)
      } else {
        true
      }
      if matches {
        signals.push(signal)
      }
    }
  }
  let refs = signal_refs(root, signals)
  let evidence = signal_list_summary(signals)
  Ok({
    root,
    query,
    signal_count: signals.length(),
    sample_count: evidence.sample_count,
    storage_ref_count: evidence.storage_ref_count,
    total_storage_byte_count: evidence.total_storage_byte_count,
    storage_checksums: evidence.storage_checksums,
    signals,
    refs,
    summary: "MoonData signals: \{signals.length()} match(es), \{evidence.sample_count} sample(s), \{evidence.storage_ref_count} storage ref(s), \{evidence.total_storage_byte_count} byte(s)",
  })
}
