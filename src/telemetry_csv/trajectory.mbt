///|
/// A recorded position and its incoming observed interval. Disconnected points
/// have no distance/speed estimate; zero is only a placeholder when connected=false.
pub(all) struct TrackPoint {
  timestamp_ms : Int64
  x : Double
  y : Double
  segment : Int
  connected : Bool
  distance : Double
  speed : Double
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Trajectory {
  format : String
  x_channel : String
  y_channel : String
  units : String
  max_gap_ms : Int64
  start_ms : Int64
  end_ms : Int64
  points : Array[TrackPoint]
  segment_count : Int
  gap_count : Int
  observed_duration_ms : Int64
  observed_distance : Double
  peak_interval_speed : Double
  minimum_x : Double
  maximum_x : Double
  minimum_y : Double
  maximum_y : Double
} derive(Debug, Eq, ToJson)

///|
/// Explore two same-unit Cartesian position channels in their existing frame.
/// Inclusive absolute timestamp window, no interpolation. Intervals longer than
/// max_gap_ms begin another segment and contribute no distance, time or speed.
pub fn trajectory_csv(
  text : String,
  x_channel : String,
  y_channel : String,
  units? : String = "coordinate-units",
  max_gap_ms? : Int64 = 1000L,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
) -> Result[Trajectory, String] {
  if max_gap_ms <= 0L || start_ms < 0L || end_ms < start_ms {
    return Err("expected max_gap_ms > 0 and 0 <= start_ms <= end_ms")
  }
  if x_channel == y_channel || units.trim().is_empty() {
    return Err("select distinct X/Y channels and a nonempty units label")
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let xi = match recording.channels.search(x_channel) {
    Some(index) => index
    None => return Err("missing X channel: " + x_channel)
  }
  let yi = match recording.channels.search(y_channel) {
    Some(index) => index
    None => return Err("missing Y channel: " + y_channel)
  }
  let samples = recording.samples.filter(s => {
    s.timestamp_ms >= start_ms && s.timestamp_ms <= end_ms
  })
  if samples.is_empty() {
    return Err("selected window contains no positions")
  }
  let points : Array[TrackPoint] = []
  let mut segment = 0
  let mut duration = 0L
  let mut total = 0.0
  let mut peak = 0.0
  let mut min_x = samples[0].values[xi]
  let mut max_x = min_x
  let mut min_y = samples[0].values[yi]
  let mut max_y = min_y
  for i, sample in samples {
    let x = sample.values[xi]
    let y = sample.values[yi]
    min_x = min_x.min(x)
    max_x = max_x.max(x)
    min_y = min_y.min(y)
    max_y = max_y.max(y)
    let mut connected = false
    let mut distance = 0.0
    let mut speed = 0.0
    if i > 0 {
      let previous = samples[i - 1]
      let dt = sample.timestamp_ms - previous.timestamp_ms
      if dt <= max_gap_ms {
        connected = true
        let dx = (x - previous.values[xi]).abs()
        let dy = (y - previous.values[yi]).abs()
        let scale = dx.max(dy)
        distance = if scale == 0.0 {
          0.0
        } else {
          scale * (dx / scale * (dx / scale) + dy / scale * (dy / scale)).sqrt()
        }
        speed = distance / (dt.to_double() / 1000.0)
        total += distance
        duration += dt
        peak = peak.max(speed)
        if (distance.is_nan() || distance.is_inf()) ||
          (speed.is_nan() || speed.is_inf()) ||
          total.is_nan() ||
          total.is_inf() {
          return Err(
            "position difference or accumulated distance/speed exceeds finite range",
          )
        }
      } else {
        segment += 1
      }
    }
    points.push({
      timestamp_ms: sample.timestamp_ms,
      x,
      y,
      segment,
      connected,
      distance,
      speed,
    })
  }
  if (max_x - min_x).is_inf() || (max_y - min_y).is_inf() {
    return Err("coordinate extent exceeds finite range")
  }
  Ok({
    format: "moonrobo.trajectory.v1",
    x_channel,
    y_channel,
    units,
    max_gap_ms,
    start_ms,
    end_ms,
    points,
    segment_count: segment + 1,
    gap_count: segment,
    observed_duration_ms: duration,
    observed_distance: total,
    peak_interval_speed: peak,
    minimum_x: min_x,
    maximum_x: max_x,
    minimum_y: min_y,
    maximum_y: max_y,
  })
}
