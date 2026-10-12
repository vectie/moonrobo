///|
pub(all) struct ComparedSample {
  elapsed_ms : Int64
  baseline_timestamp_ms : Int64
  candidate_left_timestamp_ms : Int64
  candidate_right_timestamp_ms : Int64
  interpolated : Bool
  baseline : Array[Double]
  candidate : Array[Double]
  delta : Array[Double]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ComparisonGap {
  elapsed_ms : Int64
  baseline_timestamp_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct DifferenceSummary {
  channel : String
  mean_delta : Double
  mean_absolute_delta : Double
  root_mean_square_delta : Double
  max_absolute_delta : Double
  max_absolute_elapsed_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Comparison {
  format : String
  timebase : String
  delta_direction : String
  value_units : String
  summary_weighting : String
  baseline_origin_ms : Int64
  candidate_origin_ms : Int64
  start_ms : Int64
  end_ms : Int64
  max_gap_ms : Int64
  channels : Array[String]
  compared_count : Int
  interpolated_count : Int
  unmatched_count : Int
  summaries : Array[DifferenceSummary]
  samples : Array[ComparedSample]
  gaps : Array[ComparisonGap]
} derive(Debug, Eq, ToJson)

///|
/// Compare candidate minus baseline at baseline sample times. Each run's first
/// recorded timestamp is elapsed zero, before the inclusive window is selected.
/// Missing candidate times are linearly interpolated only when the enclosing
/// interval is <= max_gap_ms; zero permits exact matches only. No extrapolation.
/// Omitted channels selects the common names in baseline order. All input rows
/// are validated, including rows outside the selected window.
pub fn compare_csv(
  baseline_text : String,
  candidate_text : String,
  channels? : Array[String],
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
  max_gap_ms? : Int64 = 0L,
) -> Result[Comparison, String] {
  if start_ms < 0L || end_ms < start_ms || max_gap_ms < 0L {
    return Err("expected 0 <= start_ms <= end_ms and max_gap_ms >= 0")
  }
  let baseline = match parse(baseline_text) {
    Ok(value) => value
    Err(message) => return Err("baseline: " + message)
  }
  let candidate = match parse(candidate_text) {
    Ok(value) => value
    Err(message) => return Err("candidate: " + message)
  }
  compare_recordings(
    baseline,
    candidate,
    baseline.samples[0].timestamp_ms,
    candidate.samples[0].timestamp_ms,
    channels?,
    start_ms~,
    end_ms~,
    max_gap_ms~,
    format="moonrobo.telemetry-comparison.v1",
    timebase="milliseconds-since-each-recording-first-sample",
  )
}

///|
// Origins must be nonnegative recorded timestamps. Signed differences therefore
// fit Int64 exactly, including observations before an event at an extreme clock.
fn compare_recordings(
  baseline : Recording,
  candidate : Recording,
  baseline_origin_ms : Int64,
  candidate_origin_ms : Int64,
  channels? : Array[String],
  start_ms~ : Int64,
  end_ms~ : Int64,
  max_gap_ms~ : Int64,
  format~ : String,
  timebase~ : String,
) -> Result[Comparison, String] {
  let selected = match channels {
    Some(names) => names.copy()
    None => baseline.channels.filter(name => candidate.channels.contains(name))
  }
  if selected.is_empty() {
    return Err("select at least one channel present in both recordings")
  }
  let baseline_indices : Array[Int] = []
  let candidate_indices : Array[Int] = []
  for i, name in selected {
    if selected[:i].contains(name) {
      return Err("duplicate selected channel: " + name)
    }
    let left = match baseline.channels.search(name) {
      Some(index) => index
      None => return Err("baseline is missing channel: " + name)
    }
    let right = match candidate.channels.search(name) {
      Some(index) => index
      None => return Err("candidate is missing channel: " + name)
    }
    baseline_indices.push(left)
    candidate_indices.push(right)
  }
  let samples : Array[ComparedSample] = []
  let gaps : Array[ComparisonGap] = []
  let mut cursor = 0
  let mut interpolated_count = 0
  for sample in baseline.samples {
    let elapsed_ms = sample.timestamp_ms - baseline_origin_ms
    if elapsed_ms < start_ms || elapsed_ms > end_ms {
      continue
    }
    while cursor < candidate.samples.length() &&
          candidate.samples[cursor].timestamp_ms - candidate_origin_ms <
          elapsed_ms {
      cursor += 1
    }
    if cursor == candidate.samples.length() ||
      (
        cursor == 0 &&
        candidate.samples[0].timestamp_ms - candidate_origin_ms > elapsed_ms
      ) {
      gaps.push({
        elapsed_ms,
        baseline_timestamp_ms: sample.timestamp_ms,
        reason: "outside-candidate-range",
      })
      continue
    }
    let right = candidate.samples[cursor]
    let exact = right.timestamp_ms - candidate_origin_ms == elapsed_ms
    let left = if exact { right } else { candidate.samples[cursor - 1] }
    let span = right.timestamp_ms - left.timestamp_ms
    if !exact && span > max_gap_ms {
      gaps.push({
        elapsed_ms,
        baseline_timestamp_ms: sample.timestamp_ms,
        reason: "candidate-gap-exceeds-limit",
      })
      continue
    }
    let fraction = if exact {
      0.0
    } else {
      (elapsed_ms - (left.timestamp_ms - candidate_origin_ms)).to_double() /
      span.to_double()
    }
    let baseline_values : Array[Double] = []
    let candidate_values : Array[Double] = []
    let delta : Array[Double] = []
    for i in 0..<selected.length() {
      let before = sample.values[baseline_indices[i]]
      let value = if exact {
        right.values[candidate_indices[i]]
      } else {
        // Convex interpolation avoids overflowing the difference of endpoints.
        left.values[candidate_indices[i]] * (1.0 - fraction) +
        right.values[candidate_indices[i]] * fraction
      }
      let difference = value - before
      if value.is_inf() || difference.is_inf() || difference.is_nan() {
        return Err("numeric comparison overflow for channel: " + selected[i])
      }
      baseline_values.push(before)
      candidate_values.push(value)
      delta.push(difference)
    }
    if !exact {
      interpolated_count += 1
    }
    samples.push({
      elapsed_ms,
      baseline_timestamp_ms: sample.timestamp_ms,
      candidate_left_timestamp_ms: left.timestamp_ms,
      candidate_right_timestamp_ms: right.timestamp_ms,
      interpolated: !exact,
      baseline: baseline_values,
      candidate: candidate_values,
      delta,
    })
  }
  let summaries : Array[DifferenceSummary] = []
  if !samples.is_empty() {
    for i, channel in selected {
      let mut mean_delta = 0.0
      let mut mean_absolute_delta = 0.0
      let mut max_absolute_delta = 0.0
      let mut max_absolute_elapsed_ms = samples[0].elapsed_ms
      for n, sample in samples {
        let value = sample.delta[i]
        let magnitude = value.abs()
        let count = (n + 1).to_double()
        mean_delta = mean_delta * (n.to_double() / count) + value / count
        mean_absolute_delta = mean_absolute_delta * (n.to_double() / count) +
          magnitude / count
        if magnitude > max_absolute_delta {
          max_absolute_delta = magnitude
          max_absolute_elapsed_ms = sample.elapsed_ms
        }
      }
      let mut scaled_squares = 0.0
      if max_absolute_delta > 0.0 {
        for sample in samples {
          let scaled = sample.delta[i] / max_absolute_delta
          scaled_squares += scaled * scaled
        }
      }
      summaries.push({
        channel,
        mean_delta,
        mean_absolute_delta,
        root_mean_square_delta: max_absolute_delta *
        (scaled_squares / samples.length().to_double()).sqrt(),
        max_absolute_delta,
        max_absolute_elapsed_ms,
      })
    }
  }
  Ok({
    format,
    timebase,
    delta_direction: "candidate-minus-baseline",
    value_units: "as-recorded-no-unit-conversion",
    summary_weighting: "equal-weight-per-compared-baseline-sample",
    baseline_origin_ms,
    candidate_origin_ms,
    start_ms,
    end_ms,
    max_gap_ms,
    channels: selected,
    compared_count: samples.length(),
    interpolated_count,
    unmatched_count: gaps.length(),
    summaries,
    samples,
    gaps,
  })
}
