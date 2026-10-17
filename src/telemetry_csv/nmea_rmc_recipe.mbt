///|
/// Explicit two-digit year interpretation, selected channels and exclusion policy.
/// Geographic degrees are never Cartesian distances. Speed remains in knots.
pub(all) struct NmeaRmcRecipe {
  year_century : Int
  channels : Array[String]
  row_policy : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn nmea_rmc_channel_name(channel : String) -> String {
  match channel {
    "latitude" => "gnss.latitude.deg"
    "longitude" => "gnss.longitude.deg"
    "speed" => "gnss.speed.knots"
    "course" => "gnss.course.true_deg"
    _ => ""
  }
}

///|
fn validate_nmea_rmc_recipe(recipe : NmeaRmcRecipe) -> Result[Unit, String] {
  if recipe.year_century != 1900 && recipe.year_century != 2000 {
    return Err("year_century must explicitly be 1900 or 2000")
  }
  if recipe.row_policy != "eligible-only" {
    return Err(
      "row_policy must explicitly be eligible-only; exclusions remain in JSON",
    )
  }
  if recipe.channels.is_empty() {
    return Err(
      "channels must select at least one of latitude, longitude, speed, course",
    )
  }
  let seen : Array[String] = []
  for channel in recipe.channels {
    if nmea_rmc_channel_name(channel) == "" || seen.contains(channel) {
      return Err("unknown or duplicate channel: " + channel)
    }
    seen.push(channel)
  }
  Ok(())
}

///|
/// Extract a root object's raw numeric token after full JSON syntax/type and
/// duplicate-key validation. Decode key escapes; skip strings and nested data.
/// The JSON library's binary64 value does not retain all decimal spellings.
fn rmc_century_token(text : String) -> String? {
  let mut depth = 0
  let mut index = 0
  while index < text.length() {
    match text[index] {
      '{' | '[' => {
        depth += 1
        index += 1
      }
      '}' | ']' => {
        depth -= 1
        index += 1
      }
      '"' => {
        let start = index
        index += 1
        while index < text.length() {
          if text[index] == '\\' {
            index += 2
          } else if text[index] == '"' {
            index += 1
            break
          } else {
            index += 1
          }
        }
        if depth != 1 {
          continue
        }
        let mut next = index
        while next < text.length() &&
              (
                text[next] == ' ' ||
                text[next] == '\t' ||
                text[next] == '\r' ||
                text[next] == '\n'
              ) {
          next += 1
        }
        if next >= text.length() || text[next] != ':' {
          continue
        }
        let key = @json.parse(text[start:index]) catch { _ => return None }
        if key != "year_century".to_json() {
          continue
        }
        next += 1
        while next < text.length() &&
              (
                text[next] == ' ' ||
                text[next] == '\t' ||
                text[next] == '\r' ||
                text[next] == '\n'
              ) {
          next += 1
        }
        let start = next
        while next < text.length() &&
              (
                text[next] == '-' ||
                text[next] == '+' ||
                text[next] == '.' ||
                text[next] == 'e' ||
                text[next] == 'E' ||
                (text[next] >= '0' && text[next] <= '9')
              ) {
          next += 1
        }
        return Some(text[start:next].to_owned())
      }
      _ => index += 1
    }
  }
  None
}

///|
/// Compare a valid JSON number's exact decimal value to 1900 or 2000 without
/// floating point or unbounded integer parsing. Normalize significant digits,
/// trailing zeros and signed exponent spelling; huge exponents cannot overflow.
fn rmc_exact_century(token : String) -> Int? {
  if token.has_prefix("-") {
    return None
  }
  let parts = token.replace(old="E", new="e").split("e").collect()
  let mantissa = parts[0].split(".").collect()
  let fraction = if mantissa.length() == 2 { mantissa[1].length() } else { 0 }
  let digits = parts[0].to_owned().replace(old=".", new="")
  let mut first = 0
  let mut last = digits.length()
  while first < last && digits[first] == '0' {
    first += 1
  }
  while last > first && digits[last - 1] == '0' {
    last -= 1
  }
  let (century, power) = match digits[first:last] {
    "19" => (1900, 2)
    "2" => (2000, 3)
    _ => return None
  }
  let required_exponent = power.to_int64() +
    fraction.to_int64() -
    (digits.length() - last).to_int64()
  let exponent = if parts.length() == 2 { parts[1] } else { "0"[:] }
  let negative = exponent.has_prefix("-")
  let mut start = if negative || exponent.has_prefix("+") { 1 } else { 0 }
  while start < exponent.length() && exponent[start] == '0' {
    start += 1
  }
  if start == exponent.length() {
    return if required_exponent == 0L { Some(century) } else { None }
  }
  let canonical_exponent = (if negative { "-" } else { "" }) +
    exponent[start:].to_owned()
  if canonical_exponent == required_exponent.to_string() {
    Some(century)
  } else {
    None
  }
}

///|
/// Strict recipe parsing rejects unknown, missing and duplicate fields.
/// Century is validated against exact JSON decimal spelling before Int decoding.
pub fn parse_nmea_rmc_recipe(text : String) -> Result[NmeaRmcRecipe, String] {
  let value = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  let keys = ["year_century", "channels", "row_policy"]
  guard value is Object(fields) && fields.length() == keys.length() else {
    return Err("recipe requires exactly year_century, channels and row_policy")
  }
  for key in fields.keys() {
    if !keys.contains(key) {
      return Err("unknown recipe field: " + key)
    }
  }
  guard fields.get("year_century") is Some(Number(_)) &&
    rmc_century_token(text) is Some(token) &&
    rmc_exact_century(token) is Some(century) else {
    return Err("year_century must be the exact integer 1900 or 2000")
  }
  fields["year_century"] = century.to_json()
  let recipe : NmeaRmcRecipe = @json.from_json(value) catch {
    _ => return Err("invalid NMEA RMC recipe field types")
  }
  match validate_nmea_rmc_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
