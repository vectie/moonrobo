///|
/// Selected original observations and their position in the recording.
pub(all) struct EnergyPoint {
  source_sample_index : Int
  timestamp_ms : Int64
  segment : Int
  segment_start : Bool
  voltage_v : Double
  current_a : Double
  power_w : Double
} derive(Debug, Eq, ToJson)

///|
/// One supported interval. Energy assumes linear power between its two samples.
pub(all) struct EnergyInterval {
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  duration_ms : Int64
  segment : Int
  zero_crossing_fraction : Double?
  drawn_wh : Double
  recovered_wh : Double
  net_wh : Double
} derive(Debug, Eq, ToJson)

///|
/// Missing duration excluded from every accumulated energy quantity.
pub(all) struct EnergyGap {
  left_sample_index : Int
  right_sample_index : Int
  left_timestamp_ms : Int64
  right_timestamp_ms : Int64
  duration_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryEnergy {
  format : String
  timebase : String
  method : String
  voltage_channel : String
  current_channel : String
  voltage_unit : String
  current_unit : String
  current_polarity : String
  max_gap_ms : Int64
  source_sample_count : Int
  segment_count : Int
  supported_interval_count : Int
  integrated_duration_ms : Int64
  excluded_duration_ms : Int64
  drawn_wh : Double
  recovered_wh : Double
  net_wh : Double
  points : Array[EnergyPoint]
  intervals : Array[EnergyInterval]
  gaps : Array[EnergyGap]
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
/// Estimate signed electrical energy from explicitly named voltage (V) and
/// current (A) channels. Voltage is a nonnegative terminal magnitude. Positive
/// normalized power means draw; negative means recovery. The current polarity
/// must be supplied, never guessed. Long intervals are excluded, not zero-filled.
/// Integrate linearly interpolated sample POWER, not the product of interpolated
/// voltage and current. Split sign-changing intervals at the modeled zero.
pub fn energy_csv(
  text : String,
  voltage_channel : String,
  current_channel : String,
  current_polarity~ : String,
  max_gap_ms~ : Int64,
) -> Result[TelemetryEnergy, String] {
  if max_gap_ms <= 0L {
    return Err("max_gap_ms must be positive")
  }
  if current_polarity != "discharge-positive" &&
    current_polarity != "charge-positive" {
    return Err("current_polarity must be discharge-positive or charge-positive")
  }
  if voltage_channel == current_channel {
    return Err("voltage and current must select distinct channels")
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let voltage_index = match source.channels.search(voltage_channel) {
    Some(value) => value
    None => return Err("missing voltage channel: " + voltage_channel)
  }
  let current_index = match source.channels.search(current_channel) {
    Some(value) => value
    None => return Err("missing current channel: " + current_channel)
  }
  let points : Array[EnergyPoint] = []
  let intervals : Array[EnergyInterval] = []
  let gaps : Array[EnergyGap] = []
  let samples : Array[Sample] = []
  let mut segment = 0
  let mut integrated_duration_ms = 0L
  let mut excluded_duration_ms = 0L
  let mut drawn_wh = 0.0
  let mut recovered_wh = 0.0
  for i, sample in source.samples {
    let voltage = sample.values[voltage_index]
    let current = sample.values[current_index]
    if voltage < 0.0 {
      return Err("voltage must be nonnegative at source sample \{i}")
    }
    let power = voltage *
      current *
      (if current_polarity == "discharge-positive" { 1.0 } else { -1.0 })
    if power.is_inf() || power.is_nan() {
      return Err("power exceeds finite range at source sample \{i}")
    }
    let mut segment_start = i == 0
    if i > 0 {
      let left = points[i - 1]
      // Nonnegative strictly ordered source timestamps make the subtraction safe.
      let duration_ms = sample.timestamp_ms - left.timestamp_ms
      if duration_ms > max_gap_ms {
        segment += 1
        segment_start = true
        excluded_duration_ms += duration_ms
        gaps.push({
          left_sample_index: i - 1,
          right_sample_index: i,
          left_timestamp_ms: left.timestamp_ms,
          right_timestamp_ms: sample.timestamp_ms,
          duration_ms,
        })
      } else {
        integrated_duration_ms += duration_ms
        let hours = duration_ms.to_double() / 3600000.0
        let p0 = left.power_w
        let p1 = power
        let mut interval_drawn = 0.0
        let mut interval_recovered = 0.0
        let mut crossing : Double? = None
        if p0 >= 0.0 && p1 >= 0.0 {
          interval_drawn = (p0 / 2.0 + p1 / 2.0) * hours
        } else if p0 <= 0.0 && p1 <= 0.0 {
          interval_recovered = (-p0 / 2.0 - p1 / 2.0) * hours
        } else {
          let a = p0.abs()
          let b = p1.abs()
          // Avoid overflowing a+b or subtracting opposite, very large powers.
          let (fraction, remainder) = if a >= b {
            let ratio = b / a
            (1.0 / (1.0 + ratio), ratio / (1.0 + ratio))
          } else {
            let ratio = a / b
            (ratio / (1.0 + ratio), 1.0 / (1.0 + ratio))
          }
          crossing = Some(fraction)
          let first = a / 2.0 * (hours * fraction)
          let second = b / 2.0 * (hours * remainder)
          if p0 > 0.0 {
            interval_drawn = first
            interval_recovered = second
          } else {
            interval_recovered = first
            interval_drawn = second
          }
        }
        drawn_wh += interval_drawn
        recovered_wh += interval_recovered
        if drawn_wh.is_inf() ||
          drawn_wh.is_nan() ||
          recovered_wh.is_inf() ||
          recovered_wh.is_nan() {
          return Err("energy exceeds finite range at source sample \{i}")
        }
        intervals.push({
          left_sample_index: i - 1,
          right_sample_index: i,
          left_timestamp_ms: left.timestamp_ms,
          right_timestamp_ms: sample.timestamp_ms,
          duration_ms,
          segment,
          zero_crossing_fraction: crossing,
          drawn_wh: interval_drawn,
          recovered_wh: interval_recovered,
          net_wh: interval_drawn - interval_recovered,
        })
      }
    }
    points.push({
      source_sample_index: i,
      timestamp_ms: sample.timestamp_ms,
      segment,
      segment_start,
      voltage_v: voltage,
      current_a: current,
      power_w: power,
    })
    samples.push({
      timestamp_ms: sample.timestamp_ms,
      values: [power, drawn_wh, recovered_wh, drawn_wh - recovered_wh],
    })
  }
  Ok({
    format: "moonrobo.telemetry-energy.v1",
    timebase: "milliseconds-as-recorded; energy-unit=Wh",
    method: "piecewise-linear-sample-power; zero-split-trapezoids; gaps-excluded",
    voltage_channel,
    current_channel,
    voltage_unit: "V",
    current_unit: "A",
    current_polarity,
    max_gap_ms,
    source_sample_count: source.samples.length(),
    segment_count: segment + 1,
    supported_interval_count: intervals.length(),
    integrated_duration_ms,
    excluded_duration_ms,
    drawn_wh,
    recovered_wh,
    net_wh: drawn_wh - recovered_wh,
    points,
    intervals,
    gaps,
    recording: {
      channels: [
        "power.w", "observed.drawn.wh", "observed.recovered.wh", "observed.net.wh",
      ],
      samples,
    },
  })
}

///|
/// Numeric sample power and cumulative energy over supported intervals only.
/// A constant cumulative value across a gap means excluded duration, not zero
/// consumption. Keep the JSON report and the same gap cutoff when plotting.
pub fn TelemetryEnergy::to_csv(
  self : TelemetryEnergy,
) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
