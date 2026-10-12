///|
/// A user-declared, fixed planar position transform. Translation is the source
/// origin expressed in the target frame, in the same units as both input axes.
pub(all) struct FrameRecipe {
  source_x : String
  source_y : String
  target_x : String
  target_y : String
  source_frame : String
  target_frame : String
  units : String
  yaw_degrees : Double
  translation_x : Double
  translation_y : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TelemetryFrameTransform {
  format : String
  timebase : String
  convention : String
  recipe : FrameRecipe
  source : Recording
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn validate_frame_recipe(recipe : FrameRecipe) -> Result[Unit, String] {
  if recipe.source_x == recipe.source_y || recipe.target_x == recipe.target_y {
    return Err("select distinct source X/Y and distinct target X/Y channels")
  }
  for
    name in [recipe.source_x, recipe.source_y, recipe.target_x, recipe.target_y] {
    if !normalization_label_valid(name) {
      return Err("invalid coordinate channel: " + name)
    }
  }
  if recipe.source_frame.trim().is_empty() ||
    recipe.target_frame.trim().is_empty() ||
    recipe.units.trim().is_empty() {
    return Err("source_frame, target_frame and units must be nonblank")
  }
  if recipe.source_frame == recipe.target_frame {
    return Err("source_frame and target_frame must name different frames")
  }
  if recipe.yaw_degrees.is_nan() ||
    recipe.yaw_degrees.is_inf() ||
    recipe.yaw_degrees < -180.0 ||
    recipe.yaw_degrees > 180.0 {
    return Err("yaw_degrees must be finite and within [-180, 180]")
  }
  if recipe.translation_x.is_nan() ||
    recipe.translation_x.is_inf() ||
    recipe.translation_y.is_nan() ||
    recipe.translation_y.is_inf() {
    return Err("translation_x and translation_y must be finite")
  }
  Ok(())
}

///|
/// Parse the complete ten-field position recipe, rejecting duplicate keys.
pub fn parse_frame_recipe(text : String) -> Result[FrameRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 10 else {
    return Err(
      "recipe requires exactly source_x, source_y, target_x, target_y, source_frame, target_frame, units, yaw_degrees, translation_x and translation_y",
    )
  }
  let recipe : FrameRecipe = @json.from_json(json) catch {
    _ => return Err("invalid frame recipe fields or types")
  }
  match validate_frame_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}

///|
/// Convert position coordinates by p_target = R(yaw) * p_source + translation.
/// Append two new columns, keeping all originals and every recorded timestamp.
/// Frames and units are assertions supplied by the user, never discovered from CSV.
pub fn transform_frame_csv(
  text : String,
  recipe : FrameRecipe,
) -> Result[TelemetryFrameTransform, String] {
  match validate_frame_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let xi = match source.channels.search(recipe.source_x) {
    Some(index) => index
    None => return Err("missing source X channel: " + recipe.source_x)
  }
  let yi = match source.channels.search(recipe.source_y) {
    Some(index) => index
    None => return Err("missing source Y channel: " + recipe.source_y)
  }
  for name in source.channels {
    if !normalization_label_valid(name) {
      return Err("channel cannot be exported as unquoted CSV: " + name)
    }
  }
  if source.channels.contains(recipe.target_x) ||
    source.channels.contains(recipe.target_y) {
    return Err(
      "target coordinate channels must be new; originals are never replaced",
    )
  }
  // Exact cardinal coefficients avoid a tiny artificial component when a large
  // coordinate is rotated by an exact quarter/half turn.
  let (c, s) = match recipe.yaw_degrees {
    0.0 => (1.0, 0.0)
    90.0 => (0.0, 1.0)
    -90.0 => (0.0, -1.0)
    180.0 | -180.0 => (-1.0, 0.0)
    degrees => {
      let radians = degrees * @math.PI / 180.0
      (@math.cos(radians), @math.sin(radians))
    }
  }
  let channels = source.channels.copy()
  channels.push(recipe.target_x)
  channels.push(recipe.target_y)
  let samples : Array[Sample] = []
  for sample in source.samples {
    let x = sample.values[xi]
    let y = sample.values[yi]
    let target_x = c * x - s * y + recipe.translation_x
    let target_y = s * x + c * y + recipe.translation_y
    if target_x.is_nan() ||
      target_x.is_inf() ||
      target_y.is_nan() ||
      target_y.is_inf() {
      return Err(
        "non-finite transformed position at timestamp_ms " +
        sample.timestamp_ms.to_string(),
      )
    }
    let values = sample.values.copy()
    values.push(target_x)
    values.push(target_y)
    samples.push({ timestamp_ms: sample.timestamp_ms, values, })
  }
  Ok({
    format: "moonrobo.telemetry-frame-transform.v1",
    timebase: "milliseconds-as-recorded",
    convention: "target_x=cos(yaw)*source_x-sin(yaw)*source_y+translation_x; target_y=sin(yaw)*source_x+cos(yaw)*source_y+translation_y; positive yaw is counterclockwise from +X toward +Y; translation is the source origin in target coordinates",
    recipe,
    source,
    recording: { channels, samples, },
  })
}

///|
/// Reusable CSV including the original and appended position channels. Retain
/// the JSON report separately for the declared frames, units and transform.
pub fn TelemetryFrameTransform::to_csv(
  self : TelemetryFrameTransform,
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
