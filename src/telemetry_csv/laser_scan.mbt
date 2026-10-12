///|
/// One recorded beam. Unusable ranges keep their source representation and have
/// no Cartesian coordinates. Offsets are seconds after the exact header stamp.
pub(all) struct LaserBeam {
  index : Int
  angle_rad : Double
  acquisition_offset_s : Double
  raw_range : Json
  status : String
  range_m : Double?
  intensity : Double?
  x_m : Double?
  y_m : Double?
} derive(Debug, Eq)

///|
fn laser_json_optional(value : Double?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => Json::null()
  }
}

///|
/// Emit explicit nulls for unavailable values; their omission could hide missing returns.
pub impl ToJson for LaserBeam with fn to_json(self) {
  {
    "index": self.index.to_json(),
    "angle_rad": self.angle_rad.to_json(),
    "acquisition_offset_s": self.acquisition_offset_s.to_json(),
    "raw_range": self.raw_range.to_json(),
    "status": self.status.to_json(),
    "range_m": laser_json_optional(self.range_m),
    "intensity": laser_json_optional(self.intensity),
    "x_m": laser_json_optional(self.x_m),
    "y_m": laser_json_optional(self.y_m),
  }
}

///|
/// A sensor-frame observation, with no transform, deskew or occupancy inference.
pub(all) struct LaserScan {
  source_line_number : Int
  sec : Int
  nanosec : Int
  frame_id : String
  angle_min_rad : Double
  angle_max_rad : Double
  angle_increment_rad : Double
  time_increment_s : Double
  scan_time_s : Double
  range_min_m : Double
  range_max_m : Double
  usable_count : Int
  beams : Array[LaserBeam]
} derive(Debug, Eq, ToJson)

///|
pub(all) struct LaserScanRecording {
  format : String
  coordinates : String
  timing : String
  frame_id : String
  scans : Array[LaserScan]
} derive(Debug, Eq, ToJson)

///|
fn laser_number(
  fields : Map[String, Json],
  key : String,
) -> Result[Double, String] {
  guard fields.get(key) is Some(Number(value)) &&
    !value.is_nan() &&
    !value.is_inf() else {
    return Err(key + " must be a finite JSON number")
  }
  Ok(value)
}

