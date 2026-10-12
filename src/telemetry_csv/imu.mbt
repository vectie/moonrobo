///|
/// Original stamp, orientation and covariance metadata for one input line.
/// Covariances remain in the source basis; none are propagated to Euler angles.
pub(all) struct ImuSource {
  source_line_number : Int
  sec : Int
  nanosec : Int
  discarded_nanoseconds : Int
  frame_id : String
  raw_orientation_xyzw : Array[Double]
  quaternion_norm : Double?
  covariances : Map[String, Array[Double]]
  covariance_status : Map[String, String]
} derive(Debug, Eq, ToJson)

///|
/// Offline IMU-derived channels, never a physical action or calibration proof.
pub(all) struct ImuImport {
  format : String
  timebase : String
  attitude_convention : String
  recipe : ImuRecipe
  sources : Array[ImuSource]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn imu_vector(
  value : Json,
  keys : Array[String],
) -> Result[Array[Double], String] {
  guard value is Object(fields) else {
    return Err("expected a component object")
  }
  let result : Array[Double] = []
  for key in keys {
    guard fields.get(key) is Some(Number(value)) &&
      !value.is_nan() &&
      !value.is_inf() else {
      return Err("component " + key + " must be a finite JSON number")
    }
    result.push(value)
  }
  Ok(result)
}

///|
fn imu_row(
  json : Json,
  recipe : ImuRecipe,
  line_number : Int,
) -> Result[(Sample, ImuSource), String] {
  guard json is Object(fields) else {
    return Err("expected an Imu JSON object")
  }
  guard fields.get("header") is Some(Object(header)) &&
    header.get("stamp") is Some(Object(stamp)) &&
    header.get("frame_id") is Some(String(frame_id)) else {
    return Err("header requires stamp object and frame_id string")
  }
  if frame_id != recipe.frame_id {
    return Err("frame_id does not match recipe; no frame transform is inferred")
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
  let vectors : Map[String, Array[Double]] = {}
  let covariances : Map[String, Array[Double]] = {}
  let covariance_status : Map[String, String] = {}
  for group in ["orientation", "angular_velocity", "linear_acceleration"] {
    guard fields.get(group) is Some(raw) else { return Err("missing " + group) }
    let keys = if group == "orientation" {
      ["x", "y", "z", "w"]
    } else {
      ["x", "y", "z"]
    }
    vectors[group] = match imu_vector(raw, keys) {
      Ok(value) => value
      Err(message) => return Err(group + ": " + message)
    }
    guard fields.get(group + "_covariance") is Some(Array(raw_covariance)) &&
      raw_covariance.length() == 9 else {
      return Err(group + "_covariance must contain exactly nine numbers")
    }
    let covariance : Array[Double] = []
    let mut all_zero = true
    for raw_value in raw_covariance {
      guard raw_value is Number(value) && !value.is_nan() && !value.is_inf() else {
        return Err(group + "_covariance must contain finite JSON numbers")
      }
      if value != 0.0 {
        all_zero = false
      }
      covariance.push(value)
    }
    covariances[group] = covariance
    covariance_status[group] = if covariance[0] == -1.0 {
      "unavailable"
    } else if all_zero {
      "unknown"
    } else {
      "provided-unvalidated"
    }
  }
  let values : Array[Double] = []
  let mut quaternion_norm : Double? = None
  for group in recipe.groups {
    let measurement = if group == "attitude" || group == "quaternion" {
      "orientation"
    } else {
      group
    }
    if covariance_status[measurement] == "unavailable" {
      return Err(
        "selected " +
        measurement +
        " estimate is unavailable (covariance[0] = -1)",
      )
    }
    let group_values = if measurement == "orientation" {
      let (q, norm) = match
        imu_quaternion(vectors[measurement], recipe.quaternion_policy) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      quaternion_norm = Some(norm)
      if group == "attitude" {
        match imu_attitude(q) {
          Ok(value) => value
          Err(message) => return Err(message)
        }
      } else {
        q
      }
    } else {
      vectors[measurement]
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
        raw_orientation_xyzw: vectors["orientation"],
        quaternion_norm,
        covariances,
        covariance_status,
      },
    ),
  )
}

///|
/// Import exported ROS 2 sensor_msgs/Imu objects, one per nonblank JSONL line.
/// Validates every line and measurement shape before emitting any recording.
pub fn import_imu_jsonl(
  text : String,
  recipe : ImuRecipe,
) -> Result[ImuImport, String] {
  match validate_imu_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let samples : Array[Sample] = []
  let sources : Array[ImuSource] = []
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
    let (sample, source) = match imu_row(json, recipe, line_number) {
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
    return Err("JSONL requires at least one nonblank Imu object line")
  }
  let channels : Array[String] = []
  for group in recipe.groups {
    for channel in imu_group_channels(group) {
      channels.push(channel)
    }
  }
  Ok({
    format: "moonrobo.ros2-imu-import.v1",
    timebase: "ros-stamp-milliseconds-no-clock-domain-inferred",
    attitude_convention: "fixed-axis-xyz-radians-Rz(yaw)-Ry(pitch)-Rx(roll)",
    recipe,
    sources,
    recording: { channels, samples, },
  })
}

///|
/// Export reusable numeric CSV; retain JSON and raw input for source metadata.
pub fn ImuImport::to_csv(self : ImuImport) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
