///|
/// Source line numbers are one-based physical lines, aligned with samples.
/// The recipe records field selection and supplied labels, not calibration.
pub(all) struct TelemetryJsonlImport {
  format : String
  timebase : String
  recipe : JsonlRecipe
  source_line_numbers : Array[Int]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn jsonl_lookup(value : Json, path : Array[String]) -> Result[Json, String] {
  let mut current = value
  for key in path {
    guard current is Object(fields) else {
      return Err("path traverses a non-object")
    }
    match fields.get(key) {
      Some(value) => current = value
      None => return Err("missing object key " + key.to_json().stringify())
    }
  }
  Ok(current)
}

///|
fn jsonl_timestamp(value : Json) -> Result[Int64, String] {
  guard value is String(text) && !text.is_empty() else {
    return Err("timestamp must be a decimal-string millisecond integer")
  }
  for c in text {
    if c < '0' || c > '9' {
      return Err("timestamp must contain only decimal digits")
    }
  }
  let timestamp = @string.parse_int64(text) catch {
    _ => return Err("timestamp exceeds nonnegative Int64 range")
  }
  Ok(timestamp)
}

///|
/// Import one JSON object per nonblank line using explicit object-key paths.
/// Timestamps are decimal strings to avoid JSON Number precision loss.
/// Every nonblank line is validated; no partial output or skipped bad rows.
pub fn import_jsonl(
  text : String,
  recipe : JsonlRecipe,
) -> Result[TelemetryJsonlImport, String] {
  match validate_jsonl_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let samples : Array[Sample] = []
  let source_line_numbers : Array[Int] = []
  let mut line_number = 0
  for line in text.split("\n") {
    line_number += 1
    if line.trim().is_empty() {
      continue
    }
    let prefix = "line \{line_number}: "
    let json = @json.parse(line) catch {
      _ => return Err(prefix + "invalid JSON")
    }
    match jsonl_unique_object_keys(line) {
      Err(message) => return Err(prefix + message)
      Ok(_) => ()
    }
    guard json is Object(_) else {
      return Err(prefix + "expected a JSON object")
    }
    let raw_timestamp = match jsonl_lookup(json, recipe.timestamp_path) {
      Ok(value) => value
      Err(message) => return Err(prefix + "timestamp: " + message)
    }
    let timestamp_ms = match jsonl_timestamp(raw_timestamp) {
      Ok(value) => value
      Err(message) => return Err(prefix + message)
    }
    if samples.last() is Some(previous) && timestamp_ms <= previous.timestamp_ms {
      return Err(prefix + "timestamps must strictly increase")
    }
    let values : Array[Double] = []
    for channel in recipe.channels {
      let value = match jsonl_lookup(json, channel.path) {
        Ok(value) => value
        Err(message) => return Err(prefix + channel.target + ": " + message)
      }
      guard value is Number(number) && !number.is_nan() && !number.is_inf() else {
        return Err(prefix + channel.target + ": expected a finite JSON number")
      }
      values.push(number)
    }
    samples.push({ timestamp_ms, values, })
    source_line_numbers.push(line_number)
  }
  if samples.is_empty() {
    return Err("JSONL requires at least one nonblank object line")
  }
  Ok({
    format: "moonrobo.telemetry-jsonl.v1",
    timebase: "milliseconds-as-recorded",
    recipe,
    source_line_numbers,
    recording: { channels: recipe.channels.map(c => c.target), samples, },
  })
}

///|
/// Export reusable numeric CSV; retain the JSON report and original JSONL too.
pub fn TelemetryJsonlImport::to_csv(
  self : TelemetryJsonlImport,
) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}

///|
fn telemetry_recording_csv(recording : Recording) -> Result[String, String] {
  let out = StringBuilder()
  out.write_string("timestamp_ms")
  for channel in recording.channels {
    if !normalization_label_valid(channel) {
      return Err("invalid output channel")
    }
    out.write_string("," + channel)
  }
  out.write_string("\n")
  for sample in recording.samples {
    out.write_string(sample.timestamp_ms.to_string())
    for value in sample.values {
      out.write_string("," + value.to_string())
    }
    out.write_string("\n")
  }
  let text = out.to_string()
  match parse(text) {
    Ok(_) => Ok(text)
    Err(message) => Err(message)
  }
}
