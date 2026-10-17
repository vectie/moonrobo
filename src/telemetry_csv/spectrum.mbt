///|
/// One original observation, retaining its zero-based position in the source.
pub(all) struct SpectrumSample {
  source_sample_index : Int
  timestamp_ms : Int64
  value : Double
} derive(Debug, Eq, ToJson)

///|
/// A one-sided peak-amplitude bin, not power, PSD, RMS, or a diagnosis.
pub(all) struct SpectrumBin {
  index : Int
  frequency_hz : Double
  amplitude : Double
  is_nyquist : Bool
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetrySpectrum {
  format : String
  method : String
  window : String
  normalization : String
  channel : String
  unit_label : String
  frequency_unit : String
  demean : Bool
  source_mean : Double
  removed_mean : Double
  source_sample_count : Int
  samples : Array[SpectrumSample]
  requested_start_ms : Int64
  requested_end_ms : Int64
  sample_interval_ms : Int64
  sample_rate_hz : Double
  frequency_resolution_hz : Double
  nyquist_hz : Double
  bins : Array[SpectrumBin]
} derive(Debug, Eq, ToJson)

///|
/// Inspect one numeric recorded channel with a bounded direct DFT. The complete
/// CSV is validated, then an inclusive window selects 2..2048 observations.
/// Every selected adjacent timestamp difference must be the same positive exact
/// Int64 millisecond count. There is no resampling, interpolation, gap bridging,
/// padding, or frequency inference from absolute floating-point timestamps.
/// Rectangular window only: |sum(x[n] exp(-i 2 pi k n/N))| / N, doubled except
/// at DC and the even-N Nyquist bin. Units are supplied explicitly by the caller.
/// Demeaning removes the selected arithmetic mean before the DFT.
///
/// ```mbt check
/// test {
///   guard @telemetry_csv.spectrum_csv(
///       "timestamp_ms,v\n0,0\n250,2\n500,0\n750,-2\n",
///       "v",
///       unit_label="V",
///     )
///     is Ok(result) else {
///     fail("spectrum failed")
///   }
///   assert_true((result.bins[1].amplitude - 2.0).abs() < 1.0e-12)
/// }
/// ```
pub fn spectrum_csv(
  text : String,
  channel : String,
  unit_label~ : String,
  demean? : Bool = false,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
) -> Result[TelemetrySpectrum, String] {
  if start_ms < 0L || end_ms < start_ms {
    return Err("expected 0 <= start_ms <= end_ms")
  }
  if text.length() > 4194304 {
    return Err("spectrum input exceeds 4 Mi UTF-16 units")
  }
  if !plot_label_valid(unit_label) ||
    unit_label.length() > 256 ||
    !plot_label_valid(channel) ||
    channel.length() > 256 {
    return Err(
      "channel and explicit unit label require 1..256 XML-compatible units",
    )
  }
  let recording = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if recording.samples.length() > 100000 {
    return Err("source exceeds 100000 samples; split the recording")
  }
  let column = match recording.channels.search(channel) {
    Some(value) => value
    None => return Err("missing channel: " + channel)
  }
  let samples : Array[SpectrumSample] = []
  for source_sample_index, sample in recording.samples {
    if sample.timestamp_ms >= start_ms && sample.timestamp_ms <= end_ms {
      samples.push({
        source_sample_index,
        timestamp_ms: sample.timestamp_ms,
        value: sample.values[column],
      })
    }
  }
  let count = samples.length()
  if count < 2 || count > 2048 {
    return Err("spectrum requires 2..2048 observations in the selected window")
  }
  // Source parser has already established nonnegative, strictly ordered times.
  // Subtract Int64 values BEFORE conversion, even near the Int64 maximum.
  let sample_interval_ms = samples[1].timestamp_ms - samples[0].timestamp_ms
  for i in 1..<count {
    if samples[i].timestamp_ms - samples[i - 1].timestamp_ms !=
      sample_interval_ms {
      return Err(
        "selected window has irregular spacing or a gap; select an uninterrupted uniformly sampled window",
      )
    }
  }
  let n = count.to_double()
  let mut scale = 0.0
  for sample in samples {
    scale = scale.max(sample.value.abs())
  }
  let normalized = samples.map(sample => {
    if scale == 0.0 {
      0.0
    } else {
      sample.value / scale
    }
  })
  let mut mean = 0.0
  let mut correction = 0.0
  for value in normalized {
    let term = value / n - correction
    let next = mean + term
    correction = next - mean - term
    mean = next
  }
  mean = mean.max(-1.0).min(1.0)
  let source_mean = mean * scale
  let removed_mean = if demean { source_mean } else { 0.0 }
  let sample_rate_hz = 1000.0 / sample_interval_ms.to_double()
  let frequency_resolution_hz = sample_rate_hz / n
  let bins : Array[SpectrumBin] = []
  for k in 0..<=(count / 2) {
    let mut real = 0.0
    let mut imaginary = 0.0
    let mut real_correction = 0.0
    let mut imaginary_correction = 0.0
    for index, value in normalized {
      let centered = value - (if demean { mean } else { 0.0 })
      let phase = 2.0 * @math.PI * k.to_double() * index.to_double() / n
      let rt = centered / n * @math.cos(phase) - real_correction
      let it = -centered / n * @math.sin(phase) - imaginary_correction
      let nr = real + rt
      let ni = imaginary + it
      real_correction = nr - real - rt
      imaginary_correction = ni - imaginary - it
      real = nr
      imaginary = ni
    }
    let is_nyquist = count % 2 == 0 && k == count / 2
    let multiplier = if k == 0 || is_nyquist { 1.0 } else { 2.0 }
    let amplitude = (real * real + imaginary * imaginary).sqrt() *
      multiplier *
      scale
    if amplitude.is_nan() || amplitude.is_inf() {
      return Err(
        "spectrum amplitude exceeds finite range; scale the source explicitly",
      )
    }
    bins.push({
      index: k,
      frequency_hz: k.to_double() * frequency_resolution_hz,
      amplitude,
      is_nyquist,
    })
  }
  Ok({
    format: "moonrobo.telemetry-spectrum.v1",
    method: "direct-DFT-one-sided-peak-amplitude",
    window: "rectangular",
    normalization: "abs(DFT)/N; double interior bins; DC and even-N Nyquist undoubled",
    channel,
    unit_label,
    frequency_unit: "Hz",
    demean,
    source_mean,
    removed_mean,
    source_sample_count: recording.samples.length(),
    samples,
    requested_start_ms: start_ms,
    requested_end_ms: end_ms,
    sample_interval_ms,
    sample_rate_hz,
    frequency_resolution_hz,
    nyquist_hz: sample_rate_hz / 2.0,
    bins,
  })
}
