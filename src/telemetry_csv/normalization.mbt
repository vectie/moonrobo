///|
/// An explicit affine transformation. Unit strings are user labels, never
/// interpreted or checked for physical equivalence. All fields are required.
pub(all) struct ChannelMapping {
  source : String
  target : String
  scale : Double
  offset : Double
  source_unit : String
  target_unit : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NormalizedChannel {
  source : String
  target : String
  scale : Double
  offset : Double
  source_unit : String?
  target_unit : String?
  explicitly_mapped : Bool
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryNormalization {
  format : String
  timebase : String
  formula : String
  channels : Array[NormalizedChannel]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
/// Parse a strict JSON array of mappings; reject missing/unknown fields.
pub fn parse_normalization_recipe(
  text : String,
) -> Result[Array[ChannelMapping], String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  guard json is Array(entries) else { return Err("recipe must be an array") }
  let mappings : Array[ChannelMapping] = []
  for entry in entries {
    guard entry is Object(fields) else {
      return Err("recipe entries must be objects")
    }
    if fields.length() != 6 {
      return Err(
        "each mapping requires exactly source, target, scale, offset, source_unit, target_unit",
      )
    }
    let mapping : ChannelMapping = @json.from_json(entry) catch {
      _ => return Err("invalid mapping fields or types")
    }
    mappings.push(mapping)
  }
  Ok(mappings)
}

///|
fn normalization_label_valid(name : String) -> Bool {
  name != "" && name != "timestamp_ms" && merge_prefix_valid(name)
}

///|
/// Keep every original column in its original position, mapping by exact source
/// name. Unlisted columns pass through unchanged with unknown unit labels.
/// Renames are simultaneous; collisions are checked on the final column names.
/// Validate the entire source and all arithmetic; no partial result is returned.
pub fn normalize_csv(
  text : String,
  mappings : Array[ChannelMapping],
) -> Result[TelemetryNormalization, String] {
  let input = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let sources : Array[String] = []
  for mapping in mappings {
    if !input.channels.contains(mapping.source) {
      return Err("unknown source channel: " + mapping.source)
    }
    if sources.contains(mapping.source) {
      return Err("duplicate source mapping: " + mapping.source)
    }
    sources.push(mapping.source)
    if !normalization_label_valid(mapping.target) {
      return Err("invalid target channel: " + mapping.target)
    }
    if mapping.scale.is_nan() ||
      mapping.scale.is_inf() ||
      mapping.offset.is_nan() ||
      mapping.offset.is_inf() {
      return Err("scale and offset must be finite: " + mapping.source)
    }
    if mapping.source_unit.trim().is_empty() ||
      mapping.target_unit.trim().is_empty() {
      return Err(
        "unit labels must be nonempty; use an explicit label such as unspecified",
      )
    }
  }
  let channels : Array[NormalizedChannel] = []
  let names : Array[String] = []
  for name in input.channels {
    let channel : NormalizedChannel = match sources.search(name) {
      Some(index) => {
        let mapping = mappings[index]
        {
          source: name,
          target: mapping.target,
          scale: mapping.scale,
          offset: mapping.offset,
          source_unit: Some(mapping.source_unit),
          target_unit: Some(mapping.target_unit),
          explicitly_mapped: true,
        }
      }
      None =>
        {
          source: name,
          target: name,
          scale: 1.0,
          offset: 0.0,
          source_unit: None,
          target_unit: None,
          explicitly_mapped: false,
        }
    }
    if !normalization_label_valid(channel.target) {
      return Err(
        "channel cannot be exported as unquoted CSV: " + channel.target,
      )
    }
    if names.contains(channel.target) {
      return Err("duplicate output channel: " + channel.target)
    }
    names.push(channel.target)
    channels.push(channel)
  }
  let samples : Array[Sample] = []
  for sample in input.samples {
    let values : Array[Double] = []
    for i, channel in channels {
      let value = if channel.explicitly_mapped {
        sample.values[i] * channel.scale + channel.offset
      } else {
        sample.values[i]
      }
      if value.is_nan() || value.is_inf() {
        return Err(
          "non-finite transformed value at timestamp_ms " +
          sample.timestamp_ms.to_string() +
          ": " +
          channel.source,
        )
      }
      values.push(value)
    }
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
  }
  Ok({
    format: "moonrobo.telemetry-normalization.v1",
    timebase: "milliseconds-as-recorded",
    formula: "output = input * scale + offset",
    channels,
    recording: { channels: names, samples, },
  })
}

///|
/// Export reusable numeric CSV. Keep the JSON report and original source:
/// CSV alone cannot retain source names, supplied unit labels or the recipe.
pub fn TelemetryNormalization::to_csv(
  self : TelemetryNormalization,
) -> Result[String, String] {
  let out = StringBuilder()
  out.write_string("timestamp_ms")
  for channel in self.recording.channels {
    if !normalization_label_valid(channel) {
      return Err("invalid output channel")
    }
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
  let text = out.to_string()
  match parse(text) {
    Ok(_) => Ok(text)
    Err(message) => Err(message)
  }
}
