///|
pub(all) struct CorrelationSample {
  source_sample_index : Int
  timestamp_ms : Int64
  left : Double
  right : Double
} derive(Debug, Eq, ToJson)

///|
/// Positive lag pairs left[i] with right[i + lag]. An undefined coefficient
/// means one overlapping channel is constant, never zero correlation.
pub(all) struct CorrelationLag {
  lag_samples : Int
  lag_ms : Int64
  pair_count : Int
  left_start_sample : Int
  right_start_sample : Int
  coefficient : Double?
  status : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryCorrelation {
  format : String
  method : String
  lag_convention : String
  left_channel : String
  right_channel : String
  requested_start_ms : Int64
  requested_end_ms : Int64
  sample_interval_ms : Int64
  max_lag_samples : Int
  minimum_pairs : Int
  source_sample_count : Int
  samples : Array[CorrelationSample]
  lags : Array[CorrelationLag]
} derive(Debug, Eq, ToJson)

///|
fn correlation_coefficient(
  samples : Array[CorrelationSample],
  left_start : Int,
  right_start : Int,
  count : Int,
) -> Double? {
  // Independent scaling avoids overflowing subtraction, squares, or products
  // for finite values near the Double limits. Scaling does not change Pearson r.
  let mut left_scale = 0.0
  let mut right_scale = 0.0
  for i in 0..<count {
    left_scale = left_scale.max(samples[left_start + i].left.abs())
    right_scale = right_scale.max(samples[right_start + i].right.abs())
  }
  if left_scale == 0.0 || right_scale == 0.0 {
    return None
  }
  let mut left_mean = 0.0
  let mut right_mean = 0.0
  for i in 0..<count {
    left_mean += samples[left_start + i].left / left_scale / count.to_double()
    right_mean += samples[right_start + i].right /
      right_scale /
      count.to_double()
  }
  let mut xx = 0.0
  let mut yy = 0.0
  let mut xy = 0.0
  let mut left_changed = false
  let mut right_changed = false
  for i in 0..<count {
    left_changed = left_changed ||
      samples[left_start + i].left != samples[left_start].left
    right_changed = right_changed ||
      samples[right_start + i].right != samples[right_start].right
    let x = samples[left_start + i].left / left_scale - left_mean
    let y = samples[right_start + i].right / right_scale - right_mean
    xx += x * x
    yy += y * y
    xy += x * y
  }
  if !left_changed || !right_changed || xx == 0.0 || yy == 0.0 {
    return None
  }
  let value = xy / xx.sqrt() / yy.sqrt()
  if value.is_nan() || value.is_inf() {
    return None
  }
  Some(value.max(-1.0).min(1.0))
}

///|
/// Explore lagged similarity of two recorded channels. Positive lag pairs
/// left[i] with a later right[i+lag]. Each lag uses its own overlapping means
/// and Pearson normalization; no circular wrapping, padding, interpolation,
/// resampling, significance estimate, clock correction or causal claim.
/// The inclusive window requires 3..2048 exact uniformly spaced observations;
/// max_lag_samples must leave at least three pairs at both ends.
///
/// ```mbt check
/// test {
///   guard @telemetry_csv.correlation_csv(
///       "timestamp_ms,a,b\n0,1,2\n10,3,6\n20,2,4\n",
///       "a",
///       "b",
///       max_lag_samples=0,
///     )
///     is Ok(result) else {
///     fail("correlation failed")
///   }
///   assert_true(result.lags[0].coefficient.unwrap() > 0.999999)
/// }
/// ```
pub fn correlation_csv(
  text : String,
  left_channel : String,
  right_channel : String,
  max_lag_samples~ : Int,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
) -> Result[TelemetryCorrelation, String] {
  if start_ms < 0L || end_ms < start_ms || max_lag_samples < 0 {
    return Err("expected 0 <= start_ms <= end_ms and max_lag_samples >= 0")
  }
  if text.length() > 4194304 {
    return Err("correlation input exceeds 4 Mi UTF-16 units")
  }
  for channel in [left_channel, right_channel] {
    if channel.length() > 256 || !plot_label_valid(channel) {
      return Err("channel labels require 1..256 XML-compatible units")
    }
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if recording.samples.length() > 100000 {
    return Err("source exceeds 100000 samples")
  }
  let left_index = match recording.channels.search(left_channel) {
    Some(value) => value
    None => return Err("missing left channel: " + left_channel)
  }
  let right_index = match recording.channels.search(right_channel) {
    Some(value) => value
    None => return Err("missing right channel: " + right_channel)
  }
  let samples : Array[CorrelationSample] = []
  for source_sample_index, sample in recording.samples {
    if sample.timestamp_ms >= start_ms && sample.timestamp_ms <= end_ms {
      samples.push({
        source_sample_index,
        timestamp_ms: sample.timestamp_ms,
        left: sample.values[left_index],
        right: sample.values[right_index],
      })
    }
  }
  let count = samples.length()
  if count < 3 || count > 2048 {
    return Err("correlation requires 3..2048 selected observations")
  }
  if max_lag_samples > count - 3 {
    return Err("each lag must leave at least three overlapping pairs")
  }
  let sample_interval_ms = samples[1].timestamp_ms - samples[0].timestamp_ms
  for i in 1..<count {
    if samples[i].timestamp_ms - samples[i - 1].timestamp_ms !=
      sample_interval_ms {
      return Err(
        "selected observations require exact uniform millisecond spacing; explicitly resample separately if intended",
      )
    }
  }
  let lags : Array[CorrelationLag] = []
  for lag in -max_lag_samples..<=max_lag_samples {
    let left_start = if lag < 0 { -lag } else { 0 }
    let right_start = if lag > 0 { lag } else { 0 }
    let pairs = count - left_start - right_start
    let coefficient = correlation_coefficient(
      samples, left_start, right_start, pairs,
    )
    lags.push({
      lag_samples: lag,
      // Difference of retained timestamps is exact and cannot overflow.
      lag_ms: samples[right_start].timestamp_ms -
      samples[left_start].timestamp_ms,
      pair_count: pairs,
      left_start_sample: left_start,
      right_start_sample: right_start,
      coefficient,
      status: if coefficient is Some(_) {
        "defined"
      } else {
        "undefined-zero-or-unresolved-variance"
      },
    })
  }
  Ok({
    format: "moonrobo.telemetry-correlation.v1",
    method: "overlap-wise-pearson",
    lag_convention: "positive-lag-pairs-left-i-with-later-right-i-plus-lag",
    left_channel,
    right_channel,
    requested_start_ms: start_ms,
    requested_end_ms: end_ms,
    sample_interval_ms,
    max_lag_samples,
    minimum_pairs: 3,
    source_sample_count: recording.samples.length(),
    samples,
    lags,
  })
}
