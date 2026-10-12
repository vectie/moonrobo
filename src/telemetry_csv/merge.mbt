///|
/// Provenance for one complete merged row. Values are observed samples, not
/// interpolated values. delta_ms is aligned secondary time minus primary time.
pub(all) struct MergeMatch {
  timestamp_ms : Int64
  secondary_timestamp_ms : Int64
  secondary_aligned_timestamp_ms : Int64
  delta_ms : Int64
  exact : Bool
  secondary_reused : Bool
} derive(Debug, Eq, ToJson)

///|
pub(all) struct MergeGap {
  timestamp_ms : Int64
  nearest_secondary_timestamp_ms : Int64
  nearest_aligned_timestamp_ms : Int64
  delta_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryMerge {
  format : String
  timebase : String
  primary_prefix : String
  secondary_prefix : String
  secondary_offset_ms : Int64
  tolerance_ms : Int64
  primary_count : Int
  secondary_count : Int
  merged_count : Int
  exact_count : Int
  nearest_count : Int
  reused_count : Int
  secondary_unused_count : Int
  recording : Recording
  matches : Array[MergeMatch]
  unmatched : Array[MergeGap]
} derive(Debug, Eq, ToJson)

///|
fn merge_prefix_valid(prefix : String) -> Bool {
  prefix.trim().to_owned() == prefix &&
  !prefix.contains(",") &&
  !prefix.contains("\"") &&
  !prefix.contains("\n") &&
  !prefix.contains("\r")
}

///|
fn merge_channel_name(prefix : String, channel : String) -> String {
  if prefix == "" {
    channel
  } else {
    prefix + "." + channel
  }
}

///|
fn merge_distance(a : Int64, b : Int64) -> Int64 {
  // Both timestamps are nonnegative Int64, so subtraction cannot overflow.
  if a >= b {
    a - b
  } else {
    b - a
  }
}

///|
/// Combine all channels on the primary recording's original timestamp grid.
/// Secondary timestamps are shifted by an explicit offset (default zero).
/// Choose the nearest observed secondary row within tolerance_ms, preferring
/// the earlier row on ties. A secondary row may be reused. Unmatched primary
/// rows are reported and omitted from the complete numeric recording.
/// Neither origins nor units are inferred; both full inputs are validated.
pub fn merge_csv(
  primary_text : String,
  secondary_text : String,
  primary_prefix? : String = "primary",
  secondary_prefix? : String = "secondary",
  secondary_offset_ms? : Int64 = 0L,
  tolerance_ms? : Int64 = 0L,
) -> Result[TelemetryMerge, String] {
  if tolerance_ms < 0L {
    return Err("tolerance_ms must be nonnegative")
  }
  if !merge_prefix_valid(primary_prefix) ||
    !merge_prefix_valid(secondary_prefix) {
    return Err(
      "prefixes must be unquoted CSV labels without surrounding whitespace",
    )
  }
  let primary = match parse(primary_text) {
    Ok(recording) => recording
    Err(message) => return Err("primary: " + message)
  }
  let secondary = match parse(secondary_text) {
    Ok(recording) => recording
    Err(message) => return Err("secondary: " + message)
  }
  let channels = primary.channels.map(name => {
    merge_channel_name(primary_prefix, name)
  })
  for name in secondary.channels {
    let output_name = merge_channel_name(secondary_prefix, name)
    if channels.contains(output_name) {
      return Err("duplicate merged channel: " + output_name)
    }
    channels.push(output_name)
  }
  let aligned : Array[Int64] = []
  for sample in secondary.samples {
    if secondary_offset_ms > 0L &&
      sample.timestamp_ms > 9223372036854775807L - secondary_offset_ms {
      return Err("secondary timestamp offset exceeds Int64 range")
    }
    let timestamp = sample.timestamp_ms + secondary_offset_ms
    if timestamp < 0L {
      return Err("secondary timestamp offset produces a negative timestamp")
    }
    aligned.push(timestamp)
  }
  let samples : Array[Sample] = []
  let matches : Array[MergeMatch] = []
  let unmatched : Array[MergeGap] = []
  let used = Array::make(secondary.samples.length(), false)
  let mut cursor = 0
  let mut exact_count = 0
  let mut reused_count = 0
  let mut secondary_used_count = 0
  for sample in primary.samples {
    while cursor + 1 < aligned.length() &&
          aligned[cursor + 1] <= sample.timestamp_ms {
      cursor += 1
    }
    let mut nearest = cursor
    if cursor + 1 < aligned.length() &&
      merge_distance(aligned[cursor + 1], sample.timestamp_ms) <
      merge_distance(aligned[cursor], sample.timestamp_ms) {
      nearest = cursor + 1
    }
    let source = secondary.samples[nearest]
    let delta_ms = aligned[nearest] - sample.timestamp_ms
    if merge_distance(aligned[nearest], sample.timestamp_ms) > tolerance_ms {
      unmatched.push({
        timestamp_ms: sample.timestamp_ms,
        nearest_secondary_timestamp_ms: source.timestamp_ms,
        nearest_aligned_timestamp_ms: aligned[nearest],
        delta_ms,
        reason: "nearest-sample-exceeds-tolerance",
      })
      continue
    }
    let values = sample.values.copy()
    values.append(source.values)
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
    let exact = delta_ms == 0L
    if exact {
      exact_count += 1
    }
    let secondary_reused = used[nearest]
    if secondary_reused {
      reused_count += 1
    } else {
      secondary_used_count += 1
      used[nearest] = true
    }
    matches.push({
      timestamp_ms: sample.timestamp_ms,
      secondary_timestamp_ms: source.timestamp_ms,
      secondary_aligned_timestamp_ms: aligned[nearest],
      delta_ms,
      exact,
      secondary_reused,
    })
  }
  Ok({
    format: "moonrobo.telemetry-merge.v1",
    timebase: "primary-milliseconds-as-recorded",
    primary_prefix,
    secondary_prefix,
    secondary_offset_ms,
    tolerance_ms,
    primary_count: primary.samples.length(),
    secondary_count: secondary.samples.length(),
    merged_count: samples.length(),
    exact_count,
    nearest_count: samples.length() - exact_count,
    reused_count,
    secondary_unused_count: secondary.samples.length() - secondary_used_count,
    recording: { channels, samples, },
    matches,
    unmatched,
  })
}

///|
/// Export a complete numeric CSV accepted by parse/explore/compare/trajectory.
/// Keep the JSON report alongside it: CSV alone omits source timestamps and
/// unmatched-row/reuse information. Results with no complete rows are errors.
pub fn TelemetryMerge::to_csv(self : TelemetryMerge) -> Result[String, String] {
  if self.recording.samples.is_empty() {
    return Err("no merged samples; inspect the JSON report or adjust alignment")
  }
  let out = StringBuilder()
  out.write_string("timestamp_ms")
  for channel in self.recording.channels {
    out.write_string("," + channel)
  }
  out.write_string("\n")
  for sample in self.recording.samples {
    out.write_string(sample.timestamp_ms.to_string())
    for value in sample.values {
      out.write_string("," + value.to_string())
    }
    out.write_string("\n")
  }
  Ok(out.to_string())
}
