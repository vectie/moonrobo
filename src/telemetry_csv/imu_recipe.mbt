///|
/// Explicit frame, precision and orientation choices for recorded ROS 2 Imu.
pub(all) struct ImuRecipe {
  timestamp_policy : String
  quaternion_policy : String
  frame_id : String
  groups : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn imu_group_channels(group : String) -> Array[String] {
  match group {
    "attitude" => ["imu.roll.rad", "imu.pitch.rad", "imu.yaw.rad"]
    "quaternion" => ["imu.q.x", "imu.q.y", "imu.q.z", "imu.q.w"]
    "angular_velocity" =>
      ["imu.gyro.x.rad_s", "imu.gyro.y.rad_s", "imu.gyro.z.rad_s"]
    "linear_acceleration" =>
      ["imu.accel.x.m_s2", "imu.accel.y.m_s2", "imu.accel.z.m_s2"]
    _ => []
  }
}

///|
fn validate_imu_recipe(recipe : ImuRecipe) -> Result[Unit, String] {
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
  if recipe.frame_id.trim().is_empty() {
    return Err("frame_id must explicitly name a nonblank recorded frame")
  }
  if recipe.groups.is_empty() {
    return Err("groups must not be empty")
  }
  let seen : Array[String] = []
  for group in recipe.groups {
    if imu_group_channels(group).is_empty() {
      return Err("unknown IMU group: " + group)
    }
    if seen.contains(group) {
      return Err("duplicate IMU group: " + group)
    }
    seen.push(group)
  }
  Ok(())
}

///|
/// Parse a strict recipe; duplicate, missing and unknown keys are rejected.
pub fn parse_imu_recipe(text : String) -> Result[ImuRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 4 else {
    return Err(
      "recipe requires exactly timestamp_policy, quaternion_policy, frame_id and groups",
    )
  }
  let recipe : ImuRecipe = @json.from_json(json) catch {
    _ => return Err("invalid IMU recipe fields or types")
  }
  match validate_imu_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
