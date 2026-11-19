///|
priv struct Element {
  name : String
  attributes : Map[String, String]
  children : Array[Element]
  mut text : String
}

///|
fn element(name : String, attributes : Map[String, String]) -> Element {
  { name, attributes, children: [], text: "", }
}

///|
fn decode_xml(s : String) -> String raise {
  let unmatched = s
    .replace_all(old="&quot;", new="")
    .replace_all(old="&apos;", new="")
    .replace_all(old="&lt;", new="")
    .replace_all(old="&gt;", new="")
    .replace_all(old="&amp;", new="")
  guard !unmatched.contains("&") else {
    fail("unsupported numeric or custom XML entity in robot description")
  }
  s
  .replace_all(old="&quot;", new="\"")
  .replace_all(old="&apos;", new="'")
  .replace_all(old="&lt;", new="<")
  .replace_all(old="&gt;", new=">")
  .replace_all(old="&amp;", new="&")
}

///|
fn escape_xml(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
}

///|
fn whitespace(s : String) -> Bool {
  s == " " || s == "\t" || s == "\n" || s == "\r"
}

///|
fn parse_tag(raw : String) -> (String, Map[String, String]) raise {
  let raw = raw.trim().to_owned()
  let mut cursor = 0
  while cursor < raw.length() && !whitespace(raw[cursor:cursor + 1].to_owned()) {
    cursor += 1
  }
  let name = raw[:cursor].to_owned()
  let attributes : Map[String, String] = Map([])
  while cursor < raw.length() {
    while cursor < raw.length() && whitespace(raw[cursor:cursor + 1].to_owned()) {
      cursor += 1
    }
    if cursor == raw.length() {
      break
    }
    let start = cursor
    while cursor < raw.length() &&
          raw[cursor:cursor + 1] != "=" &&
          !whitespace(raw[cursor:cursor + 1].to_owned()) {
      cursor += 1
    }
    let key = raw[start:cursor].to_owned()
    while cursor < raw.length() && whitespace(raw[cursor:cursor + 1].to_owned()) {
      cursor += 1
    }
    guard !key.is_empty() &&
      cursor < raw.length() &&
      raw[cursor:cursor + 1] == "=" else {
      fail("invalid XML attribute")
    }
    cursor += 1
    while cursor < raw.length() && whitespace(raw[cursor:cursor + 1].to_owned()) {
      cursor += 1
    }
    guard cursor < raw.length() else { fail("unterminated XML attribute") }
    let quote = raw[cursor:cursor + 1].to_owned()
    guard quote == "\"" || quote == "'" else {
      fail("XML attributes must be quoted")
    }
    cursor += 1
    let start = cursor
    while cursor < raw.length() && raw[cursor:cursor + 1] != quote {
      cursor += 1
    }
    guard cursor < raw.length() && !attributes.contains(key) else {
      fail("unterminated or duplicate XML attribute")
    }
    attributes[key] = decode_xml(raw[start:cursor].to_owned())
    cursor += 1
  }
  (name, attributes)
}

///|
fn parse_xml(source : String) -> Element raise {
  let document = element("document", Map([]))
  let stack = [document]
  let mut cursor = 0
  while cursor < source.length() {
    if source[cursor:cursor + 1] != "<" {
      let start = cursor
      while cursor < source.length() && source[cursor:cursor + 1] != "<" {
        cursor += 1
      }
      stack[stack.length() - 1].text += decode_xml(
        source[start:cursor].to_owned(),
      )
      continue
    }
    if source[cursor:].has_prefix("<!--") {
      guard source[cursor + 4:].find("-->") is Some(end) else {
        fail("unterminated XML comment")
      }
      cursor += 4 + end + 3
      continue
    }
    if source[cursor:].has_prefix("<?") {
      guard source[cursor + 2:].find("?>") is Some(end) else {
        fail("unterminated XML declaration")
      }
      cursor += 2 + end + 2
      continue
    }
    guard !source[cursor:].has_prefix("<!") else {
      fail("DOCTYPE and CDATA are unsupported in robot descriptions")
    }
    let start = cursor + 1
    cursor = start
    let mut quote : String? = None
    while cursor < source.length() {
      let ch = source[cursor:cursor + 1].to_owned()
      match quote {
        Some(q) => if ch == q { quote = None }
        None =>
          if ch == "\"" || ch == "'" {
            quote = Some(ch)
          } else if ch == ">" {
            break
          }
      }
      cursor += 1
    }
    guard cursor < source.length() else { fail("unterminated XML element") }
    let tag = source[start:cursor].trim().to_owned()
    cursor += 1
    if tag.has_prefix("/") {
      guard stack.length() > 1 &&
        stack[stack.length() - 1].name == tag[1:].trim().to_owned() else {
        fail("mismatched XML closing tag")
      }
      ignore(stack.pop())
    } else {
      let self_closing = tag.has_suffix("/")
      let (name, attrs) = parse_tag(
        if self_closing {
          tag[:tag.length() - 1].to_owned()
        } else {
          tag
        },
      )
      let node = element(name, attrs)
      stack[stack.length() - 1].children.push(node)
      if !self_closing {
        stack.push(node)
      }
    }
  }
  guard stack.length() == 1 && document.children.length() == 1 else {
    fail("robot XML requires one closed root")
  }
  document.children[0]
}

///|
fn Element::xml(self : Element) -> String {
  let mut out = "<" + self.name
  for key, value in self.attributes {
    out += " " + key + "=\"" + escape_xml(value) + "\""
  }
  if self.children.is_empty() && self.text.is_empty() {
    return out + "/>"
  }
  out += ">" + escape_xml(self.text)
  for child in self.children {
    out += child.xml()
  }
  out + "</" + self.name + ">"
}

///|
fn Element::find(self : Element, tag : String, name? : String) -> Element? {
  let matches = match name {
    None => true
    Some(n) => self.attributes.get("name") == Some(n)
  }
  if self.name == tag && matches {
    return Some(self)
  }
  for child in self.children {
    if child.find(tag, name?) is Some(found) {
      return Some(found)
    }
  }
  None
}

///|
fn Element::child(self : Element, name : String) -> Element {
  for child in self.children {
    if child.name == name {
      return child
    }
  }
  let child = element(name, Map([]))
  self.children.push(child)
  child
}

///|
fn collision_geoms(node : Element, self_collisions : Bool) -> Unit {
  if node.name == "geom" {
    let a = node.attributes
    if a.get("contype").unwrap_or("1") != "0" ||
      a.get("conaffinity").unwrap_or("1") != "0" {
      a["contype"] = "2"
      a["conaffinity"] = if self_collisions { "3" } else { "1" }
      a["friction"] = "1 0.005 0.0001"
    }
  }
  for child in node.children {
    collision_geoms(child, self_collisions)
  }
}
