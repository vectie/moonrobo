///|
/// A grid sample's exact source bracket, in selected channel order.
pub(all) struct ResamplePoint {
  grid_index : Int
  timestamp_ms : Int64
  source_segment : Int
  exact : Bool
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  right_weight : Double
  left_values : Array[Double]
  right_values : Array[Double]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ResampleMissing {
  grid_index : Int
  timestamp_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson)

///|
/// Every excessive source interval, even when the grid has no point inside it.
pub(all) struct ResampleSourceGap {
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  duration_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryResample {
  format : String
  timebase : String
  method : String
  value_units : String
  start_ms : Int64
  end_ms : Int64
  step_ms : Int64
  max_gap_ms : Int64
  source_sample_count : Int
  source_segment_count : Int
  output_segment_count : Int
  grid_count : Int
  exact_count : Int
  interpolated_count : Int
  recording : Recording
  points : Array[ResamplePoint]
  missing : Array[ResampleMissing]
  source_gaps : Array[ResampleSourceGap]
} derive(Debug, Eq, ToJson)

///|
/// Evaluate explicitly selected channels at start_ms + k * step_ms <= end_ms.
/// Exact source observations always survive. Other points require a bracketing
/// source interval <= max_gap_ms; no extrapolation or anti-alias filter occurs.
/// Integer offsets are computed before conversion to Double. All input rows
/// are validated, including unselected channels and rows outside the window.
/// At most 100000 grid points may be requested in one in-memory operation.
pub fn resample_csv(
  text : String,
  channels : Array[String],
  start_ms~ : Int64,
  end_ms~ : Int64,
  step_ms~ : Int64,
  max_gap_ms~ : Int64,
) -> Result[TelemetryResample, String] {
  if start_ms < 0L || end_ms < start_ms || step_ms <= 0L || max_gap_ms < 0L {
    return Err(
      "expected 0 <= start_ms <= end_ms, step_ms > 0 and max_gap_ms >= 0",
    )
  }
  let steps = (end_ms - start_ms) / step_ms
  if steps >= 100000L {
    return Err(
      "grid exceeds 100000 points; narrow the window or increase step_ms",
    )
  }
  if channels.is_empty() {
    return Err("select at least one channel")
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
  let source_gaps : Array[ResampleSourceGap] = []
  let segments : Array[Int] = []
  let mut segment = 0
  for i, sample in source.samples {
    if i > 0 {
      let left = source.samples[i - 1].timestamp_ms
      let duration_ms = sample.timestamp_ms - left
      if duration_ms > max_gap_ms {
        source_gaps.push({
          left_sample_index: i - 1,
          right_sample_index: i,
          left_timestamp_ms: left,
          right_timestamp_ms: sample.timestamp_ms,
          duration_ms,
        })
        segment += 1
      }
    }
    segments.push(segment)
  }
  let samples : Array[Sample] = []
  let points : Array[ResamplePoint] = []
  let missing : Array[ResampleMissing] = []
  let mut cursor = 0
  let mut exact_count = 0
  let mut output_segment_count = 0
  let mut last_segment = -1
  let grid_count = steps.to_int() + 1
  for grid_index in 0..<grid_count {
    // Multiplication and addition are bounded by the nonnegative end_ms.
    let timestamp_ms = start_ms + grid_index.to_int64() * step_ms
    while cursor < source.samples.length() &&
          source.samples[cursor].timestamp_ms < timestamp_ms {
      cursor += 1
    }
    if cursor == source.samples.length() ||
      timestamp_ms < source.samples[0].timestamp_ms {
      missing.push({ grid_index, timestamp_ms, reason: "outside-source-range", })
      continue
    }
    let right = source.samples[cursor]
    let exact = right.timestamp_ms == timestamp_ms
    let left_index = if exact { cursor } else { cursor - 1 }
    let left = source.samples[left_index]
    let span_ms = right.timestamp_ms - left.timestamp_ms
    if !exact && span_ms > max_gap_ms {
      missing.push({
        grid_index,
        timestamp_ms,
        reason: "source-gap-exceeds-limit",
      })
      continue
    }
    let right_weight = if exact {
      0.0
    } else {
      (timestamp_ms - left.timestamp_ms).to_double() / span_ms.to_double()
    }
    let left_values = indices.map(i => left.values[i])
    let right_values = indices.map(i => right.values[i])
    let values : Array[Double] = []
    for i in 0..<indices.length() {
      let a = left_values[i]
      let b = right_values[i]
      let value = if exact {
        b
      } else if (a >= 0.0 && b >= 0.0) || (a <= 0.0 && b <= 0.0) {
        // Same-sign endpoints have a representable difference.
        a + (b - a) * right_weight
      } else {
        // Opposite-sign endpoints need a convex sum to avoid difference overflow.
        a * (1.0 - right_weight) + b * right_weight
      }
      if value.is_nan() || value.is_inf() {
        return Err("non-finite interpolation for channel: " + channels[i])
      }
      values.push(value)
    }
    let source_segment = segments[cursor]
    if source_segment != last_segment {
      output_segment_count += 1
      last_segment = source_segment
    }
    if exact {
      exact_count += 1
    }
    samples.push({ timestamp_ms, values, })
    points.push({
      grid_index,
      timestamp_ms,
      source_segment,
      exact,
      left_sample_index: left_index,
      right_sample_index: cursor,
      left_timestamp_ms: left.timestamp_ms,
      right_timestamp_ms: right.timestamp_ms,
      right_weight,
      left_values,
      right_values,
    })
  }
  Ok({
    format: "moonrobo.telemetry-resample.v1",
    timebase: "milliseconds-as-recorded",
    method: "piecewise-linear-with-bounded-source-intervals",
    value_units: "as-recorded-no-unit-conversion",
    start_ms,
    end_ms,
    step_ms,
    max_gap_ms,
    source_sample_count: source.samples.length(),
    source_segment_count: segment + 1,
    output_segment_count,
    grid_count,
    exact_count,
    interpolated_count: points.length() - exact_count,
    recording: { channels: channels.copy(), samples, },
    points,
    missing,
    source_gaps,
  })
}
