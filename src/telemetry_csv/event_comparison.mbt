///|
/// The first actual observation of a selected qualifying threshold episode.
/// This is not an interpolated crossing, a command timestamp, or a clock sync.
pub(all) struct EventAnchor {
  episode_index : Int
  qualifying_episode_count : Int
  episode : ThresholdEpisode
  source_value : Double
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EventComparison {
  format : String
  registration : String
  event_channel : String
  direction : String
  threshold : Double
  event_min_span_ms : Int64
  event_max_gap_ms : Int64
  baseline_anchor : EventAnchor
  candidate_anchor : EventAnchor
  comparison : Comparison
} derive(Debug, Eq, ToJson)

///|
/// Register two recordings on explicitly selected observed threshold episodes.
/// Episode indices are zero-based after minimum-span and gap filtering. The
/// first observation of each episode is elapsed zero. Compare baseline samples
/// in the inclusive [-before_ms, after_ms] window; candidate interpolation is
/// opt-in and never extrapolates. All input rows are validated before selection.
/// Channel units, event correspondence and clock drift are not inferred.
pub fn compare_event_csv(
  baseline_text : String,
  candidate_text : String,
  event_channel : String,
  direction : String,
  threshold : Double,
  baseline_episode~ : Int,
  candidate_episode~ : Int,
  before_ms~ : Int64,
  after_ms~ : Int64,
  event_min_span_ms~ : Int64,
  event_max_gap_ms~ : Int64,
  max_gap_ms~ : Int64,
  channels? : Array[String],
) -> Result[EventComparison, String] {
  if baseline_episode < 0 || candidate_episode < 0 {
    return Err("episode indices must be nonnegative")
  }
  if before_ms < 0L || after_ms < 0L || max_gap_ms < 0L {
    return Err("before_ms, after_ms and max_gap_ms must be nonnegative")
  }
  let baseline_events = match
    threshold_events_csv(
      baseline_text,
      event_channel,
      direction,
      threshold,
      min_span_ms=event_min_span_ms,
      max_gap_ms=event_max_gap_ms,
    ) {
    Ok(value) => value
    Err(message) => return Err("baseline event: " + message)
  }
  let candidate_events = match
    threshold_events_csv(
      candidate_text,
      event_channel,
      direction,
      threshold,
      min_span_ms=event_min_span_ms,
      max_gap_ms=event_max_gap_ms,
    ) {
    Ok(value) => value
    Err(message) => return Err("candidate event: " + message)
  }
  let left_episode = match baseline_events.episodes.get(baseline_episode) {
    Some(value) => value
    None => return Err("baseline episode index is outside qualifying episodes")
  }
  let right_episode = match candidate_events.episodes.get(candidate_episode) {
    Some(value) => value
    None => return Err("candidate episode index is outside qualifying episodes")
  }
  // The event reader above validates both complete recordings. Parse the same
  // immutable text here for comparison and the exact anchor observation values.
  let baseline = match parse(baseline_text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let candidate = match parse(candidate_text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let baseline_channel = match baseline.channels.search(event_channel) {
    Some(value) => value
    None => return Err("baseline is missing event channel")
  }
  let candidate_channel = match candidate.channels.search(event_channel) {
    Some(value) => value
    None => return Err("candidate is missing event channel")
  }
  let comparison = match
    compare_recordings(
      baseline,
      candidate,
      left_episode.first_timestamp_ms,
      right_episode.first_timestamp_ms,
      channels?,
      start_ms=-before_ms,
      end_ms=after_ms,
      max_gap_ms~,
      format="moonrobo.event-comparison-values.v1",
      timebase="milliseconds-since-each-selected-observed-event",
    ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({
    format: "moonrobo.observed-event-comparison.v1",
    registration: "first-recorded-sample-of-selected-qualifying-threshold-episode",
    event_channel,
    direction,
    threshold,
    event_min_span_ms,
    event_max_gap_ms,
    baseline_anchor: {
      episode_index: baseline_episode,
      qualifying_episode_count: baseline_events.episodes.length(),
      episode: left_episode,
      source_value: baseline.samples[left_episode.first_sample_position].values[baseline_channel],
    },
    candidate_anchor: {
      episode_index: candidate_episode,
      qualifying_episode_count: candidate_events.episodes.length(),
      episode: right_episode,
      source_value: candidate.samples[right_episode.first_sample_position].values[candidate_channel],
    },
    comparison,
  })
}

///|
/// Same long-form values/gaps export as Comparison. Keep the JSON report with
/// CSV to retain event-selection configuration and the two anchor observations.
pub fn EventComparison::to_csv(self : EventComparison) -> String {
  self.comparison.to_csv()
}
