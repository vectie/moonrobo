///|
/// Explicit source and derived labels; units describe, but do not convert, values.
pub(all) struct MotionChannel {
  source : String
  target : String
  source_unit : String
  output_unit : String
} derive(Debug, Eq, ToJson)

///|
/// One derivative's exact source stencil, in the selected channel order.
pub(all) struct MotionStencil {
  timestamp_ms : Int64
  segment : Int
  source_sample_indices : Array[Int]
  source_timestamps_ms : Array[Int64]
  source_values : Array[Array[Double]]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct MotionUnavailable {
  source_sample_index : Int
  timestamp_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct MotionGap {
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  duration_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryMotion {
  format : String
  timebase : String
  order : Int
  method : String
  timestamp_assignment : String
  max_gap_ms : Int64
  source_sample_count : Int
  segment_count : Int
  channels : Array[MotionChannel]
  recording : Recording
  stencils : Array[MotionStencil]
  unavailable : Array[MotionUnavailable]
  gaps : Array[MotionGap]
} derive(Debug, Eq, ToJson)

///|
/// Differentiate explicitly selected recorded position channels. Order 1 is
/// interval-average rate, assigned to its right source timestamp. Order 2 is
/// the nonuniform three-point second derivative, assigned to its middle source
/// timestamp. No stencil crosses a gap longer than max_gap_ms. All source rows
/// are validated, including unselected channels. Values use seconds, not ms.
pub fn motion_csv(
  text : String,
  channels : Array[String],
  unit_labels~ : Array[String],
  order~ : Int,
  max_gap_ms~ : Int64,
) -> Result[TelemetryMotion, String] {
  if order != 1 && order != 2 {
    return Err("order must be 1 (rate) or 2 (acceleration)")
  }
  if max_gap_ms <= 0L {
    return Err("max_gap_ms must be positive")
  }
  if channels.is_empty() || channels.length() != unit_labels.length() {
    return Err("select at least one channel and one source unit per channel")
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let indices : Array[Int] = []
  let mappings : Array[MotionChannel] = []
  for i, channel in channels {
    if !normalization_label_valid(channel) || unit_labels[i].trim().is_empty() {
      return Err("channel and source unit labels must be nonblank and valid")
    }
    let index = match source.channels.search(channel) {
      Some(value) => value
      None => return Err("missing channel: " + channel)
    }
    if indices.contains(index) {
      return Err("duplicate selected channel: " + channel)
    }
    indices.push(index)
    mappings.push({
      source: channel,
      target: channel + (if order == 1 { ".rate" } else { ".acceleration" }),
      source_unit: unit_labels[i],
      output_unit: "(" +
      unit_labels[i] +
      (if order == 1 { ")/s" } else { ")/s^2" }),
    })
  }
  let gaps : Array[MotionGap] = []
  let segments : Array[Int] = []
  let mut segment = 0
  for i, sample in source.samples {
    if i > 0 {
      let left = source.samples[i - 1].timestamp_ms
      let dt = sample.timestamp_ms - left
      if dt > max_gap_ms {
        gaps.push({
          left_sample_index: i - 1,
          right_sample_index: i,
          left_timestamp_ms: left,
          right_timestamp_ms: sample.timestamp_ms,
          duration_ms: dt,
        })
        segment += 1
      }
    }
    segments.push(segment)
  }
  let samples : Array[Sample] = []
  let stencils : Array[MotionStencil] = []
  let unavailable : Array[MotionUnavailable] = []
  for i, sample in source.samples {
    let reason = if i == 0 || (order == 2 && i == source.samples.length() - 1) {
      "recording-boundary"
    } else {
      let gap_before = segments[i - 1] != segments[i]
      let gap_after = order == 2 && segments[i + 1] != segments[i]
      if gap_before && gap_after {
        "gap-before-and-after"
      } else if gap_before {
        "gap-before"
      } else if gap_after {
        "gap-after"
      } else {
        ""
      }
    }
    if reason != "" {
      unavailable.push({
        source_sample_index: i,
        timestamp_ms: sample.timestamp_ms,
        reason,
      })
      continue
    }
    let left = source.samples[i - 1]
    let dt_left = (sample.timestamp_ms - left.timestamp_ms).to_double() / 1000.0
    let values : Array[Double] = []
    for index in indices {
      let rate_left = (sample.values[index] - left.values[index]) / dt_left
      let value = if order == 1 {
        rate_left
      } else {
        let right = source.samples[i + 1]
        let dt_right = (right.timestamp_ms - sample.timestamp_ms).to_double() /
          1000.0
        let rate_right = (right.values[index] - sample.values[index]) / dt_right
        // The spacing between interval midpoints is half the full stencil span.
        // Subtract timestamps before Double conversion to preserve short steps
        // at large epoch values; never add Int64 durations that can overflow.
        let midpoint_spacing = (right.timestamp_ms - left.timestamp_ms).to_double() /
          2000.0
        (rate_right - rate_left) / midpoint_spacing
      }
      if value.is_nan() || value.is_inf() {
        return Err("derivative exceeds finite range at source sample \{i}")
      }
      values.push(value)
    }
    let source_indices = if order == 1 { [i - 1, i] } else { [i - 1, i, i + 1] }
    stencils.push({
      timestamp_ms: sample.timestamp_ms,
      segment: segments[i],
      source_sample_indices: source_indices,
      source_timestamps_ms: source_indices.map(j => {
        source.samples[j].timestamp_ms
      }),
      source_values: source_indices.map(j => {
        indices.map(k => source.samples[j].values[k])
      }),
    })
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
  }
  Ok({
    format: "moonrobo.telemetry-motion.v1",
    timebase: "milliseconds-as-recorded; derivative-time-unit=seconds",
    order,
    method: if order == 1 {
      "two-point-interval-average"
    } else {
      "nonuniform-three-point-second-derivative"
    },
    timestamp_assignment: if order == 1 {
      "right-source-sample"
    } else {
      "middle-source-sample"
    },
    max_gap_ms,
    source_sample_count: source.samples.length(),
    segment_count: segment + 1,
    channels: mappings,
    recording: { channels: mappings.map(c => c.target), samples, },
    stencils,
    unavailable,
    gaps,
  })
}

///|
/// Export only supported derivative estimates as reusable numeric CSV. No zero
/// rows are manufactured at boundaries or gaps. Keep the JSON lineage report.
pub fn TelemetryMotion::to_csv(
  self : TelemetryMotion,
) -> Result[String, String] {
  if self.recording.samples.is_empty() {
    return Err(
      "no derivative estimates; use JSON to inspect boundaries and gaps",
    )
  }
  telemetry_recording_csv(self.recording)
}
