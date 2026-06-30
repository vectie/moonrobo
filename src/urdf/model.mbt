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
pub(all) struct UrdfVisual {
  link_name : String
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : UrdfOrigin
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfCollision {
  link_name : String
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : UrdfOrigin
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfInertial {
  link_name : String
  origin : UrdfOrigin
  mass : Double?
  ixx : Double?
  ixy : Double?
  ixz : Double?
  iyy : Double?
  iyz : Double?
  izz : Double?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfModel {
  robot_name : String
  link_count : Int
  joint_count : Int
  visual_count : Int
  collision_count : Int
  inertial_count : Int
  links : Array[String]
  joints : Array[UrdfJoint]
  visuals : Array[UrdfVisual]
  collisions : Array[UrdfCollision]
  inertials : Array[UrdfInertial]
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
  let clean = tag
    .trim()
    .to_owned()
    .replace(old="\n", new=" ")
    .replace(old="\r", new=" ")
    .replace(old="\t", new=" ")
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
fn make_visual(
  link_name : String,
  geometry_kind : String,
  mesh_filename : String,
  mesh_scale : String,
  size : String,
  radius : Double?,
  length : Double?,
  origin : UrdfOrigin,
) -> UrdfVisual {
  {
    link_name,
    geometry_kind,
    mesh_filename,
    mesh_scale,
    size,
    radius,
    length,
    origin,
  }
}

///|
fn make_collision(
  link_name : String,
  geometry_kind : String,
  mesh_filename : String,
  mesh_scale : String,
  size : String,
  radius : Double?,
  length : Double?,
  origin : UrdfOrigin,
) -> UrdfCollision {
  {
    link_name,
    geometry_kind,
    mesh_filename,
    mesh_scale,
    size,
    radius,
    length,
    origin,
  }
}

///|
fn make_inertial(
  link_name : String,
  origin : UrdfOrigin,
  mass : Double?,
  ixx : Double?,
  ixy : Double?,
  ixz : Double?,
  iyy : Double?,
  iyz : Double?,
  izz : Double?,
) -> UrdfInertial {
  { link_name, origin, mass, ixx, ixy, ixz, iyy, iyz, izz }
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
  let visuals : Array[UrdfVisual] = []
  let collisions : Array[UrdfCollision] = []
  let inertials : Array[UrdfInertial] = []
  let issues : Array[String] = []
  let mut robot_name = ""
  let mut in_link = false
  let mut current_link = ""
  let mut in_joint = false
  let mut current_name = ""
  let mut current_type = ""
  let mut current_parent = ""
  let mut current_child = ""
  let mut current_origin = default_origin()
  let mut current_axis = ""
  let mut current_limit : UrdfLimit? = None
  let mut in_visual = false
  let mut current_visual_origin = default_origin()
  let mut current_geometry_kind = ""
  let mut current_mesh_filename = ""
  let mut current_mesh_scale = ""
  let mut current_size = ""
  let mut current_radius : Double? = None
  let mut current_length : Double? = None
  let mut in_collision = false
  let mut current_collision_origin = default_origin()
  let mut current_collision_geometry_kind = ""
  let mut current_collision_mesh_filename = ""
  let mut current_collision_mesh_scale = ""
  let mut current_collision_size = ""
  let mut current_collision_radius : Double? = None
  let mut current_collision_length : Double? = None
  let mut in_inertial = false
  let mut current_inertial_origin = default_origin()
  let mut current_mass : Double? = None
  let mut current_ixx : Double? = None
  let mut current_ixy : Double? = None
  let mut current_ixz : Double? = None
  let mut current_iyy : Double? = None
  let mut current_iyz : Double? = None
  let mut current_izz : Double? = None
  for raw_tag in tag_items(text) {
    let name = tag_name(raw_tag)
    if name == "robot" {
      robot_name = attr_or(raw_tag, "name", "")
    } else if name == "link" {
      match attr(raw_tag, "name") {
        Some(link_name) => {
          if !links.contains(link_name) {
            links.push(link_name)
          }
          current_link = link_name
          in_link = !raw_tag.has_suffix("/")
        }
        None => issues.push("link tag missing name")
      }
    } else if name == "/link" && in_link {
      in_link = false
      current_link = ""
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
    } else if name == "visual" && in_link {
      in_visual = true
      current_visual_origin = default_origin()
      current_geometry_kind = ""
      current_mesh_filename = ""
      current_mesh_scale = ""
      current_size = ""
      current_radius = None
      current_length = None
    } else if name == "origin" && in_visual {
      current_visual_origin = origin_from_strings(
        attr_or(raw_tag, "xyz", "0 0 0"),
        attr_or(raw_tag, "rpy", "0 0 0"),
      )
    } else if name == "mesh" && in_visual {
      current_geometry_kind = "mesh"
      current_mesh_filename = attr_or(raw_tag, "filename", "")
      current_mesh_scale = attr_or(raw_tag, "scale", "")
    } else if name == "box" && in_visual {
      current_geometry_kind = "box"
      current_size = attr_or(raw_tag, "size", "")
    } else if name == "sphere" && in_visual {
      current_geometry_kind = "sphere"
      current_radius = parse_double_attr(raw_tag, "radius")
    } else if name == "cylinder" && in_visual {
      current_geometry_kind = "cylinder"
      current_radius = parse_double_attr(raw_tag, "radius")
      current_length = parse_double_attr(raw_tag, "length")
    } else if name == "collision" && in_link {
      in_collision = true
      current_collision_origin = default_origin()
      current_collision_geometry_kind = ""
      current_collision_mesh_filename = ""
      current_collision_mesh_scale = ""
      current_collision_size = ""
      current_collision_radius = None
      current_collision_length = None
    } else if name == "origin" && in_collision {
      current_collision_origin = origin_from_strings(
        attr_or(raw_tag, "xyz", "0 0 0"),
        attr_or(raw_tag, "rpy", "0 0 0"),
      )
    } else if name == "mesh" && in_collision {
      current_collision_geometry_kind = "mesh"
      current_collision_mesh_filename = attr_or(raw_tag, "filename", "")
      current_collision_mesh_scale = attr_or(raw_tag, "scale", "")
    } else if name == "box" && in_collision {
      current_collision_geometry_kind = "box"
      current_collision_size = attr_or(raw_tag, "size", "")
    } else if name == "sphere" && in_collision {
      current_collision_geometry_kind = "sphere"
      current_collision_radius = parse_double_attr(raw_tag, "radius")
    } else if name == "cylinder" && in_collision {
      current_collision_geometry_kind = "cylinder"
      current_collision_radius = parse_double_attr(raw_tag, "radius")
      current_collision_length = parse_double_attr(raw_tag, "length")
    } else if name == "/collision" && in_collision {
      if current_link == "" {
        issues.push("collision tag is outside a named link")
      } else if current_collision_geometry_kind == "" {
        issues.push("link `\{current_link}` collision missing geometry")
      } else {
        collisions.push(
          make_collision(
            current_link, current_collision_geometry_kind, current_collision_mesh_filename,
            current_collision_mesh_scale, current_collision_size, current_collision_radius,
            current_collision_length, current_collision_origin,
          ),
        )
      }
      in_collision = false
    } else if name == "inertial" && in_link {
      in_inertial = true
      current_inertial_origin = default_origin()
      current_mass = None
      current_ixx = None
      current_ixy = None
      current_ixz = None
      current_iyy = None
      current_iyz = None
      current_izz = None
    } else if name == "origin" && in_inertial {
      current_inertial_origin = origin_from_strings(
        attr_or(raw_tag, "xyz", "0 0 0"),
        attr_or(raw_tag, "rpy", "0 0 0"),
      )
    } else if name == "mass" && in_inertial {
      current_mass = parse_double_attr(raw_tag, "value")
    } else if name == "inertia" && in_inertial {
      current_ixx = parse_double_attr(raw_tag, "ixx")
      current_ixy = parse_double_attr(raw_tag, "ixy")
      current_ixz = parse_double_attr(raw_tag, "ixz")
      current_iyy = parse_double_attr(raw_tag, "iyy")
      current_iyz = parse_double_attr(raw_tag, "iyz")
      current_izz = parse_double_attr(raw_tag, "izz")
    } else if name == "/inertial" && in_inertial {
      if current_link == "" {
        issues.push("inertial tag is outside a named link")
      } else {
        inertials.push(
          make_inertial(
            current_link, current_inertial_origin, current_mass, current_ixx, current_ixy,
            current_ixz, current_iyy, current_iyz, current_izz,
          ),
        )
      }
      in_inertial = false
    } else if name == "/visual" && in_visual {
      if current_link == "" {
        issues.push("visual tag is outside a named link")
      } else if current_geometry_kind == "" {
        issues.push("link `\{current_link}` visual missing geometry")
      } else {
        visuals.push(
          make_visual(
            current_link, current_geometry_kind, current_mesh_filename, current_mesh_scale,
            current_size, current_radius, current_length, current_visual_origin,
          ),
        )
      }
      in_visual = false
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
    visual_count: visuals.length(),
    collision_count: collisions.length(),
    inertial_count: inertials.length(),
    links,
    joints,
    visuals,
    collisions,
    inertials,
    issues,
  }
}
