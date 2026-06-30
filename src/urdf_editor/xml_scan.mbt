///|
struct XmlTag {
  raw : String
  name : String
  span : UrdfSourceSpan
  self_closing : Bool
} derive(Debug, Eq)

///|
fn span(start : Int, end : Int) -> UrdfSourceSpan {
  { start, end }
}

///|
fn empty_span(at : Int) -> UrdfSourceSpan {
  { start: at, end: at }
}

///|
fn tag_name(raw : String) -> String {
  let clean = raw
    .trim()
    .to_owned()
    .replace(old="\n", new=" ")
    .replace(old="\r", new=" ")
    .replace(old="\t", new=" ")
  let without_slash = if clean.has_suffix("/") {
    clean[0:clean.length() - 1].trim().to_owned()
  } else {
    clean
  }
  match without_slash.split_once(" ") {
    Some((name, _)) => name.to_owned()
    None => without_slash
  }
}

///|
fn scan_tags(source : String) -> Array[XmlTag] {
  let tags : Array[XmlTag] = []
  let mut cursor = 0
  while cursor < source.length() {
    match source[cursor:].find("<") {
      None => return tags
      Some(relative_lt) => {
        let lt = cursor + relative_lt
        match source[lt + 1:].find(">") {
          None => return tags
          Some(relative_gt) => {
            let gt = lt + 1 + relative_gt
            let raw = source[lt + 1:gt].trim().to_owned()
            if !raw.is_empty() &&
              !raw.has_prefix("?") &&
              (!raw.has_prefix("!") || raw.has_prefix("!--")) {
              tags.push({
                raw,
                name: tag_name(raw),
                span: span(lt, gt + 1),
                self_closing: raw.has_suffix("/"),
              })
            }
            cursor = gt + 1
          }
        }
      }
    }
  }
  tags
}

///|
fn attr(tag : String, name : String) -> String? {
  match tag.split_once("\{name}=\"") {
    Some((_, rest)) =>
      match rest.split_once("\"") {
        Some((value, _)) => Some(value.to_owned())
        None => None
      }
    None =>
      match tag.split_once("\{name}='") {
        Some((_, rest)) =>
          match rest.split_once("'") {
            Some((value, _)) => Some(value.to_owned())
            None => None
          }
        None => None
      }
  }
}

///|
fn attr_or(tag : String, name : String, fallback : String) -> String {
  match attr(tag, name) {
    Some(value) => value
    None => fallback
  }
}

///|
fn attr_value_span(
  source : String,
  tag : XmlTag,
  name : String,
) -> UrdfSourceSpan? {
  let tag_text = source[tag.span.start:tag.span.end]
  let double_pattern = "\{name}=\""
  match tag_text.find(double_pattern) {
    Some(offset) => {
      let start = tag.span.start + offset + double_pattern.length()
      match source[start:tag.span.end].find("\"") {
        Some(end_offset) => return Some(span(start, start + end_offset))
        None => ()
      }
    }
    None => ()
  }
  let single_pattern = "\{name}='"
  match tag_text.find(single_pattern) {
    Some(offset) => {
      let start = tag.span.start + offset + single_pattern.length()
      match source[start:tag.span.end].find("'") {
        Some(end_offset) => Some(span(start, start + end_offset))
        None => None
      }
    }
    None => None
  }
}

///|
fn parse_double_attr(tag : String, name : String) -> Double? {
  match attr(tag, name) {
    Some(value) => Some(@string.parse_double(value) catch { _ => return None })
    None => None
  }
}

///|
fn is_open_tag(tag : XmlTag, name : String) -> Bool {
  tag.name == name && !tag.name.has_prefix("/")
}

///|
fn is_close_tag(tag : XmlTag, name : String) -> Bool {
  tag.name == "/\{name}"
}

///|
fn indentation_before(source : String, at : Int) -> String {
  let mut cursor = at - 1
  while cursor >= 0 {
    let ch = source[cursor:cursor + 1]
    if ch == "\n" || ch == "\r" {
      return source[cursor + 1:at].to_owned()
    }
    cursor -= 1
  }
  ""
}

///|
fn apply_span_patch(
  source : String,
  patch_span : UrdfSourceSpan,
  replacement : String,
) -> String {
  source[0:patch_span.start].to_owned() +
  replacement +
  source[patch_span.end:].to_owned()
}
