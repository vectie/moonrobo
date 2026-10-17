///|
priv suberror NmeaRmcError {
  NmeaRmcError(String)
}

///|
fn rmc_digits(text : StringView) -> Int raise NmeaRmcError {
  if text.is_empty() || text.length() > 9 {
    raise NmeaRmcError("expected 1 to 9 decimal digits")
  }
  let mut value = 0
  for ch in text {
    if ch < '0' || ch > '9' {
      raise NmeaRmcError("expected decimal digits")
    }
    value = value * 10 + ch.to_int() - 48
  }
  value
}

///|
fn rmc_decimal(text : String) -> Double raise NmeaRmcError {
  let parts = text.split(".").collect()
  if parts.length() > 2 {
    raise NmeaRmcError("expected unsigned decimal")
  }
  ignore(rmc_digits(parts[0]))
  if parts.length() == 2 {
    ignore(rmc_digits(parts[1]))
  }
  @string.parse_double(text) catch {
    _ => raise NmeaRmcError("invalid decimal")
  }
}

///|
fn rmc_leap(year : Int) -> Bool {
  year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

///|
fn rmc_month_days(year : Int, month : Int) -> Int {
  if month == 2 && rmc_leap(year) {
    29
  } else {
    [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
  }
}

///|
fn rmc_day(text : String, century : Int) -> Int? raise NmeaRmcError {
  if text == "" {
    return None
  }
  if text.length() != 6 {
    raise NmeaRmcError("date must be ddmmyy")
  }
  let day = rmc_digits(text[:2])
  let month = rmc_digits(text[2:4])
  let year = century + rmc_digits(text[4:])
  if year < 1970 || month < 1 || month > 12 || day < 1 {
    raise NmeaRmcError("date must be a valid Gregorian date in 1970..2099")
  }
  if day > rmc_month_days(year, month) {
    raise NmeaRmcError("invalid calendar day")
  }
  let mut days = day - 1
  for y in 1970..<year {
    days += if rmc_leap(y) { 366 } else { 365 }
  }
  for m in 1..<month {
    days += rmc_month_days(year, m)
  }
  Some(days)
}

///|
fn rmc_time(text : String) -> Int? raise NmeaRmcError {
  if text == "" {
    return None
  }
  let parts = text.split(".").collect()
  if parts.length() > 2 || parts[0].length() != 6 {
    raise NmeaRmcError(
      "time must be hhmmss with optional 1..3 millisecond digits",
    )
  }
  let hour = rmc_digits(parts[0][:2])
  let minute = rmc_digits(parts[0][2:4])
  let second = rmc_digits(parts[0][4:])
  if hour > 23 || minute > 59 || second > 59 {
    raise NmeaRmcError("invalid time; leap seconds are unsupported")
  }
  let mut millisecond = 0
  if parts.length() == 2 {
    let fraction = parts[1]
    if fraction.length() < 1 || fraction.length() > 3 {
      raise NmeaRmcError(
        "sub-millisecond precision is unsupported; no truncation",
      )
    }
    millisecond = rmc_digits(fraction)
    for _ in fraction.length()..<3 {
      millisecond *= 10
    }
  }
  Some(((hour * 60 + minute) * 60 + second) * 1000 + millisecond)
}

///|
fn rmc_coordinate(
  text : String,
  hemisphere : String,
  latitude : Bool,
) -> Double? raise NmeaRmcError {
  if text == "" && hemisphere == "" {
    return None
  }
  let degree_digits = if latitude { 2 } else { 3 }
  let maximum = if latitude { 90 } else { 180 }
  let positive = if latitude { "N" } else { "E" }
  let negative = if latitude { "S" } else { "W" }
  if hemisphere != positive && hemisphere != negative {
    raise NmeaRmcError("missing or invalid coordinate hemisphere")
  }
  let parts = text.split(".").collect()
  if parts[0].length() != degree_digits + 2 {
    raise NmeaRmcError("coordinate requires fixed-width degrees and minutes")
  }
  ignore(rmc_decimal(text))
  let degrees = rmc_digits(text[:degree_digits])
  let minutes = rmc_decimal(text[degree_digits:].to_owned())
  if minutes >= 60.0 ||
    degrees > maximum ||
    (degrees == maximum && minutes != 0.0) {
    raise NmeaRmcError("coordinate outside geographic degree/minute bounds")
  }
  let value = degrees.to_double() + minutes / 60.0
  Some(if hemisphere == negative { -value } else { value })
}

///|
fn rmc_optional_decimal(text : String) -> Double? raise NmeaRmcError {
  if text == "" {
    None
  } else {
    Some(rmc_decimal(text))
  }
}

///|
fn rmc_hex(ch : UInt16) -> Int raise NmeaRmcError {
  match ch {
    '0'..='9' => ch.to_int() - 48
    'A'..='F' => ch.to_int() - 55
    _ => raise NmeaRmcError("checksum must be two uppercase hexadecimal digits")
  }
}

///|
fn rmc_fields(sentence : String) -> Array[String] raise NmeaRmcError {
  if sentence.length() > 256 || !sentence.has_prefix("$") {
    raise NmeaRmcError(
      "expected an RMC sentence of at most 256 ASCII characters",
    )
  }
  for ch in sentence {
    if ch < '!' || ch > '~' {
      raise NmeaRmcError("sentence must be printable ASCII without spaces")
    }
  }
  let split = sentence.split("*").collect()
  if split.length() != 2 || split[1].length() != 2 {
    raise NmeaRmcError("one mandatory *HH checksum is required")
  }
  let body = split[0][1:]
  let mut checksum = 0
  for ch in body {
    checksum = checksum.lxor(ch.to_int())
  }
  if checksum != rmc_hex(split[1][0]) * 16 + rmc_hex(split[1][1]) {
    raise NmeaRmcError("checksum mismatch")
  }
  let fields = body.split(",").map(s => s.to_owned()).collect()
  if fields.length() != 12 && fields.length() != 13 {
    raise NmeaRmcError(
      "supported RMC layout has 12 fields, or 13 with position mode",
    )
  }
  if fields[0] != "GPRMC" && fields[0] != "GNRMC" {
    raise NmeaRmcError("only GPRMC and GNRMC sentences are supported")
  }
  fields
}
