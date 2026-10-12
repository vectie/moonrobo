///|
/// Explicit periodic source, output name, period and descriptive unit label.
pub(all) struct PeriodicChannel {
  source : String
  target : String
  period : Double
  unit : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validate_unwrap_recipe(
  channels : Array[PeriodicChannel],
) -> Result[Unit, String] {
  if channels.is_empty() {
    return Err("recipe requires at least one periodic channel")
  }
  let sources : Array[String] = []
  let targets : Array[String] = []
  for channel in channels {
    if !normalization_label_valid(channel.source) ||
      !normalization_label_valid(channel.target) {
      return Err("source and target must be valid unquoted CSV channel names")
    }
    if sources.contains(channel.source) || targets.contains(channel.target) {
      return Err("duplicate source or target channel")
    }
    if channel.period.is_nan() ||
      channel.period.is_inf() ||
      channel.period <= 0.0 ||
      channel.period / 2.0 == 0.0 {
      return Err(
        "period must be positive and finite with a representable half-period",
      )
    }
    if channel.unit.trim().is_empty() {
      return Err("unit label must be nonblank")
    }
    sources.push(channel.source)
    targets.push(channel.target)
  }
  Ok(())
}

///|
/// Parse a nonempty array of explicit periodic channels. No implicit degrees,
/// radians, source names or periods; unknown and duplicate object keys fail.
pub fn parse_unwrap_recipe(
  text : String,
) -> Result[Array[PeriodicChannel], String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Array(entries) else { return Err("recipe must be an array") }
  for entry in entries {
    guard entry is Object(fields) && fields.length() == 4 else {
      return Err(
        "each periodic channel requires exactly source, target, period and unit",
      )
    }
  }
  let channels : Array[PeriodicChannel] = @json.from_json(json) catch {
    _ => return Err("invalid recipe fields or types")
  }
  match validate_unwrap_recipe(channels) {
    Err(message) => Err(message)
    Ok(_) => Ok(channels)
  }
}
