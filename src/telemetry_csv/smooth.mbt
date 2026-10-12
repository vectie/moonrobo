///|
/// A full centered window over the piecewise-linear source curve.
/// Its inclusive source index range references `TelemetrySmooth.source`.
pub(all) struct SmoothPoint {
  source_sample_index : Int
  timestamp_ms : Int64
  source_segment : Int
  window_start_ms : Int64
  window_end_ms : Int64
  first_source_index : Int
  last_source_index : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct SmoothMissing {
  source_sample_index : Int
  timestamp_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetrySmooth {
  format : String
  timebase : String
  method : String
  value_units : String
  half_window_ms : Int64
  max_gap_ms : Int64
  source_segment_count : Int
  output_segment_count : Int
  source : Recording
  recording : Recording
  points : Array[SmoothPoint]
  missing : Array[SmoothMissing]
  source_gaps : Array[ResampleSourceGap]
} derive(Debug, Eq, ToJson)

///|
/// Center a time-weighted box mean at every original source timestamp. Integrate
/// the piecewise-linear curve over [t-half_window_ms, t+half_window_ms]. A result
/// needs the complete window inside one connected source segment. Never shrink
/// windows, extrapolate or bridge excessive gaps. Retain all selected raw values
/// once, and exact window/source spans for reproducibility. Derived labels gain
/// `.mean`; units are unchanged. At most 100000 source rows and 1000000
/// interval-channel contributions may be processed per operation.
pub fn smooth_csv(
  text : String,
  channels : Array[String],
  half_window_ms~ : Int64,
  max_gap_ms~ : Int64,
) -> Result[TelemetrySmooth, String] {
  if half_window_ms <= 0L || half_window_ms > 4611686018427387903L {
    return Err("half_window_ms must be between 1 and 4611686018427387903")
  }
  if max_gap_ms <= 0L {
    return Err("max_gap_ms must be positive")
  }
  if channels.is_empty() {
    return Err("select at least one channel")
  }
  let input = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if input.samples.length() > 100000 {
    return Err("source exceeds 100000 samples; split the recording")
  }
  let indices : Array[Int] = []
  for channel in channels {
    let index = match input.channels.search(channel) {
      Some(value) => value
      None => return Err("missing channel: " + channel)
    }
    if indices.contains(index) {
      return Err("duplicate selected channel: " + channel)
    }
    indices.push(index)
  }
  let source : Recording = {
    channels: channels.copy(),
    samples: input.samples.map(s => {
      timestamp_ms: s.timestamp_ms,
      values: indices.map(i => s.values[i]),
    }),
  }
  let source_gaps : Array[ResampleSourceGap] = []
  let segments : Array[Int] = []
  let starts : Array[Int] = [0]
  let ends : Array[Int] = []
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
        ends.push(i - 1)
        starts.push(i)
        segment += 1
      }
    }
    segments.push(segment)
  }
  ends.push(source.samples.length() - 1)
  let samples : Array[Sample] = []
  let points : Array[SmoothPoint] = []
  let missing : Array[SmoothMissing] = []
  let mut left = 0
  let mut right = 0
  let mut contributions = 0L
  let mut last_segment = -1
  let mut output_segment_count = 0
  let width_ms = half_window_ms * 2L
  for i, sample in source.samples {
    let id = segments[i]
    // Test coverage using nonnegative differences before forming window bounds.
    // This avoids underflow/overflow near zero or the Int64 maximum.
    if sample.timestamp_ms - source.samples[starts[id]].timestamp_ms <
      half_window_ms ||
      source.samples[ends[id]].timestamp_ms - sample.timestamp_ms <
      half_window_ms {
      let outside = sample.timestamp_ms - source.samples[0].timestamp_ms <
        half_window_ms ||
        source.samples[source.samples.length() - 1].timestamp_ms -
        sample.timestamp_ms <
        half_window_ms
      missing.push({
        source_sample_index: i,
        timestamp_ms: sample.timestamp_ms,
        reason: if outside {
          "recording-boundary"
        } else {
          "source-gap-overlaps-window"
        },
      })
      continue
    }
    let start_ms = sample.timestamp_ms - half_window_ms
    let end_ms = sample.timestamp_ms + half_window_ms
    // Exact left boundaries exclude the interval ending there. Exact right
    // boundaries exclude the interval starting there: only positive duration.
    while left + 1 < source.samples.length() &&
          source.samples[left + 1].timestamp_ms <= start_ms {
      left += 1
    }
    right = right.max(left + 1)
    while source.samples[right].timestamp_ms < end_ms {
      right += 1
    }
    contributions += (right - left).to_int64() * channels.length().to_int64()
    if contributions > 1000000L {
      return Err(
        "smoothing exceeds 1000000 interval-channel contributions; reduce window, channels or recording length",
      )
    }
    let values : Array[Double] = []
    for channel in 0..<channels.length() {
      let mut scale = 0.0
      for j in left..<=right {
        scale = scale.max(source.samples[j].values[channel].abs())
      }
      let mut sum = 0.0
      let mut correction = 0.0
      if scale != 0.0 {
        for j in left..<right {
          let a = source.samples[j]
          let b = source.samples[j + 1]
          let lo = a.timestamp_ms.max(start_ms)
          let hi = b.timestamp_ms.min(end_ms)
          let span = (b.timestamp_ms - a.timestamp_ms).to_double()
          let f0 = (lo - a.timestamp_ms).to_double() / span
          let f1 = (hi - a.timestamp_ms).to_double() / span
          let av = a.values[channel] / scale
          let bv = b.values[channel] / scale
          let v0 = av * (1.0 - f0) + bv * f0
          let v1 = av * (1.0 - f1) + bv * f1
          let weight = (hi - lo).to_double() / width_ms.to_double()
          // Normalize before arithmetic to avoid finite endpoint overflow, and
          // compensate accumulation. The true normalized mean is in [-1,1].
          let term = (v0 * 0.5 + v1 * 0.5) * weight - correction
          let next = sum + term
          correction = next - sum - term
          sum = next
        }
      }
      let value = sum.max(-1.0).min(1.0) * scale
      if value.is_nan() || value.is_inf() {
        return Err("non-finite window mean for channel: " + channels[channel])
      }
      values.push(value)
    }
    if id != last_segment {
      output_segment_count += 1
      last_segment = id
    }
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
    points.push({
      source_sample_index: i,
      timestamp_ms: sample.timestamp_ms,
      source_segment: id,
      window_start_ms: start_ms,
      window_end_ms: end_ms,
      first_source_index: left,
      last_source_index: right,
    })
  }
  Ok({
    format: "moonrobo.telemetry-smooth.v1",
    timebase: "milliseconds-as-recorded",
    method: "centered-full-window-piecewise-linear-time-mean",
    value_units: "as-recorded-no-unit-conversion",
    half_window_ms,
    max_gap_ms,
    source_segment_count: segment + 1,
    output_segment_count,
    source,
    recording: { channels: channels.map(c => c + ".mean"), samples, },
    points,
    missing,
    source_gaps,
  })
}
