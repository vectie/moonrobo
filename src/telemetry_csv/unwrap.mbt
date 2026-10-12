///|
/// Arrays follow the explicit recipe order, not the full CSV channel order.
/// step_adjustments are local changes to a raw delta; offsets are cumulative.
pub(all) struct UnwrapPoint {
  source_sample_index : Int
  timestamp_ms : Int64
  segment : Int
  segment_start : Bool
  source_values : Array[Double]
  step_adjustments : Array[Double]
  offsets : Array[Double]
  half_period_ties : Array[Bool]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct UnwrapGap {
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  duration_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryUnwrap {
  format : String
  timebase : String
  algorithm : String
  assumption : String
  tie_policy : String
  max_gap_ms : Int64
  segment_count : Int
  channels : Array[PeriodicChannel]
  recording : Recording
  points : Array[UnwrapPoint]
  gaps : Array[UnwrapGap]
} derive(Debug, Eq, ToJson)

///|
/// Correct periodic discontinuities using the shortest signed delta. Every
/// segment is anchored to its first raw value. A gap longer than max_gap_ms
/// starts a new segment; no turn count is carried through an unobserved gap.
/// All rows, timestamps and unselected channels are retained and validated.
/// This is a sampling assumption, not recovery of unobserved physical turns.
pub fn unwrap_csv(
  text : String,
  channels : Array[PeriodicChannel],
  max_gap_ms~ : Int64,
) -> Result[TelemetryUnwrap, String] {
  if max_gap_ms <= 0L {
    return Err("max_gap_ms must be positive")
  }
  match validate_unwrap_recipe(channels) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let indices : Array[Int] = []
  let names = source.channels.copy()
  for channel in channels {
    let index = match source.channels.search(channel.source) {
      Some(value) => value
      None => return Err("missing source channel: " + channel.source)
    }
    indices.push(index)
    names[index] = channel.target
  }
  // Renames are simultaneous; mapped/untouched collisions are not allowed.
  let seen : Array[String] = []
  for name in names {
    if !normalization_label_valid(name) || seen.contains(name) {
      return Err("invalid or duplicate output channel: " + name)
    }
    seen.push(name)
  }
  let offsets : Array[Double] = channels.map(_ => 0.0)
  let samples : Array[Sample] = []
  let points : Array[UnwrapPoint] = []
  let gaps : Array[UnwrapGap] = []
  let mut segment = 0
  for i, sample in source.samples {
    let mut segment_start = i == 0
    if i > 0 {
      let left = source.samples[i - 1].timestamp_ms
      let duration = sample.timestamp_ms - left
      if duration > max_gap_ms {
        segment += 1
        segment_start = true
        gaps.push({
          left_sample_index: i - 1,
          right_sample_index: i,
          left_timestamp_ms: left,
          right_timestamp_ms: sample.timestamp_ms,
          duration_ms: duration,
        })
      }
    }
    let values = sample.values.copy()
    let adjustments : Array[Double] = []
    let ties : Array[Bool] = []
    for j, channel in channels {
      let index = indices[j]
      let raw = sample.values[index]
      let mut adjustment = 0.0
      let mut tie = false
      if segment_start {
        offsets[j] = 0.0
      } else {
        let delta = raw - source.samples[i - 1].values[index]
        if delta.is_nan() || delta.is_inf() {
          return Err(
            "non-finite raw delta at source sample \{i}: " + channel.source,
          )
        }
        let half = channel.period / 2.0
        // Signed remainder avoids division into an overflowing turn count.
        let remainder = delta % channel.period
        let shortest = if remainder > half {
          remainder - channel.period
        } else if remainder < -half {
          remainder + channel.period
        } else {
          remainder
        }
        tie = shortest.abs() == half
        adjustment = shortest - delta
        offsets[j] = offsets[j] + adjustment
      }
      let output = raw + offsets[j]
      if adjustment.is_nan() ||
        adjustment.is_inf() ||
        offsets[j].is_nan() ||
        offsets[j].is_inf() ||
        output.is_nan() ||
        output.is_inf() {
        return Err(
          "unwrapped value or correction exceeds finite range at source sample \{i}: " +
          channel.source,
        )
      }
      values[index] = output
      adjustments.push(adjustment)
      ties.push(tie)
    }
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
    points.push({
      source_sample_index: i,
      timestamp_ms: sample.timestamp_ms,
      segment,
      segment_start,
      source_values: indices.map(index => sample.values[index]),
      step_adjustments: adjustments,
      offsets: offsets.copy(),
      half_period_ties: ties,
    })
  }
  Ok({
    format: "moonrobo.telemetry-unwrap.v1",
    timebase: "milliseconds-as-recorded",
    algorithm: "shortest-signed-periodic-delta; raw-anchor-per-segment",
    assumption: "true inter-sample displacement is less than half-period; hidden turns are not recoverable",
    tie_policy: "retain raw delta sign at exact half-period; report ambiguity",
    max_gap_ms,
    segment_count: segment + 1,
    channels,
    recording: { channels: names, samples, },
    points,
    gaps,
  })
}

///|
/// Reusable numeric recording. Preserve the JSON and raw source separately;
/// CSV omits correction history, units, ties and explicit segment boundaries.
pub fn TelemetryUnwrap::to_csv(
  self : TelemetryUnwrap,
) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
