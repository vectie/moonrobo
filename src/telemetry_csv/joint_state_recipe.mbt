///|
/// A literal ROS joint name, selected JointState field, and output labels.
pub(all) struct JointStateChannel {
  joint : String
  field : String
  target : String
  unit : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The timestamp policy explicitly chooses exact or floored milliseconds.
pub(all) struct JointStateRecipe {
  timestamp_policy : String
  channels : Array[JointStateChannel]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validate_joint_state_recipe(
  recipe : JointStateRecipe,
) -> Result[Unit, String] {
  if recipe.timestamp_policy != "exact-milliseconds" &&
    recipe.timestamp_policy != "floor-milliseconds" {
    return Err(
      "timestamp_policy must be exact-milliseconds or floor-milliseconds",
    )
  }
  if recipe.channels.is_empty() {
    return Err("recipe requires at least one channel")
  }
  let targets : Array[String] = []
  let selected : Array[(String, String)] = []
  for channel in recipe.channels {
    if channel.joint.trim().is_empty() {
      return Err("joint name must be nonblank")
    }
    if channel.field != "position" &&
      channel.field != "velocity" &&
      channel.field != "effort" {
      return Err("field must be position, velocity or effort")
    }
    if !normalization_label_valid(channel.target) {
      return Err("invalid output channel: " + channel.target)
    }
    if targets.contains(channel.target) {
      return Err("duplicate output channel: " + channel.target)
    }
    if selected.contains((channel.joint, channel.field)) {
      return Err("duplicate joint/field selection")
    }
    if channel.unit.trim().is_empty() {
      return Err("unit label must be nonblank: " + channel.target)
    }
    targets.push(channel.target)
    selected.push((channel.joint, channel.field))
  }
  Ok(())
}

///|
/// Parse an explicit selection recipe. Unknown or duplicate keys are errors.
pub fn parse_joint_state_recipe(
  text : String,
) -> Result[JointStateRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 2 else {
    return Err("recipe requires exactly timestamp_policy and channels")
  }
  guard fields.get("channels") is Some(Array(channels)) else {
    return Err("recipe channels must be an array")
  }
  for channel in channels {
    guard channel is Object(fields) && fields.length() == 4 else {
      return Err("each channel requires exactly joint, field, target and unit")
    }
  }
  let recipe : JointStateRecipe = @json.from_json(json) catch {
    _ => return Err("invalid recipe fields or types")
  }
  match validate_joint_state_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
