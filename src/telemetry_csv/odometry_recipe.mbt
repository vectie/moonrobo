///|
/// Explicit pose and twist frames for an offline ROS 2 Odometry recording.
pub(all) struct OdometryRecipe {
  timestamp_policy : String
  quaternion_policy : String
  frame_id : String
  child_frame_id : String
  groups : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn odometry_channels(group : String) -> Array[String] {
  match group {
    "position" => ["odom.pose.x.m", "odom.pose.y.m", "odom.pose.z.m"]
    "quaternion" =>
      ["odom.pose.q.x", "odom.pose.q.y", "odom.pose.q.z", "odom.pose.q.w"]
    "attitude" =>
      ["odom.pose.roll.rad", "odom.pose.pitch.rad", "odom.pose.yaw.rad"]
    "linear_velocity" =>
      [
        "odom.twist.linear.x.m_s", "odom.twist.linear.y.m_s", "odom.twist.linear.z.m_s",
      ]
    "angular_velocity" =>
      [
        "odom.twist.angular.x.rad_s", "odom.twist.angular.y.rad_s", "odom.twist.angular.z.rad_s",
      ]
    _ => []
  }
}

///|
fn validate_odometry_recipe(recipe : OdometryRecipe) -> Result[Unit, String] {
  if recipe.timestamp_policy != "exact-milliseconds" &&
    recipe.timestamp_policy != "floor-milliseconds" {
    return Err(
      "timestamp_policy must be exact-milliseconds or floor-milliseconds",
    )
  }
  if recipe.quaternion_policy != "require-unit" &&
    recipe.quaternion_policy != "normalize" {
    return Err("quaternion_policy must be require-unit or normalize")
  }
  if recipe.frame_id.trim().is_empty() ||
    recipe.child_frame_id.trim().is_empty() {
    return Err(
      "frame_id and child_frame_id must explicitly name nonblank recorded frames",
    )
  }
  if recipe.groups.is_empty() {
    return Err("groups must not be empty")
  }
  let seen : Array[String] = []
  for group in recipe.groups {
    if odometry_channels(group).is_empty() {
      return Err("unknown Odometry group: " + group)
    }
    if seen.contains(group) {
      return Err("duplicate Odometry group: " + group)
    }
    seen.push(group)
  }
  Ok(())
}

///|
/// Parse a five-field recipe; reject missing, extra and duplicate keys.
pub fn parse_odometry_recipe(text : String) -> Result[OdometryRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 5 else {
    return Err(
      "recipe requires exactly timestamp_policy, quaternion_policy, frame_id, child_frame_id and groups",
    )
  }
  let recipe : OdometryRecipe = @json.from_json(json) catch {
    _ => return Err("invalid Odometry recipe fields or types")
  }
  match validate_odometry_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
