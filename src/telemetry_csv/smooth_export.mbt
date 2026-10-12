///|
/// Export numeric recording rows for one connected source segment. Without an
/// explicit segment, export succeeds only when output has one source segment.
/// This prevents a downstream processing hiding a source gap between adjacent means.
/// Keep JSON beside CSV: CSV omits window lineage and unsupported centers.
pub fn TelemetrySmooth::to_csv(
  self : TelemetrySmooth,
  segment? : Int,
) -> Result[String, String] {
  let selected = match segment {
    Some(value) => value
    None => {
      if self.output_segment_count > 1 {
        return Err(
          "disconnected source segments; select a segment for CSV and retain JSON",
        )
      }
      if self.points.is_empty() {
        return Err("no supported window means; inspect the JSON report")
      }
      self.points[0].source_segment
    }
  }
  if !self.points.any(p => p.source_segment == selected) {
    return Err("selected segment has no supported window means")
  }
  let out = StringBuilder()
  out.write_string("timestamp_ms")
  for channel in self.recording.channels {
    out.write_string("," + channel)
  }
  out.write_string("\n")
  for i, sample in self.recording.samples {
    if self.points[i].source_segment != selected {
      continue
    }
    out.write_string(sample.timestamp_ms.to_string())
    for value in sample.values {
      out.write_string("," + value.to_string())
    }
    out.write_string("\n")
  }
  Ok(out.to_string())
}
