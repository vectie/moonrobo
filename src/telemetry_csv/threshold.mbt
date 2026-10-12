///|
/// Endpoints are actual matching samples, never interpolated crossing times.
/// Positions are zero-based sample positions in the fully validated input.
pub(all) struct ThresholdEpisode {
  first_timestamp_ms : Int64
  last_timestamp_ms : Int64
  first_sample_position : Int
  last_sample_position : Int
  observed_span_ms : Int64
  sample_count : Int
  minimum : Double
  maximum : Double
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ThresholdEvents {
  format : String
  channel : String
  direction : String
  threshold : Double
  min_span_ms : Int64
  max_gap_ms : Int64
  source_sample_count : Int
  episodes : Array[ThresholdEpisode]
} derive(Debug, Eq, ToJson)

///|
/// Strict above/below comparisons: equality breaks an episode. Consecutive
/// matching source samples join only when their gap is <= max_gap_ms.
/// The default maximum allows any recorded gap; choose one for your recording.
/// Minimum span is inclusive and measures last minus first observed timestamp.
/// All channels and rows are validated before any episode is selected.
pub fn threshold_events_csv(
  text : String,
  channel : String,
  direction : String,
  threshold : Double,
  min_span_ms? : Int64 = 0L,
  max_gap_ms? : Int64 = 9223372036854775807L,
) -> Result[ThresholdEvents, String] {
  if direction != "above" && direction != "below" {
    return Err("direction must be above or below (strict comparison)")
  }
  if threshold.is_nan() || threshold.is_inf() {
    return Err("threshold must be finite")
  }
  if min_span_ms < 0L || max_gap_ms < 0L {
    return Err("min_span_ms and max_gap_ms must be nonnegative")
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ci = match recording.channels.search(channel) {
    Some(value) => value
    None => return Err("missing channel: " + channel)
  }
  let episodes : Array[ThresholdEpisode] = []
  let mut current : ThresholdEpisode? = None
  for position, sample in recording.samples {
    let value = sample.values[ci]
    let matches = if direction == "above" {
      value > threshold
    } else {
      value < threshold
    }
    if current is Some(previous) {
      if !matches ||
        sample.timestamp_ms - previous.last_timestamp_ms > max_gap_ms {
        if previous.observed_span_ms >= min_span_ms {
          episodes.push(previous)
        }
        current = None
      }
    }
    if matches {
      current = Some(
        match current {
          Some(previous) =>
            {
              ..previous,
              last_timestamp_ms: sample.timestamp_ms,
              last_sample_position: position,
              observed_span_ms: sample.timestamp_ms -
              previous.first_timestamp_ms,
              sample_count: previous.sample_count + 1,
              minimum: previous.minimum.min(value),
              maximum: previous.maximum.max(value),
            }
          None =>
            {
              first_timestamp_ms: sample.timestamp_ms,
              last_timestamp_ms: sample.timestamp_ms,
              first_sample_position: position,
              last_sample_position: position,
              observed_span_ms: 0L,
              sample_count: 1,
              minimum: value,
              maximum: value,
            }
        },
      )
    }
  }
  if current is Some(previous) && previous.observed_span_ms >= min_span_ms {
    episodes.push(previous)
  }
  Ok({
    format: "moonrobo.observed-threshold-events.v1",
    channel,
    direction,
    threshold,
    min_span_ms,
    max_gap_ms,
    source_sample_count: recording.samples.length(),
    episodes,
  })
}

///|
/// One row per episode, with selection metadata repeated for reuse. JSON also
/// retains metadata for empty results. Int64 timestamps are decimal text in CSV
/// and strings in JSON, preserving exact values on native and JS targets.
pub fn ThresholdEvents::to_csv(self : ThresholdEvents) -> String {
  let out = StringBuilder()
  out.write_string(
    "channel,direction,threshold,min_span_ms,max_gap_ms,source_sample_count,first_timestamp_ms,last_timestamp_ms,first_sample_position,last_sample_position,observed_span_ms,sample_count,minimum,maximum\n",
  )
  let channel = "\"" + self.channel.replace(old="\"", new="\"\"") + "\""
  for episode in self.episodes {
    out.write_string(
      "\{channel},\{self.direction},\{self.threshold},\{self.min_span_ms},\{self.max_gap_ms},\{self.source_sample_count},\{episode.first_timestamp_ms},\{episode.last_timestamp_ms},\{episode.first_sample_position},\{episode.last_sample_position},\{episode.observed_span_ms},\{episode.sample_count},\{episode.minimum},\{episode.maximum}\n",
    )
  }
  out.to_string()
}
