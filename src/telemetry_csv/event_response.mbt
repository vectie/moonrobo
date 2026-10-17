///|
/// One requested relative-grid point, including unavailable observations.
/// Source indices are zero-based positions in the complete input recording.
pub(all) struct EventResponsePoint {
  offset_ms : Int64
  timestamp_ms : Int64?
  status : String
  source_segment : Int?
  left_sample_index : Int?
  right_sample_index : Int?
  left_timestamp_ms : Int64?
  right_timestamp_ms : Int64?
  right_weight : Double?
  values : Array[Double]?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EventResponseTrial {
  episode_index : Int
  anchor : ThresholdEpisode
  points : Array[EventResponsePoint]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EventResponseSummary {
  offset_ms : Int64
  supported_episode_indices : Array[Int]
  exact_count : Int
  interpolated_count : Int
  missing_count : Int
  mean : Array[Double]?
  minimum : Array[Double]?
  maximum : Array[Double]?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EventResponseOverlap {
  first_episode_index : Int
  second_episode_index : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EventResponses {
  format : String
  registration : String
  weighting : String
  overlap_policy : String
  before_ms : Int64
  after_ms : Int64
  step_ms : Int64
  max_gap_ms : Int64
  channels : Array[String]
  unit_labels : Array[String]
  events : ThresholdEvents
  source : Recording
  overlaps : Array[EventResponseOverlap]
  trials : Array[EventResponseTrial]
  summaries : Array[EventResponseSummary]
} derive(Debug, Eq, ToJson)

///|
fn response_missing(
  offset_ms : Int64,
  timestamp_ms : Int64?,
  status : String,
) -> EventResponsePoint {
  {
    offset_ms,
    timestamp_ms,
    status,
    source_segment: None,
    left_sample_index: None,
    right_sample_index: None,
    left_timestamp_ms: None,
    right_timestamp_ms: None,
    right_weight: None,
    values: None,
  }
}

///|
/// Compare explicitly selected repeated recorded events on a common relative
/// grid. Zero is each episode's first matching observed sample, not a physical
/// transition or command. Before/after must be exact multiples of step_ms.
/// All requested points remain visible: outside-range and excessive source
/// gaps are missing, never zero-filled, clipped away or extrapolated.
/// Overlapping windows either fail or are explicitly retained as dependent
/// trials. Mean/min/max use one supported value per selected episode per offset;
/// these are descriptive, not confidence intervals or independent-trial proof.
///
/// ```mbt check
/// test {
///   let report = event_responses_csv(
///     "timestamp_ms,trigger,load\n0,1,2\n100,0,4\n",
///     "trigger",
///     "above",
///     0.5,
///     episodes=[0],
///     channels=["load"],
///     unit_labels=["N"],
///     before_ms=0L,
///     after_ms=100L,
///     step_ms=100L,
///     event_min_span_ms=0L,
///     event_max_gap_ms=100L,
///     max_gap_ms=100L,
///     overlap_policy="reject",
///   ).unwrap()
///   assert_eq(report.summaries[1].mean, Some([4.0]))
/// }
/// ```
pub fn event_responses_csv(
  text : String,
  event_channel : String,
  direction : String,
  threshold : Double,
  episodes~ : Array[Int],
  channels~ : Array[String],
  unit_labels~ : Array[String],
  before_ms~ : Int64,
  after_ms~ : Int64,
  step_ms~ : Int64,
  event_min_span_ms~ : Int64,
  event_max_gap_ms~ : Int64,
  max_gap_ms~ : Int64,
  overlap_policy~ : String,
) -> Result[EventResponses, String] {
  if before_ms < 0L || after_ms < 0L || step_ms <= 0L || max_gap_ms < 0L {
    return Err(
      "before/after and max_gap_ms must be nonnegative; step_ms positive",
    )
  }
  if before_ms > 9223372036854775807L - after_ms {
    return Err("relative window exceeds Int64 span")
  }
  if before_ms % step_ms != 0L || after_ms % step_ms != 0L {
    return Err("before_ms and after_ms must be exact multiples of step_ms")
  }
  let span_ms = before_ms + after_ms
  if span_ms / step_ms >= 10001L {
    return Err("response grid exceeds 10001 points")
  }
  let grid_count = (span_ms / step_ms).to_int() + 1
  if episodes.is_empty() || episodes.length() > 64 {
    return Err("select 1 to 64 episode indices explicitly")
  }
  if channels.is_empty() ||
    channels.length() > 32 ||
    channels.length() != unit_labels.length() {
    return Err("select 1 to 32 channels with one unit label per channel")
  }
  if grid_count * episodes.length() * channels.length() > 200000 {
    return Err("response exceeds 200000 grid/channel/episode cells")
  }
  if overlap_policy != "reject" && overlap_policy != "allow-shared-observations" {
    return Err("overlap_policy must be reject or allow-shared-observations")
  }
  for label in unit_labels {
    if label.trim().is_empty() ||
      label.to_array().any(c => c < ' ' || c == '\u{7f}') {
      return Err("unit labels must be nonblank printable text")
    }
  }
  let events = match
    threshold_events_csv(
      text,
      event_channel,
      direction,
      threshold,
      min_span_ms=event_min_span_ms,
      max_gap_ms=event_max_gap_ms,
    ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let indices : Array[Int] = []
  for channel in channels {
    let index = match source.channels.search(channel) {
      Some(value) => value
      None => return Err("missing channel: " + channel)
    }
    if indices.contains(index) {
      return Err("duplicate selected channel: " + channel)
    }
    indices.push(index)
  }
  let overlaps : Array[EventResponseOverlap] = []
  for i, index in episodes {
    if index < 0 || index >= events.episodes.length() {
      return Err("episode index outside qualifying episodes: \{index}")
    }
    for j in 0..<i {
      if episodes[j] == index {
        return Err("duplicate selected episode: \{index}")
      }
      let a = events.episodes[index].first_timestamp_ms
      let b = events.episodes[episodes[j]].first_timestamp_ms
      if a.max(b) - a.min(b) <= span_ms {
        if overlap_policy == "reject" {
          return Err(
            "requested windows overlap: episodes \{episodes[j]} and \{index}",
          )
        }
        overlaps.push({
          first_episode_index: episodes[j],
          second_episode_index: index,
        })
      }
    }
  }
  let segments : Array[Int] = []
  let mut segment = 0
  for i, sample in source.samples {
    if i > 0 &&
      sample.timestamp_ms - source.samples[i - 1].timestamp_ms > max_gap_ms {
      segment += 1
    }
    segments.push(segment)
  }
  let trials : Array[EventResponseTrial] = []
  for episode_index in episodes {
    let anchor = events.episodes[episode_index]
    let points : Array[EventResponsePoint] = []
    let mut cursor = 0
    for grid_index in 0..<grid_count {
      let offset_ms = grid_index.to_int64() * step_ms - before_ms
      let origin = anchor.first_timestamp_ms
      if (offset_ms < 0L && origin < -offset_ms) ||
        (offset_ms > 0L && origin > 9223372036854775807L - offset_ms) {
        points.push(
          response_missing(offset_ms, None, "outside-timestamp-domain"),
        )
        continue
      }
      let timestamp_ms = origin + offset_ms
      while cursor < source.samples.length() &&
            source.samples[cursor].timestamp_ms < timestamp_ms {
        cursor += 1
      }
      if cursor == source.samples.length() ||
        timestamp_ms < source.samples[0].timestamp_ms {
        points.push(
          response_missing(
            offset_ms,
            Some(timestamp_ms),
            "outside-source-range",
          ),
        )
        continue
      }
      let right = source.samples[cursor]
      let exact = timestamp_ms == right.timestamp_ms
      let left_index = if exact { cursor } else { cursor - 1 }
      let left = source.samples[left_index]
      let span = right.timestamp_ms - left.timestamp_ms
      if !exact && span > max_gap_ms {
        let missing = response_missing(
          offset_ms,
          Some(timestamp_ms),
          "source-gap-exceeds-limit",
        )
        points.push({
          ..missing,
          left_sample_index: Some(left_index),
          right_sample_index: Some(cursor),
          left_timestamp_ms: Some(left.timestamp_ms),
          right_timestamp_ms: Some(right.timestamp_ms),
        })
        continue
      }
      let right_weight = if exact {
        0.0
      } else {
        (timestamp_ms - left.timestamp_ms).to_double() / span.to_double()
      }
      let values : Array[Double] = []
      for index in indices {
        let a = left.values[index]
        let b = right.values[index]
        let value = if exact {
          b
        } else if (a >= 0.0 && b >= 0.0) || (a <= 0.0 && b <= 0.0) {
          a + (b - a) * right_weight
        } else {
          a * (1.0 - right_weight) + b * right_weight
        }
        if value.is_nan() || value.is_inf() {
          return Err("non-finite response interpolation")
        }
        values.push(value)
      }
      points.push({
        offset_ms,
        timestamp_ms: Some(timestamp_ms),
        status: if exact {
          "exact"
        } else {
          "interpolated"
        },
        source_segment: Some(segments[cursor]),
        left_sample_index: Some(left_index),
        right_sample_index: Some(cursor),
        left_timestamp_ms: Some(left.timestamp_ms),
        right_timestamp_ms: Some(right.timestamp_ms),
        right_weight: Some(right_weight),
        values: Some(values),
      })
    }
    trials.push({ episode_index, anchor, points, })
  }
  let summaries : Array[EventResponseSummary] = []
  for grid_index in 0..<grid_count {
    let supported : Array[Int] = []
    let mean : Array[Double] = []
    let minimum : Array[Double] = []
    let maximum : Array[Double] = []
    let mut exact_count = 0
    for trial in trials {
      let point = trial.points[grid_index]
      if point.values is Some(values) {
        supported.push(trial.episode_index)
        if point.status == "exact" {
          exact_count += 1
        }
        for i, value in values {
          if supported.length() == 1 {
            mean.push(value)
            minimum.push(value)
            maximum.push(value)
          } else {
            let weight = 1.0 / supported.length().to_double()
            let old = mean[i]
            mean[i] = if (old >= 0.0 && value >= 0.0) ||
              (old <= 0.0 && value <= 0.0) {
              old + (value - old) * weight
            } else {
              old * (1.0 - weight) + value * weight
            }
            if mean[i].is_nan() || mean[i].is_inf() {
              return Err("non-finite response mean")
            }
            minimum[i] = minimum[i].min(value)
            maximum[i] = maximum[i].max(value)
          }
        }
      }
    }
    summaries.push({
      offset_ms: grid_index.to_int64() * step_ms - before_ms,
      supported_episode_indices: supported,
      exact_count,
      interpolated_count: supported.length() - exact_count,
      missing_count: trials.length() - supported.length(),
      mean: if supported.is_empty() {
        None
      } else {
        Some(mean)
      },
      minimum: if supported.is_empty() {
        None
      } else {
        Some(minimum)
      },
      maximum: if supported.is_empty() {
        None
      } else {
        Some(maximum)
      },
    })
  }
  Ok({
    format: "moonrobo.recorded-event-responses.v1",
    registration: "first-observed-sample-of-explicitly-selected-threshold-episode",
    weighting: "one-supported-value-per-selected-episode-at-each-offset",
    overlap_policy,
    before_ms,
    after_ms,
    step_ms,
    max_gap_ms,
    channels: channels.copy(),
    unit_labels: unit_labels.copy(),
    events,
    source,
    overlaps,
    trials,
    summaries,
  })
}
