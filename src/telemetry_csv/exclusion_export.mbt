///|
/// Export one retained segment as canonical numeric telemetry. All source
/// channels and original timestamps/values remain, with canonical number text.
/// Keep the JSON report and raw input beside CSV for the full editing lineage.
pub fn TelemetryExclusion::to_csv(
  self : TelemetryExclusion,
  segment? : Int,
) -> Result[String, String] {
  if self.segments.is_empty() {
    return Err("no retained samples; inspect the JSON report")
  }
  let selected = match segment {
    Some(value) => value
    None => {
      if self.segments.length() != 1 {
        return Err(
          "multiple retained segments; select --segment and retain the JSON report",
        )
      }
      0
    }
  }
  if selected < 0 || selected >= self.segments.length() {
    return Err("selected segment does not exist")
  }
  let out = StringBuilder()
  out.write_string("timestamp_ms")
  for channel in self.source.channels {
    out.write_string("," + channel)
  }
  out.write_string("\n")
  for row in self.rows {
    if row.segment != Some(selected) {
      continue
    }
    let sample = self.source.samples[row.source_sample_index]
    out.write_string(sample.timestamp_ms.to_string())
    for value in sample.values {
      out.write_string("," + value.to_string())
    }
    out.write_string("\n")
  }
  Ok(out.to_string())
}
