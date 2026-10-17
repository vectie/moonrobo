///|
/// A human-selected closed interval. Reasons are user annotations, not verified
/// diagnoses. Overlapping intervals retain every matching ID in recipe order.
pub(all) struct ExclusionInterval {
  id : String
  start_ms : Int64
  end_ms : Int64
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ExclusionRecipe {
  editor_label : String
  max_gap_ms : Int64
  intervals : Array[ExclusionInterval]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validate_exclusion_recipe(recipe : ExclusionRecipe) -> Result[Unit, String] {
  if recipe.editor_label.trim().is_empty() || recipe.editor_label.length() > 256 {
    return Err("editor_label requires 1..256 nonblank text units")
  }
  if recipe.max_gap_ms <= 0L {
    return Err("max_gap_ms must be positive")
  }
  if recipe.intervals.length() > 128 {
    return Err("at most 128 exclusion intervals are supported")
  }
  let seen : Array[String] = []
  for interval in recipe.intervals {
    if interval.id.trim().is_empty() ||
      interval.id.length() > 64 ||
      seen.contains(interval.id) {
      return Err(
        "interval IDs must be unique nonblank strings of at most 64 units",
      )
    }
    seen.push(interval.id)
    if interval.start_ms < 0L || interval.end_ms < interval.start_ms {
      return Err(
        "interval " + interval.id + ": expected 0 <= start_ms <= end_ms",
      )
    }
    if interval.reason.trim().is_empty() || interval.reason.length() > 1024 {
      return Err(
        "interval " +
        interval.id +
        ": reason requires 1..1024 nonblank text units",
      )
    }
  }
  Ok(())
}

///|
/// Parse an exact-field recipe. Int64 times are decimal JSON strings, not
/// floating-point numbers. Duplicate and unknown keys fail at every depth.
pub fn parse_exclusion_recipe(text : String) -> Result[ExclusionRecipe, String] {
  if text.length() > 262144 {
    return Err("recipe exceeds 256 Ki UTF-16 units")
  }
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 3 else {
    return Err("recipe requires exactly editor_label, max_gap_ms and intervals")
  }
  for key in fields.keys() {
    if !["editor_label", "max_gap_ms", "intervals"].contains(key) {
      return Err("unknown recipe field: " + key)
    }
  }
  guard fields.get("intervals") is Some(Array(intervals)) else {
    return Err("intervals must be an array")
  }
  for interval in intervals {
    guard interval is Object(values) && values.length() == 4 else {
      return Err(
        "each interval requires exactly id, start_ms, end_ms and reason",
      )
    }
    for key in values.keys() {
      if !["id", "start_ms", "end_ms", "reason"].contains(key) {
        return Err("unknown interval field: " + key)
      }
    }
  }
  let recipe : ExclusionRecipe = @json.from_json(json) catch {
    _ =>
      return Err(
        "invalid recipe types; millisecond fields require Int64 strings",
      )
  }
  match validate_exclusion_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
