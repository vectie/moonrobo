///|
/// One observed row. Positions refer to the complete parsed input, not the window.
pub(all) struct PlotSample {
  timestamp_ms : Int64
  source_sample_index : Int
  segment : Int
  connected : Bool
  values : Array[Double]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct PlotChannel {
  channel : String
  unit_label : String
  minimum : Double
  maximum : Double
} derive(Debug, Eq, ToJson)

///|
fn plot_label_valid(text : String) -> Bool {
  if text.trim().is_empty() {
    return false
  }
  for ch in text {
    if (ch < ' ' && ch != '\t') || ch == '\u{fffe}' || ch == '\u{ffff}' {
      return false
    }
  }
  true
}

///|
pub(all) struct TelemetryPlot {
  format : String
  timebase : String
  start_ms : Int64
  end_ms : Int64
  max_gap_ms : Int64
  source_sample_count : Int
  channels : Array[PlotChannel]
  samples : Array[PlotSample]
  segment_count : Int
  gap_count : Int
} derive(Debug, Eq, ToJson)

///|
/// Select named channels in caller order for a stacked recorded-time plot.
/// All source rows and channels are validated before the inclusive window is
/// selected. Connections are visual guides, never reconstructed measurements.
pub fn plot_csv(
  text : String,
  channels : Array[String],
  unit_labels? : Array[String] = [],
  max_gap_ms? : Int64 = 1000L,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
) -> Result[TelemetryPlot, String] {
  if max_gap_ms <= 0L || start_ms < 0L || end_ms < start_ms {
    return Err("expected max_gap_ms > 0 and 0 <= start_ms <= end_ms")
  }
  if channels.is_empty() {
    return Err("select at least one channel")
  }
  if !unit_labels.is_empty() && unit_labels.length() != channels.length() {
    return Err("supply one unit label per selected channel, or omit all labels")
  }
  for label in unit_labels {
    if !plot_label_valid(label) {
      return Err("unit labels must be nonblank XML-compatible text")
    }
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
    if !plot_label_valid(name) {
      return Err("selected channel contains an unsupported XML character")
    }
    indices.push(index)
  }
  let samples : Array[PlotSample] = []
  let mut segment = 0
  for source_sample_index, sample in recording.samples {
    if sample.timestamp_ms < start_ms || sample.timestamp_ms > end_ms {
      continue
    }
    let connected = match samples.last() {
      Some(previous) => {
        let close = sample.timestamp_ms - previous.timestamp_ms <= max_gap_ms
        if !close {
          segment += 1
        }
        close
      }
      None => false
    }
    samples.push({
      timestamp_ms: sample.timestamp_ms,
      source_sample_index,
      segment,
      connected,
      values: indices.map(index => sample.values[index]),
    })
  }
  if samples.is_empty() {
    return Err("selected window contains no samples")
  }
  let summaries : Array[PlotChannel] = []
  for i, channel in channels {
    let mut minimum = samples[0].values[i]
    let mut maximum = minimum
    for sample in samples {
      minimum = minimum.min(sample.values[i])
      maximum = maximum.max(sample.values[i])
    }
    let unit_label = if unit_labels.is_empty() {
      "unspecified"
    } else {
      unit_labels[i]
    }
    summaries.push({ channel, unit_label, minimum, maximum, })
  }
  Ok({
    format: "moonrobo.telemetry-plot.v1",
    timebase: "milliseconds-as-recorded",
    start_ms,
    end_ms,
    max_gap_ms,
    source_sample_count: recording.samples.length(),
    channels: summaries,
    samples,
    segment_count: segment + 1,
    gap_count: segment,
  })
}
