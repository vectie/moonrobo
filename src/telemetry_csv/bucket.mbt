///|
pub(all) struct BucketStatistics {
  channel : String
  first : Double
  last : Double
  minimum : Double
  maximum : Double
  sample_weighted_mean : Double
} derive(Debug, Eq, ToJson)

///|
/// All bounds are inclusive integer milliseconds. Grid bounds are clipped only
/// at Int64 max; selected bounds also intersect the requested window.
pub(all) struct TelemetryBucket {
  index : Int64
  start_ms : Int64
  end_ms : Int64
  selected_start_ms : Int64
  selected_end_ms : Int64
  sample_count : Int
  source_sample_indices : Array[Int]
  source_timestamps_ms : Array[Int64]
  statistics : Array[BucketStatistics]
} derive(Debug, Eq, ToJson)

///|
/// A contiguous run of empty buckets, never synthesized zero-valued samples.
pub(all) struct BucketGap {
  first_index : Int64
  last_index : Int64
  empty_bucket_count : UInt64
  selected_start_ms : Int64
  selected_end_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryBuckets {
  format : String
  timebase : String
  weighting : String
  alignment : String
  origin_ms : Int64
  width_ms : Int64
  start_ms : Int64
  end_ms : Int64
  channels : Array[String]
  source_sample_count : Int
  selected_sample_count : Int
  total_bucket_count : UInt64
  buckets : Array[TelemetryBucket]
  gaps : Array[BucketGap]
} derive(Debug, Eq, ToJson)

///|
fn bucket_bounds(
  index : Int64,
  width : Int64,
  origin : Int64,
) -> (Int64, Int64) {
  // Callers supply indices derived from a nonnegative, representable timestamp.
  let start = origin + index * width
  let remaining = 9223372036854775807L - start
  let end = if remaining < width - 1L {
    9223372036854775807L
  } else {
    start + (width - 1L)
  }
  (start, end)
}

///|
fn summarize_bucket(
  recording : Recording,
  indices : Array[Int],
  begin : Int,
  limit : Int,
  index : Int64,
  width : Int64,
  origin : Int64,
  window_start : Int64,
  window_end : Int64,
) -> TelemetryBucket {
  let statistics : Array[BucketStatistics] = []
  for ci in indices {
    let first = recording.samples[begin].values[ci]
    let mut minimum = first
    let mut maximum = first
    let mut scale = first.abs()
    for i in begin..<limit {
      let value = recording.samples[i].values[ci]
      minimum = minimum.min(value)
      maximum = maximum.max(value)
      scale = scale.max(value.abs())
    }
    // Scale before summation: even opposite or repeated finite Double extremes
    // cannot overflow. Compensated normalized summation reduces rounding loss.
    let mut sum = 0.0
    let mut correction = 0.0
    if scale > 0.0 {
      for i in begin..<limit {
        let term = recording.samples[i].values[ci] / scale - correction
        let next = sum + term
        correction = next - sum - term
        sum = next
      }
    }
    let mean = scale * (sum / (limit - begin).to_double()).max(-1.0).min(1.0)
    statistics.push({
      channel: recording.channels[ci],
      first,
      last: recording.samples[limit - 1].values[ci],
      minimum,
      maximum,
      sample_weighted_mean: mean,
    })
  }
  let (start_ms, end_ms) = bucket_bounds(index, width, origin)
  let source_sample_indices : Array[Int] = []
  let source_timestamps_ms : Array[Int64] = []
  for i in begin..<limit {
    source_sample_indices.push(i)
    source_timestamps_ms.push(recording.samples[i].timestamp_ms)
  }
  {
    index,
    start_ms,
    end_ms,
    selected_start_ms: start_ms.max(window_start),
    selected_end_ms: end_ms.min(window_end),
    sample_count: limit - begin,
    source_sample_indices,
    source_timestamps_ms,
    statistics,
  }
}

///|
fn bucket_gap(
  first : Int64,
  last : Int64,
  width : Int64,
  origin : Int64,
  window_start : Int64,
  window_end : Int64,
) -> BucketGap {
  let (start, _) = bucket_bounds(first, width, origin)
  let (_, end) = bucket_bounds(last, width, origin)
  {
    first_index: first,
    last_index: last,
    empty_bucket_count: (last - first).to_uint64() + 1UL,
    selected_start_ms: start.max(window_start),
    selected_end_ms: end.min(window_end),
  }
}

///|
/// Aggregate observations into explicit fixed-width integer time buckets.
/// Alignment is "zero" (origin 0) or "window" (origin start_ms). Selection is
/// inclusive; bucket index is floor((timestamp-origin)/width). Only selected
/// observations contribute, equally weighted. Validate every input row first.
/// Empty spans are compressed; work and memory do not scale with window width.
pub fn bucket_csv(
  text : String,
  channels : Array[String],
  width_ms~ : Int64,
  alignment~ : String,
  start_ms~ : Int64,
  end_ms~ : Int64,
) -> Result[TelemetryBuckets, String] {
  if width_ms <= 0L || start_ms < 0L || end_ms < start_ms {
    return Err("expected width_ms > 0 and 0 <= start_ms <= end_ms")
  }
  if alignment != "zero" && alignment != "window" {
    return Err("alignment must be zero or window")
  }
  if channels.is_empty() {
    return Err("select at least one channel")
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let indices : Array[Int] = []
  for name in channels {
    let index = match recording.channels.search(name) {
      Some(index) => index
      None => return Err("missing channel: " + name)
    }
    if indices.contains(index) {
      return Err("duplicate selected channel: " + name)
    }
    indices.push(index)
  }
  let origin_ms = if alignment == "zero" { 0L } else { start_ms }
  let first_index = (start_ms - origin_ms) / width_ms
  let last_index = (end_ms - origin_ms) / width_ms
  let buckets : Array[TelemetryBucket] = []
  let mut selected_sample_count = 0
  let mut begin = 0
  while begin < recording.samples.length() &&
        recording.samples[begin].timestamp_ms < start_ms {
    begin += 1
  }
  while begin < recording.samples.length() &&
        recording.samples[begin].timestamp_ms <= end_ms {
    let index = (recording.samples[begin].timestamp_ms - origin_ms) / width_ms
    let mut limit = begin + 1
    while limit < recording.samples.length() &&
          recording.samples[limit].timestamp_ms <= end_ms &&
          (recording.samples[limit].timestamp_ms - origin_ms) / width_ms ==
          index {
      limit += 1
    }
    buckets.push(
      summarize_bucket(
        recording, indices, begin, limit, index, width_ms, origin_ms, start_ms, end_ms,
      ),
    )
    selected_sample_count += limit - begin
    begin = limit
  }
  let gaps : Array[BucketGap] = []
  let mut next = first_index
  let mut remainder = true
  for bucket in buckets {
    if bucket.index > next {
      gaps.push(
        bucket_gap(
          next,
          bucket.index - 1L,
          width_ms,
          origin_ms,
          start_ms,
          end_ms,
        ),
      )
    }
    if bucket.index == last_index {
      remainder = false
    } else {
      next = bucket.index + 1L
    }
  }
  if remainder {
    gaps.push(
      bucket_gap(next, last_index, width_ms, origin_ms, start_ms, end_ms),
    )
  }
  Ok({
    format: "moonrobo.telemetry-buckets.v1",
    timebase: "milliseconds-as-recorded-inclusive-integer-bounds",
    weighting: "equal-weight-per-selected-source-sample-no-time-weighting",
    alignment,
    origin_ms,
    width_ms,
    start_ms,
    end_ms,
    channels: channels.copy(),
    source_sample_count: recording.samples.length(),
    selected_sample_count,
    total_bucket_count: (last_index - first_index).to_uint64() + 1UL,
    buckets,
    gaps,
  })
}
