///|
/// Numeric offline telemetry. Values are ordered exactly like channels.
pub(all) struct Sample {
  timestamp_ms : Int64
  values : Array[Double]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Recording {
  channels : Array[String]
  samples : Array[Sample]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ChannelSummary {
  channel : String
  minimum : Double
  maximum : Double
  first : Double
  last : Double
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Exploration {
  format : String
  timebase : String
  sample_count : Int
  channels : Array[String]
  summaries : Array[ChannelSummary]
  samples : Array[Sample]
} derive(Debug, Eq, ToJson)

///|
/// Parse a rectangular unquoted CSV with timestamp_ms followed by unique
/// numeric channel names. Timestamps must be nonnegative and strictly increasing.
/// Blank lines and CRLF are accepted; all rows are validated before selection.
pub fn parse(text : String) -> Result[Recording, String] {
  let mut channels : Array[String] = []
  let samples : Array[Sample] = []
  let mut header_seen = false
  let mut line_number = 0
  for line in text.split("\n") {
    line_number += 1
    if line.trim().is_empty() {
      continue
    }
    if line.contains("\"") {
      return Err("line \{line_number}: quoted CSV fields are unsupported")
    }
    let cells = line.split(",").map(s => s.trim().to_owned()).collect()
    if !header_seen {
      if cells.length() < 2 || cells[0] != "timestamp_ms" {
        return Err(
          "line \{line_number}: expected timestamp_ms and at least one channel",
        )
      }
      channels = cells[1:].to_owned()
      for i in 0..<channels.length() {
        if channels[i] == "" || channels[i] == "timestamp_ms" {
          return Err("line \{line_number}: empty or reserved channel name")
        }
        for j in 0..<i {
          if channels[i] == channels[j] {
            return Err("line \{line_number}: duplicate channel \{channels[i]}")
          }
        }
      }
      header_seen = true
      continue
    }
    if cells.length() != channels.length() + 1 {
      return Err("line \{line_number}: wrong number of columns")
    }
    let timestamp_ms = @string.parse_int64(cells[0]) catch {
      _ => return Err("line \{line_number}: invalid integer timestamp_ms")
    }
    if timestamp_ms < 0L {
      return Err("line \{line_number}: timestamp_ms must be nonnegative")
    }
    if samples.last() is Some(previous) && timestamp_ms <= previous.timestamp_ms {
      return Err("line \{line_number}: timestamps must strictly increase")
    }
    let values : Array[Double] = []
    for i in 1..<cells.length() {
      let value = @string.parse_double(cells[i]) catch {
        _ =>
          return Err(
            "line \{line_number}: invalid numeric channel \{channels[i - 1]}",
          )
      }
      if value.is_nan() || value.is_inf() {
        return Err("line \{line_number}: non-finite channel \{channels[i - 1]}")
      }
      values.push(value)
    }
    samples.push({ timestamp_ms, values, })
  }
  if !header_seen || samples.is_empty() {
    return Err("CSV requires a header and at least one sample")
  }
  Ok({ channels, samples, })
}

///|
/// Select an inclusive time window and emit a portable numeric replay payload.
/// No interpolation, resampling, unit conversion, or hardware dispatch occurs.
pub fn explore_csv(
  text : String,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
) -> Result[Exploration, String] {
  if start_ms < 0L || end_ms < start_ms {
    return Err("expected 0 <= start_ms <= end_ms")
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let samples = recording.samples.filter(s => {
    s.timestamp_ms >= start_ms && s.timestamp_ms <= end_ms
  })
  let summaries : Array[ChannelSummary] = []
  if !samples.is_empty() {
    for i in 0..<recording.channels.length() {
      let first = samples[0].values[i]
      let mut minimum = first
      let mut maximum = first
      for sample in samples {
        minimum = minimum.min(sample.values[i])
        maximum = maximum.max(sample.values[i])
      }
      summaries.push({
        channel: recording.channels[i],
        minimum,
        maximum,
        first,
        last: samples[samples.length() - 1].values[i],
      })
    }
  }
  Ok({
    format: "moonrobo.telemetry-csv.v1",
    timebase: "milliseconds-as-recorded",
    sample_count: samples.length(),
    channels: recording.channels,
    summaries,
    samples,
  })
}
