///|
pub(all) struct UrdfLimit {
  lower : Double?
  upper : Double?
  effort : Double?
  velocity : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfOrigin {
  xyz : String
  rpy : String
  x : Double
  y : Double
  z : Double
  roll : Double
  pitch : Double
  yaw : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfJoint {
  name : String
  joint_type : String
  parent_link : String
  child_link : String
  origin : UrdfOrigin
  axis : String
  limit : UrdfLimit?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfModel {
  robot_name : String
  link_count : Int
  joint_count : Int
  links : Array[String]
  joints : Array[UrdfJoint]
  issues : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn attr(tag : String, name : String) -> String? {
  match tag.split_once("\{name}=\"") {
    Some((_, rest)) =>
      match rest.split_once("\"") {
        Some((value, _)) => Some(value.to_owned())
        None => None
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
fn attr_or(tag : String, name : String, fallback : String) -> String {
  match attr(tag, name) {
    Some(value) => value
    None => fallback
  }
}

///|
fn parse_vector_part(text : String, index : Int) -> Double {
  let mut current = 0
  for part in text.split(" ") {
    if !part.is_empty() {
      if current == index {
        return @string.parse_double(part) catch { _ => 0.0 }
      }
      current += 1
    }
  }
  0.0
}

///|
fn origin_from_strings(xyz : String, rpy : String) -> UrdfOrigin {
  {
    xyz,
    rpy,
    x: parse_vector_part(xyz, 0),
    y: parse_vector_part(xyz, 1),
    z: parse_vector_part(xyz, 2),
    roll: parse_vector_part(rpy, 0),
    pitch: parse_vector_part(rpy, 1),
    yaw: parse_vector_part(rpy, 2),
  }
}

///|
fn default_origin() -> UrdfOrigin {
  origin_from_strings("0 0 0", "0 0 0")
}

///|
fn tag_name(tag : String) -> String {
  let clean = tag.trim().to_owned()
  match clean.split_once(" ") {
    Some((name, _)) => name.to_owned()
    None =>
      if clean.has_suffix("/") {
        clean[0:clean.length() - 1].to_owned()
      } else {
        clean
      }
  }
}

///|
fn tag_items(text : String) -> Array[String] {
  let items : Array[String] = []
  for piece in text.split("<") {
    match piece.split_once(">") {
      Some((tag, _)) => {
        let clean = tag.trim().to_owned()
        if !clean.is_empty() && !clean.has_prefix("?") && !clean.has_prefix("!") {
          items.push(clean)
        }
      }
      None => ()
    }
  }
  items
}

///|
fn make_joint(
  name : String,
  joint_type : String,
  parent_link : String,
  child_link : String,
  origin : UrdfOrigin,
  axis : String,
  limit : UrdfLimit?,
) -> UrdfJoint {
  { name, joint_type, parent_link, child_link, origin, axis, limit }
}

///|
pub fn find_joint(model : UrdfModel, name : String) -> UrdfJoint? {
  for joint in model.joints {
    if joint.name == name {
      return Some(joint)
    }
  }
  None
}

///|
pub fn has_joint(model : UrdfModel, name : String) -> Bool {
  find_joint(model, name) is Some(_)
}

///|
pub fn has_link(model : UrdfModel, name : String) -> Bool {
  model.links.contains(name)
}

///|
pub fn parse(text : String) -> UrdfModel {
  let links : Array[String] = []
  let joints : Array[UrdfJoint] = []
  let issues : Array[String] = []
  let mut robot_name = ""
  let mut in_joint = false
  let mut current_name = ""
  let mut current_type = ""
  let mut current_parent = ""
  let mut current_child = ""
  let mut current_origin = default_origin()
  let mut current_axis = ""
  let mut current_limit : UrdfLimit? = None
  for raw_tag in tag_items(text) {
    let name = tag_name(raw_tag)
    if name == "robot" {
      robot_name = attr_or(raw_tag, "name", "")
    } else if name == "link" {
      match attr(raw_tag, "name") {
        Some(link_name) =>
          if !links.contains(link_name) {
            links.push(link_name)
          }
        None => issues.push("link tag missing name")
      }
    } else if name == "joint" {
      in_joint = true
      current_name = attr_or(raw_tag, "name", "")
      current_type = attr_or(raw_tag, "type", "")
      current_parent = ""
      current_child = ""
      current_origin = default_origin()
      current_axis = ""
      current_limit = None
      if current_name == "" {
        issues.push("joint tag missing name")
      }
      if current_type == "" {
        issues.push("joint `\{current_name}` missing type")
      }
    } else if name == "parent" && in_joint {
      current_parent = attr_or(raw_tag, "link", "")
    } else if name == "child" && in_joint {
      current_child = attr_or(raw_tag, "link", "")
    } else if name == "origin" && in_joint {
      current_origin = origin_from_strings(
        attr_or(raw_tag, "xyz", "0 0 0"),
        attr_or(raw_tag, "rpy", "0 0 0"),
      )
    } else if name == "axis" && in_joint {
      current_axis = attr_or(raw_tag, "xyz", "")
    } else if name == "limit" && in_joint {
      current_limit = Some({
        lower: parse_double_attr(raw_tag, "lower"),
        upper: parse_double_attr(raw_tag, "upper"),
        effort: parse_double_attr(raw_tag, "effort"),
        velocity: parse_double_attr(raw_tag, "velocity"),
      })
    } else if name == "/joint" && in_joint {
      if current_name != "" {
        if current_parent == "" {
          issues.push("joint `\{current_name}` missing parent link")
        }
        if current_child == "" {
          issues.push("joint `\{current_name}` missing child link")
        }
        joints.push(
          make_joint(
            current_name, current_type, current_parent, current_child, current_origin,
            current_axis, current_limit,
          ),
        )
      }
      in_joint = false
      current_name = ""
      current_type = ""
      current_parent = ""
      current_child = ""
      current_origin = default_origin()
      current_axis = ""
      current_limit = None
    }
  }
  if robot_name == "" {
    issues.push("robot tag missing name")
  }
  if in_joint {
    issues.push("unterminated joint `\{current_name}`")
  }
  {
    robot_name,
    link_count: links.length(),
    joint_count: joints.length(),
    links,
    joints,
    issues,
  }
}
