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
  Ok({
    root,
    query,
    signal_count: signals.length(),
    signals,
    refs,
    summary: "MoonData signals: \{signals.length()} match(es)",
  })
}