///|
fn laser_row(
  json : Json,
  frame : String,
  line : Int,
) -> Result[LaserScan, String] {
  guard json is Object(fields) else {
    return Err("expected a LaserScan object")
  }
  guard fields.get("header") is Some(Object(header)) &&
    header.get("stamp") is Some(Object(stamp)) &&
    header.get("frame_id") is Some(String(frame_id)) else {
    return Err("header requires stamp object and frame_id string")
  }
  if frame_id != frame {
    return Err("frame_id does not match requested sensor frame")
  }
  guard stamp.get("sec") is Some(raw_sec) &&
    stamp.get("nanosec") is Some(raw_ns) else {
    return Err("stamp requires ROS 2 sec and nanosec")
  }
  let sec = match joint_state_integer(raw_sec, 2147483647) {
    Ok(v) => v
    Err(e) => return Err("stamp.sec: " + e)
  }
  let nanosec = match joint_state_integer(raw_ns, 999999999) {
    Ok(v) => v
    Err(e) => return Err("stamp.nanosec: " + e)
  }
  let metadata : Map[String, Double] = {}
  for
    key in [
      "angle_min", "angle_max", "angle_increment", "time_increment", "scan_time",
      "range_min", "range_max",
    ] {
    metadata[key] = match laser_number(fields, key) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  let angle_min = metadata["angle_min"]
  let angle_max = metadata["angle_max"]
  let increment = metadata["angle_increment"]
  let time_increment = metadata["time_increment"]
  let scan_time = metadata["scan_time"]
  let range_min = metadata["range_min"]
  let range_max = metadata["range_max"]
  if increment == 0.0 {
    return Err("angle_increment must be nonzero")
  }
  if time_increment < 0.0 || scan_time < 0.0 {
    return Err("scan times must be nonnegative")
  }
  if range_min < 0.0 || range_max <= range_min {
    return Err("expected 0 <= range_min < range_max")
  }
  guard fields.get("ranges") is Some(Array(ranges)) && !ranges.is_empty() else {
    return Err("ranges must be a nonempty array")
  }
  guard fields.get("intensities") is Some(Array(intensities)) &&
    (intensities.is_empty() || intensities.length() == ranges.length()) else {
    return Err("intensities must be empty or match ranges length")
  }
  let last_angle = angle_min + (ranges.length() - 1).to_double() * increment
  // Source ROS fields are float32. Permit their accumulated rounding, never
  // invent beams from angle_max or reverse recorded ordering.
  let tolerance = 0.00001 *
    1.0.max(angle_min.abs()).max(angle_max.abs()).max(last_angle.abs())
  if last_angle.is_nan() ||
    last_angle.is_inf() ||
    (last_angle - angle_max).abs() > tolerance {
    return Err("angle_max disagrees with ranges length and angle_increment")
  }
  let beams : Array[LaserBeam] = []
  let mut usable_count = 0
  for index, raw_range in ranges {
    let angle_rad = angle_min + index.to_double() * increment
    let acquisition_offset_s = index.to_double() * time_increment
    if angle_rad.is_nan() || angle_rad.is_inf() || acquisition_offset_s.is_inf() {
      return Err("beam angle or acquisition offset exceeds finite range")
    }
    let intensity = if intensities.is_empty() {
      None
    } else {
      match intensities[index] {
        Number(v) if !v.is_nan() && !v.is_inf() => Some(v)
        Null => None
        _ => return Err("intensities must contain finite numbers or null")
      }
    }
    let range_m = match raw_range {
      Number(v) if !v.is_nan() && !v.is_inf() => Some(v)
      Null | String("NaN" | "Infinity" | "+Infinity" | "-Infinity") => None
      _ =>
        return Err(
          "ranges require numbers, null, NaN/Infinity strings; bare nonfinite JSON tokens are unsupported",
        )
    }
    let status = match range_m {
      Some(v) if v < range_min => "below-range"
      Some(v) if v > range_max => "above-range"
      Some(_) => "usable"
      None =>
        match raw_range {
          Null => "missing"
          String("NaN") => "nan"
          String("-Infinity") => "negative-infinity"
          _ => "positive-infinity"
        }
    }
    let (x_m, y_m) = if status == "usable" {
      let r = range_m.unwrap()
      usable_count += 1
      (Some(r * @math.cos(angle_rad)), Some(r * @math.sin(angle_rad)))
    } else {
      (None, None)
    }
    beams.push({
      index,
      angle_rad,
      acquisition_offset_s,
      raw_range,
      status,
      range_m,
      intensity,
      x_m,
      y_m,
    })
  }
  Ok({
    source_line_number: line,
    sec,
    nanosec,
    frame_id,
    angle_min_rad: angle_min,
    angle_max_rad: angle_max,
    angle_increment_rad: increment,
    time_increment_s: time_increment,
    scan_time_s: scan_time,
    range_min_m: range_min,
    range_max_m: range_max,
    usable_count,
    beams,
  })
}

///|
/// Import JSON-friendly exported ROS 2 LaserScan messages, one per nonblank line.
/// Keep exact nonnegative ROS stamps; reject duplicate/reversed scan timestamps.
/// Nonfinite ranges must be explicit strings or null, never invented zeros.
pub fn import_laser_scan_jsonl(
  text : String,
  frame_id : String,
) -> Result[LaserScanRecording, String] {
  if frame_id.trim().is_empty() {
    return Err("frame_id must explicitly name a nonblank sensor frame")
  }
  for ch in frame_id {
    if ch < ' ' || ch == '\u{7f}' || ch == '\u{fffe}' || ch == '\u{ffff}' {
      return Err(
        "frame_id must not contain control characters or XML noncharacters",
      )
    }
  }
  let scans : Array[LaserScan] = []
  let mut line_number = 0
  for line in text.split("\n") {
    line_number += 1
    if line.trim().is_empty() {
      continue
    }
    let prefix = "line \{line_number}: "
    let json = @json.parse(line) catch {
      _ =>
        return Err(
          prefix +
          "invalid JSON; encode nonfinite ranges as quoted NaN/Infinity or null",
        )
    }
    match jsonl_unique_object_keys(line) {
      Err(e) => return Err(prefix + e)
      Ok(_) => ()
    }
    let scan = match laser_row(json, frame_id, line_number) {
      Ok(v) => v
      Err(e) => return Err(prefix + e)
    }
    if scans.last() is Some(previous) &&
      (
        scan.sec < previous.sec ||
        (scan.sec == previous.sec && scan.nanosec <= previous.nanosec)
      ) {
      return Err(
        prefix +
        "scan header stamps must strictly increase; no scans dropped or merged",
      )
    }
    scans.push(scan)
  }
  if scans.is_empty() {
    return Err("JSONL requires at least one nonblank LaserScan object")
  }
  Ok({
    format: "moonrobo.ros2-laser-scan.v1",
    coordinates: "sensor-frame-metres-x-forward-y-left-positive-angle-about-z",
    timing: "exact-first-ray-ros-stamp-plus-relative-seconds-no-clock-domain-inferred",
    frame_id,
    scans,
  })
}
