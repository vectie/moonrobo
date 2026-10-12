///|
/// Exact nested-object keys, output channel name, and descriptive unit label.
/// Paths never interpret dots, slashes, array indexes, or wildcards.
pub(all) struct JsonlChannel {
  path : Array[String]
  target : String
  unit : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct JsonlRecipe {
  timestamp_path : Array[String]
  channels : Array[JsonlChannel]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validate_jsonl_recipe(recipe : JsonlRecipe) -> Result[Unit, String] {
  if recipe.timestamp_path.is_empty() {
    return Err("timestamp_path must contain at least one object key")
  }
  if recipe.channels.is_empty() {
    return Err("recipe requires at least one channel")
  }
  let names : Array[String] = []
  for channel in recipe.channels {
    if channel.path.is_empty() {
      return Err(
        "channel path must contain at least one object key: " + channel.target,
      )
    }
    if !normalization_label_valid(channel.target) {
      return Err("invalid output channel: " + channel.target)
    }
    if names.contains(channel.target) {
      return Err("duplicate output channel: " + channel.target)
    }
    if channel.unit.trim().is_empty() {
      return Err("unit label must be nonblank: " + channel.target)
    }
    names.push(channel.target)
  }
  Ok(())
}

///|
/// Parse the explicit recipe; unknown and missing fields are errors.
pub fn parse_jsonl_recipe(text : String) -> Result[JsonlRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 2 else {
    return Err("recipe requires exactly timestamp_path and channels")
  }
  guard fields.get("channels") is Some(Array(channels)) else {
    return Err("recipe channels must be an array")
  }
  for channel in channels {
    guard channel is Object(fields) && fields.length() == 3 else {
      return Err("each channel requires exactly path, target and unit")
    }
  }
  let recipe : JsonlRecipe = @json.from_json(json) catch {
    _ => return Err("invalid recipe fields or types")
  }
  match validate_jsonl_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
