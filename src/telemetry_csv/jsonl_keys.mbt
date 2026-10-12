///|
/// Check already-parsed JSON before its object maps can hide duplicate keys.
/// Strings are decoded by the JSON parser, so escaped spellings compare equal.
/// This scanner is only called after successful full JSON syntax validation.
fn jsonl_unique_object_keys(text : StringView) -> Result[Unit, String] {
  let scopes : Array[Map[String, Bool]] = []
  let mut token = StringBuilder()
  let mut in_string = false
  let mut escaped = false
  let mut last_string : String? = None
  for c in text {
    if in_string {
      token.write_char(c)
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        let decoded = @json.parse(token.to_string()) catch {
          _ => return Err("invalid JSON string")
        }
        guard decoded is String(value) else {
          return Err("invalid JSON string")
        }
        last_string = Some(value)
        in_string = false
      }
      continue
    }
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      continue
    }
    if c == '"' {
      token = StringBuilder()
      token.write_char(c)
      in_string = true
      escaped = false
      last_string = None
      continue
    }
    if c == ':' {
      guard last_string is Some(key) && scopes.last() is Some(scope) else {
        return Err("invalid JSON object key")
      }
      if scope.contains(key) {
        return Err("duplicate object key " + key.to_json().stringify())
      }
      scope[key] = true
    } else if c == '{' {
      scopes.push({})
    } else if c == '}' {
      ignore(scopes.pop())
    }
    last_string = None
  }
  Ok(())
}
