///|
pub(all) struct SignalSeries {
  series_id : String
  dataset_id : DatasetId
  episode_id : EpisodeId
  field_path : String
  units : String
  sample_count : Int
  timebase : String
  storage_ref : DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn signal_series(
  series_id : String,
  dataset_id : DatasetId,
  episode_id : EpisodeId,
  field_path : String,
  units : String,
  sample_count : Int,
  timebase : String,
  storage_ref : DataRef,
) -> SignalSeries {
  {
    series_id,
    dataset_id,
    episode_id,
    field_path,
    units,
    sample_count,
    timebase,
    storage_ref,
  }
}
