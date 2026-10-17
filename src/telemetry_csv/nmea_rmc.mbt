///|
/// One checksum-verified sentence, including excluded fixes and missing values.
pub(all) struct NmeaRmcSource {
  source_line_number : Int
  sentence : String
  talker : String
  status : String
  position_mode : String?
  timestamp_ms : Int64?
  latitude_deg : Double?
  longitude_deg : Double?
  speed_knots : Double?
  course_true_deg : Double?
  magnetic_variation_east_deg : Double?
  exclusion_reasons : Array[String]
} derive(Debug, Eq, ToJson)

///|
/// Recorded GNSS channels for offline inspection, without accuracy or control claims.
pub(all) struct NmeaRmcImport {
  format : String
  timebase : String
  coordinate_convention : String
  raw_source : String
  recipe : NmeaRmcRecipe
  sources : Array[NmeaRmcSource]
  exported_source_line_numbers : Array[Int]
  excluded_sentence_count : Int
  recording : Recording
} derive(Debug, Eq, ToJson)

///|
fn rmc_source(
  sentence : String,
  line : Int,
  recipe : NmeaRmcRecipe,
) -> NmeaRmcSource raise NmeaRmcError {
  let f = rmc_fields(sentence)
  let day = rmc_day(f[9], recipe.year_century)
  let time = rmc_time(f[1])
  let timestamp_ms = match (day, time) {
    (Some(day), Some(time)) =>
      Some(day.to_int64() * 86400000L + time.to_int64())
    _ => None
  }
  let status = f[2]
  if !["", "A", "V"].contains(status) {
    raise NmeaRmcError("status must be A, V or empty")
  }
  let position_mode = if f.length() == 13 { Some(f[12]) } else { None }
  if position_mode is Some(mode) &&
    !["", "A", "D", "E", "F", "M", "N", "P", "R", "S"].contains(mode) {
    raise NmeaRmcError("unsupported position mode")
  }
  let latitude_deg = rmc_coordinate(f[3], f[4], true)
  let longitude_deg = rmc_coordinate(f[5], f[6], false)
  let speed_knots = rmc_optional_decimal(f[7])
  let course_true_deg = rmc_optional_decimal(f[8])
  if course_true_deg is Some(course) && course >= 360.0 {
    raise NmeaRmcError("course must be in [0,360) true degrees")
  }
  let magnetic_variation_east_deg = if f[10] == "" && f[11] == "" {
    None
  } else {
    if f[11] != "E" && f[11] != "W" {
      raise NmeaRmcError("magnetic variation requires E or W")
    }
    let variation = rmc_decimal(f[10])
    if variation > 180.0 {
      raise NmeaRmcError("magnetic variation exceeds 180 degrees")
    }
    Some(if f[11] == "W" { -variation } else { variation })
  }
  let exclusion_reasons : Array[String] = []
  if status == "V" {
    exclusion_reasons.push("void-status")
  }
  if status == "" {
    exclusion_reasons.push("missing-status")
  }
  if position_mode is Some(mode) && !["A", "D", "F", "R"].contains(mode) {
    exclusion_reasons.push(
      if mode == "" {
        "missing-position-mode"
      } else {
        "ineligible-position-mode:" + mode
      },
    )
  }
  if day is None {
    exclusion_reasons.push("missing-date")
  }
  if time is None {
    exclusion_reasons.push("missing-time")
  }
  let available : Map[String, Double?] = {
    "latitude": latitude_deg,
    "longitude": longitude_deg,
    "speed": speed_knots,
    "course": course_true_deg,
  }
  for channel in recipe.channels {
    if available[channel] is None {
      exclusion_reasons.push("missing-selected-channel:" + channel)
    }
  }
  {
    source_line_number: line,
    sentence,
    talker: f[0][:2].to_owned(),
    status,
    position_mode,
    timestamp_ms,
    latitude_deg,
    longitude_deg,
    speed_knots,
    course_true_deg,
    magnetic_variation_east_deg,
    exclusion_reasons,
  }
}

///|
/// Import only checksummed GP/GN RMC lines. Every sentence remains in the report.
/// Active rows with available selected channels produce a strictly ordered CSV.
///
/// ```mbt check
/// test {
///   let recipe : @telemetry_csv.NmeaRmcRecipe = {
///     year_century: 1900,
///     channels: ["speed"],
///     row_policy: "eligible-only",
///   }
///   let result = @telemetry_csv.import_nmea_rmc(
///     "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A", recipe,
///   ).unwrap()
///   assert_eq(result.recording.samples[0].timestamp_ms, 764426119000L)
///   assert_eq(result.recording.samples[0].values, [22.4])
/// }
/// ```
pub fn import_nmea_rmc(
  text : String,
  recipe : NmeaRmcRecipe,
) -> Result[NmeaRmcImport, String] {
  match validate_nmea_rmc_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  if text.length() > 4194304 {
    return Err("NMEA recording exceeds 4 MiB text limit")
  }
  let samples : Array[Sample] = []
  let sources : Array[NmeaRmcSource] = []
  let exported_source_line_numbers : Array[Int] = []
  let mut line_number = 0
  for line in text.split("\n") {
    line_number += 1
    let sentence = if line.has_suffix("\r") {
      line[:line.length() - 1].to_owned()
    } else {
      line.to_owned()
    }
    if sentence == "" {
      continue
    }
    let source = rmc_source(sentence, line_number, recipe) catch {
      NmeaRmcError(message) => return Err("line \{line_number}: " + message)
    }
    if source.exclusion_reasons.is_empty() {
      guard source.timestamp_ms is Some(timestamp_ms) else {
        return Err("internal missing eligible timestamp")
      }
      if samples.last() is Some(previous) &&
        timestamp_ms <= previous.timestamp_ms {
        return Err(
          "line \{line_number}: exported timestamps must strictly increase; no sorting or merging",
        )
      }
      let available : Map[String, Double?] = {
        "latitude": source.latitude_deg,
        "longitude": source.longitude_deg,
        "speed": source.speed_knots,
        "course": source.course_true_deg,
      }
      let values : Array[Double] = []
      for channel in recipe.channels {
        guard available[channel] is Some(value) else {
          return Err("internal missing eligible channel")
        }
        values.push(value)
      }
      samples.push({ timestamp_ms, values, })
      exported_source_line_numbers.push(line_number)
    }
    sources.push(source)
  }
  if sources.is_empty() {
    return Err("requires at least one nonempty RMC sentence")
  }
  Ok({
    format: "moonrobo.nmea-rmc-import.v1",
    timebase: "UTC-unix-milliseconds-as-recorded-explicit-century-no-leap-seconds",
    coordinate_convention: "geographic-degrees-north-east-positive-datum-not-inferred-not-Cartesian",
    raw_source: text,
    recipe,
    excluded_sentence_count: sources.length() - samples.length(),
    sources,
    exported_source_line_numbers,
    recording: {
      channels: recipe.channels.map(nmea_rmc_channel_name),
      samples,
    },
  })
}

///|
/// Export eligible rows only. Keep the report to retain exclusions and lineage.
/// An all-excluded report is inspectable but cannot produce a numeric CSV.
pub fn NmeaRmcImport::to_csv(self : NmeaRmcImport) -> Result[String, String] {
  telemetry_recording_csv(self.recording)
}
