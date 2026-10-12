///|
/// Exact stamp, raw quaternion and unchanged row-major 6x6 covariance arrays.
/// Covariances are neither validated statistically nor propagated to Euler angles.
pub(all) struct OdometrySource {
  source_line_number : Int
  sec : Int
  nanosec : Int
  discarded_nanoseconds : Int
  frame_id : String
  child_frame_id : String
  raw_orientation_xyzw : Array[Double]
  quaternion_norm : Double
  pose_covariance : Array[Double]
  twist_covariance : Array[Double]
} derive(Debug, Eq, ToJson)

///|
/// Offline estimates. Pose channels use header.frame_id; twist uses child_frame_id.
pub(all) struct OdometryImport {
  format : String
  timebase : String
  attitude_convention : String
  covariance_policy : String
  recipe : OdometryRecipe
  channel_frames : Map[String, String]
  sources : Array[OdometrySource]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn odometry_covariance(value : Json) -> Result[Array[Double], String] {
  guard value is Array(raw) && raw.length() == 36 else {
    return Err("covariance must contain exactly 36 numbers")
  }
  let values : Array[Double] = []
  for item in raw {
    guard item is Number(value) && !value.is_nan() && !value.is_inf() else {
      return Err("covariance must contain finite JSON numbers")
    }
    values.push(value)
  }
  Ok(values)
}

///|
fn odometry_row(
  json : Json,
  recipe : OdometryRecipe,
  line_number : Int,
) -> Result[(Sample, OdometrySource), String] {
  guard json is Object(fields) else {
    return Err("expected an Odometry JSON object")
  }
  guard fields.get("header") is Some(Object(header)) &&
    header.get("stamp") is Some(Object(stamp)) &&
    header.get("frame_id") is Some(String(frame_id)) &&
    fields.get("child_frame_id") is Some(String(child_frame_id)) else {
    return Err("header requires stamp and frame_id; child_frame_id is required")
  }
  if frame_id != recipe.frame_id || child_frame_id != recipe.child_frame_id {
    return Err(
      "pose frame_id or twist child_frame_id does not match recipe; no frame transform is inferred",
    )
  }
  guard stamp.get("sec") is Some(raw_sec) &&
    stamp.get("nanosec") is Some(raw_nanosec) else {
    return Err("stamp requires ROS 2 sec and nanosec fields")
  }
  let sec = match joint_state_integer(raw_sec, 2147483647) {
    Ok(value) => value
    Err(message) => return Err("stamp.sec: " + message)
  }
  let nanosec = match joint_state_integer(raw_nanosec, 999999999) {
    Ok(value) => value
    Err(message) => return Err("stamp.nanosec: " + message)
  }
  let discarded_nanoseconds = nanosec % 1000000
  if recipe.timestamp_policy == "exact-milliseconds" &&
    discarded_nanoseconds != 0 {
    return Err(
      "stamp has sub-millisecond precision; choose floor-milliseconds explicitly",
    )
  }
  guard fields.get("pose") is Some(Object(pose_wrapper)) &&
    pose_wrapper.get("pose") is Some(Object(pose)) &&
    pose.get("position") is Some(raw_position) &&
    pose.get("orientation") is Some(raw_orientation) &&
    pose_wrapper.get("covariance") is Some(raw_pose_covariance) else {
    return Err(
      "pose requires nested pose.position, pose.orientation and covariance",
    )
  }
  guard fields.get("twist") is Some(Object(twist_wrapper)) &&
    twist_wrapper.get("twist") is Some(Object(twist)) &&
    twist.get("linear") is Some(raw_linear) &&
    twist.get("angular") is Some(raw_angular) &&
    twist_wrapper.get("covariance") is Some(raw_twist_covariance) else {
    return Err(
      "twist requires nested twist.linear, twist.angular and covariance",
    )
  }
  let vectors : Map[String, Array[Double]] = {}
  for
    (name, value) in [
      ("position", raw_position),
      ("quaternion", raw_orientation),
      ("linear_velocity", raw_linear),
      ("angular_velocity", raw_angular),
    ] {
    let keys = if name == "quaternion" {
      ["x", "y", "z", "w"]
    } else {
      ["x", "y", "z"]
    }
    vectors[name] = match imu_vector(value, keys) {
      Ok(value) => value
      Err(message) => return Err(name + ": " + message)
    }
  }
  let pose_covariance = match odometry_covariance(raw_pose_covariance) {
    Ok(value) => value
    Err(message) => return Err("pose: " + message)
  }
  let twist_covariance = match odometry_covariance(raw_twist_covariance) {
    Ok(value) => value
    Err(message) => return Err("twist: " + message)
  }
  let raw_orientation_xyzw = vectors["quaternion"]
  let (quaternion, quaternion_norm) = match
    imu_quaternion(raw_orientation_xyzw, recipe.quaternion_policy) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  vectors["quaternion"] = quaternion
  let values : Array[Double] = []
  for group in recipe.groups {
    let group_values = if group == "attitude" {
      match imu_attitude(quaternion) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
    } else {
      vectors[group]
    }
    for value in group_values {
      values.push(value)
    }
  }
  Ok(
    (
      {
        timestamp_ms: sec.to_int64() * 1000L + (nanosec / 1000000).to_int64(),
        values,
      },
      {
        source_line_number: line_number,
        sec,
        nanosec,
        discarded_nanoseconds,
        frame_id,
        child_frame_id,
        raw_orientation_xyzw,
        quaternion_norm,
        pose_covariance,
        twist_covariance,
      },
    ),
  )
}

///|
/// Import one exported nav_msgs/Odometry object per nonblank line, validating all
/// pose/twist fields before any output. Timestamps must strictly increase in ms.
pub fn import_odometry_jsonl(
  text : String,
  recipe : OdometryRecipe,
) -> Result[OdometryImport, String] {
  match validate_odometry_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let samples : Array[Sample] = []
  let sources : Array[OdometrySource] = []
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
    let (sample, source) = match odometry_row(json, recipe, line_number) {
      Ok(value) => value
      Err(message) => return Err(prefix + message)
    }
    if samples.last() is Some(previous) &&
      sample.timestamp_ms <= previous.timestamp_ms {
      return Err(
        prefix +
        "millisecond timestamps must strictly increase; no rows merged or dropped",
      )
    }
    samples.push(sample)
    sources.push(source)
  }
  if samples.is_empty() {
    return Err("JSONL requires at least one nonblank Odometry object line")
  }
  let channels : Array[String] = []
  let channel_frames : Map[String, String] = {}
  for group in recipe.groups {
    let frame = if group == "linear_velocity" || group == "angular_velocity" {
      recipe.child_frame_id
    } else {
      recipe.frame_id
    }
    for channel in odometry_channels(group) {
      channels.push(channel)
      channel_frames[channel] = frame
    }
  }
  Ok({
    format: "moonrobo.ros2-odometry-import.v1",
    timebase: "ros-stamp-milliseconds-no-clock-domain-inferred",
    attitude_convention: "fixed-axis-xyz-radians-Rz(yaw)-Ry(pitch)-Rx(roll)",
    covariance_policy: "raw-row-major-6x6-unvalidated-not-transformed",
    recipe,
    channel_frames,
    sources,
    recording: { channels, samples, },
  })
}

///|
/// Reusable numeric CSV. Keep JSON metadata and original recording alongside it.
pub fn OdometryImport::to_csv(self : OdometryImport) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
