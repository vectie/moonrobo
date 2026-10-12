///|
/// One physical JSONL line's original ROS stamp and selected array positions.
/// Joint indices are in recipe order; frame_id is retained, not interpreted.
pub(all) struct JointStateSource {
  source_line_number : Int
  sec : Int
  nanosec : Int
  discarded_nanoseconds : Int
  frame_id : String
  joint_indices : Array[Int]
} derive(Debug, Eq, ToJson)

///|
/// Offline import only; this result grants no robot or device authority.
pub(all) struct JointStateImport {
  format : String
  timebase : String
  recipe : JointStateRecipe
  sources : Array[JointStateSource]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn joint_state_integer(value : Json, maximum : Int) -> Result[Int, String] {
  guard value is Number(number) &&
    !number.is_nan() &&
    !number.is_inf() &&
    number >= 0.0 &&
    number <= maximum.to_double() else {
    return Err("expected a nonnegative in-range JSON integer")
  }
  let integer = number.to_int()
  if integer.to_double() != number {
    return Err("expected a nonnegative in-range JSON integer")
  }
  Ok(integer)
}

///|
fn joint_state_row(
  json : Json,
  recipe : JointStateRecipe,
  line_number : Int,
) -> Result[(Sample, JointStateSource), String] {
  guard json is Object(fields) else {
    return Err("expected a JointState JSON object")
  }
  guard fields.get("header") is Some(Object(header)) &&
    header.get("stamp") is Some(Object(stamp)) &&
    header.get("frame_id") is Some(String(frame_id)) else {
    return Err("header requires stamp object and frame_id string")
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
      "stamp has sub-millisecond precision; explicitly choose floor-milliseconds to discard it",
    )
  }
  let timestamp_ms = sec.to_int64() * 1000L + (nanosec / 1000000).to_int64()
  guard fields.get("name") is Some(Array(raw_names)) && !raw_names.is_empty() else {
    return Err("name must be a nonempty array of joint names")
  }
  let names : Array[String] = []
  for raw_name in raw_names {
    guard raw_name is String(name) && !name.trim().is_empty() else {
      return Err("joint names must be nonblank strings")
    }
    if names.contains(name) {
      return Err("duplicate joint name " + name.to_json().stringify())
    }
    names.push(name)
  }
  let arrays : Map[String, Array[Double]] = {}
  for field in ["position", "velocity", "effort"] {
    guard fields.get(field) is Some(Array(raw_values)) else {
      return Err(field + " must be an array (empty when unavailable)")
    }
    if !raw_values.is_empty() && raw_values.length() != names.length() {
      return Err(field + " array must be empty or match name length")
    }
    let values : Array[Double] = []
    for raw in raw_values {
      guard raw is Number(value) && !value.is_nan() && !value.is_inf() else {
        return Err(field + " requires finite JSON numbers")
      }
      values.push(value)
    }
    arrays[field] = values
  }
  let values : Array[Double] = []
  let joint_indices : Array[Int] = []
  for channel in recipe.channels {
    let mut index = -1
    for i, name in names {
      if name == channel.joint {
        index = i
        break
      }
    }
    if index < 0 {
      return Err(
        "missing selected joint " + channel.joint.to_json().stringify(),
      )
    }
    let array = arrays[channel.field]
    if array.is_empty() {
      return Err("selected field " + channel.field + " is unavailable")
    }
    values.push(array[index])
    joint_indices.push(index)
  }
  Ok(
    (
      { timestamp_ms, values, },
      {
        source_line_number: line_number,
        sec,
        nanosec,
        discarded_nanoseconds,
        frame_id,
        joint_indices,
      },
    ),
  )
}

///|
/// Import one ROS 2 JointState object per nonblank JSONL line. Every message
/// validates all three numeric arrays; selected joints resolve by name anew.
/// Millisecond collisions, missing observations and clock reversal are errors.
pub fn import_joint_state_jsonl(
  text : String,
  recipe : JointStateRecipe,
) -> Result[JointStateImport, String] {
  match validate_joint_state_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  let samples : Array[Sample] = []
  let sources : Array[JointStateSource] = []
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
    let (sample, source) = match joint_state_row(json, recipe, line_number) {
      Ok(value) => value
      Err(message) => return Err(prefix + message)
    }
    if samples.last() is Some(previous) &&
      sample.timestamp_ms <= previous.timestamp_ms {
      return Err(
        prefix +
        "millisecond timestamps must strictly increase; collision or clock reversal (no rows merged or dropped)",
      )
    }
    samples.push(sample)
    sources.push(source)
  }
  if samples.is_empty() {
    return Err("JSONL requires at least one nonblank JointState object line")
  }
  Ok({
    format: "moonrobo.ros2-joint-state-import.v1",
    timebase: "ros-stamp-milliseconds-no-clock-domain-inferred",
    recipe,
    sources,
    recording: { channels: recipe.channels.map(c => c.target), samples, },
  })
}

///|
/// Export numeric CSV for the existing explorer, plotter and comparator.
/// Retain the JSON report and original JSONL for stamp precision and lineage.
pub fn JointStateImport::to_csv(
  self : JointStateImport,
) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
