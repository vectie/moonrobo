///|
struct MutableJointState {
  name : String
  joint_type : String
  parent_link : String
  child_link : String
  origin : UrdfOriginNode?
  axis : String
  limit : UrdfLimitNode?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
} derive(Debug, Eq)

///|
struct MutableVisualState {
  link_name : String
  index : Int
  geometry_kind : String
  mesh_filename : String
  mesh_scale : String
  size : String
  radius : Double?
  length : Double?
  origin : UrdfOriginNode?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
} derive(Debug, Eq)

///|
fn origin_node(node_id : String, tag : XmlTag) -> UrdfOriginNode {
  {
    node_id,
    xyz: attr_or(tag.raw, "xyz", "0 0 0"),
    rpy: attr_or(tag.raw, "rpy", "0 0 0"),
    source_span: tag.span,
  }
}

///|
fn limit_node(node_id : String, tag : XmlTag) -> UrdfLimitNode {
  {
    node_id,
    lower: parse_double_attr(tag.raw, "lower"),
    upper: parse_double_attr(tag.raw, "upper"),
    effort: parse_double_attr(tag.raw, "effort"),
    velocity: parse_double_attr(tag.raw, "velocity"),
    source_span: tag.span,
  }
}

///|
fn close_link(
  links : Array[UrdfLinkNode],
  current_link : UrdfLinkNode?,
  close_span : UrdfSourceSpan?,
) -> UrdfLinkNode? {
  match current_link {
    None => None
    Some(link) => {
      let closed = {
        ..link,
        source_span: match close_span {
          Some(value) => span(link.source_span.start, value.end)
          None => link.source_span
        },
        close_tag_span: close_span,
      }
      links.push(closed)
      None
    }
  }
}

///|
fn close_joint(
  joints : Array[UrdfJointNode],
  current : MutableJointState?,
  close_span : UrdfSourceSpan?,
) -> MutableJointState? {
  match current {
    None => None
    Some(joint) => {
      let source_span = match close_span {
        Some(value) => span(joint.source_span.start, value.end)
        None => joint.source_span
      }
      joints.push({
        node_id: "joint:\{joint.name}",
        name: joint.name,
        joint_type: joint.joint_type,
        parent_link: joint.parent_link,
        child_link: joint.child_link,
        origin: joint.origin,
        axis: joint.axis,
        limit: joint.limit,
        source_span,
        open_tag_span: joint.open_tag_span,
        close_tag_span: close_span,
      })
      None
    }
  }
}

///|
fn close_visual(
  visuals : Array[UrdfVisualNode],
  current : MutableVisualState?,
  close_span : UrdfSourceSpan?,
) -> MutableVisualState? {
  match current {
    None => None
    Some(visual) => {
      let source_span = match close_span {
        Some(value) => span(visual.source_span.start, value.end)
        None => visual.source_span
      }
      visuals.push({
        node_id: "visual:\{visual.link_name}:\{visual.index}",
        link_name: visual.link_name,
        index: visual.index,
        geometry_kind: visual.geometry_kind,
        mesh_filename: visual.mesh_filename,
        mesh_scale: visual.mesh_scale,
        size: visual.size,
        radius: visual.radius,
        length: visual.length,
        origin: visual.origin,
        source_span,
        open_tag_span: visual.open_tag_span,
        close_tag_span: close_span,
      })
      None
    }
  }
}

///|
fn has_name(items : Array[String], name : String) -> Bool {
  items.contains(name)
}

///|
fn duplicate_issues(
  kind : String,
  names : Array[String],
) -> Array[UrdfEditorIssue] {
  let seen : Array[String] = []
  let duplicates : Array[String] = []
  let issues : Array[UrdfEditorIssue] = []
  for name in names {
    if seen.contains(name) && !duplicates.contains(name) {
      duplicates.push(name)
      issues.push(
        issue(
          "duplicate-\{kind}",
          Error,
          "\{kind}:\{name}",
          "duplicate URDF \{kind} name `\{name}`",
        ),
      )
    } else {
      seen.push(name)
    }
  }
  issues
}

///|
fn validate_document(
  robot_name : String,
  links : Array[UrdfLinkNode],
  joints : Array[UrdfJointNode],
  visuals : Array[UrdfVisualNode],
  parse_issues : Array[UrdfEditorIssue],
) -> Array[UrdfEditorIssue] {
  let issues : Array[UrdfEditorIssue] = []
  for item in parse_issues {
    issues.push(item)
  }
  if robot_name == "" {
    issues.push(
      issue("robot-name-missing", Error, "robot", "robot tag missing name"),
    )
  }
  let link_names = links.map(fn(link) { link.name })
  let joint_names = joints.map(fn(joint) { joint.name })
  for item in duplicate_issues("link", link_names) {
    issues.push(item)
  }
  for item in duplicate_issues("joint", joint_names) {
    issues.push(item)
  }
  for joint in joints {
    if joint.parent_link == "" {
      issues.push(
        issue(
          "joint-parent-missing",
          Error,
          joint.node_id,
          "joint `\{joint.name}` missing parent link",
        ),
      )
    } else if !has_name(link_names, joint.parent_link) {
      issues.push(
        issue(
          "joint-parent-unknown",
          Error,
          joint.node_id,
          "joint `\{joint.name}` parent link `\{joint.parent_link}` is not declared",
        ),
      )
    }
    if joint.child_link == "" {
      issues.push(
        issue(
          "joint-child-missing",
          Error,
          joint.node_id,
          "joint `\{joint.name}` missing child link",
        ),
      )
    } else if !has_name(link_names, joint.child_link) {
      issues.push(
        issue(
          "joint-child-unknown",
          Error,
          joint.node_id,
          "joint `\{joint.name}` child link `\{joint.child_link}` is not declared",
        ),
      )
    }
    match joint.limit {
      Some(limit) =>
        match (limit.lower, limit.upper) {
          (Some(lower), Some(upper)) =>
            if lower > upper {
              issues.push(
                issue(
                  "joint-limit-order",
                  Error,
                  joint.node_id,
                  "joint `\{joint.name}` lower limit is greater than upper limit",
                ),
              )
            }
          _ => ()
        }
      None => ()
    }
  }
  if links.length() > 0 {
    let child_links = joints.map(fn(joint) { joint.child_link })
    let root_count = links
      .filter(fn(link) { !child_links.contains(link.name) })
      .length()
    if root_count == 0 {
      issues.push(
        issue("root-link-missing", Error, "robot", "URDF has no root link"),
      )
    } else if root_count > 1 {
      issues.push(
        issue(
          "root-link-multiple",
          Warning,
          "robot",
          "URDF has \{root_count} root links; topology may be disconnected",
        ),
      )
    }
  }
  for visual in visuals {
    if visual.geometry_kind == "" {
      issues.push(
        issue(
          "visual-geometry-missing",
          Error,
          visual.node_id,
          "visual `\{visual.node_id}` has no geometry",
        ),
      )
    }
  }
  issues
}

///|
pub fn parse_document(source : String) -> UrdfDocument {
  let links : Array[UrdfLinkNode] = []
  let joints : Array[UrdfJointNode] = []
  let visuals : Array[UrdfVisualNode] = []
  let parse_issues : Array[UrdfEditorIssue] = []
  let mut robot_name = ""
  let mut current_link : UrdfLinkNode? = None
  let mut current_joint : MutableJointState? = None
  let mut current_visual : MutableVisualState? = None
  let mut visual_index = 0
  for tag in scan_tags(source) {
    if is_open_tag(tag, "robot") {
      robot_name = attr_or(tag.raw, "name", "")
    } else if is_open_tag(tag, "link") {
      let name = attr_or(tag.raw, "name", "")
      if name == "" {
        parse_issues.push(
          issue("link-name-missing", Error, "link", "link tag missing name"),
        )
      }
      let link = {
        node_id: "link:\{name}",
        name,
        source_span: tag.span,
        open_tag_span: tag.span,
        close_tag_span: None,
      }
      if tag.self_closing {
        links.push(link)
      } else {
        current_link = Some(link)
      }
    } else if is_close_tag(tag, "link") {
      current_link = close_link(links, current_link, Some(tag.span))
    } else if is_open_tag(tag, "joint") {
      let name = attr_or(tag.raw, "name", "")
      let joint_type = attr_or(tag.raw, "type", "")
      if name == "" {
        parse_issues.push(
          issue("joint-name-missing", Error, "joint", "joint tag missing name"),
        )
      }
      current_joint = Some({
        name,
        joint_type,
        parent_link: "",
        child_link: "",
        origin: None,
        axis: "",
        limit: None,
        source_span: tag.span,
        open_tag_span: tag.span,
      })
    } else if is_close_tag(tag, "joint") {
      current_joint = close_joint(joints, current_joint, Some(tag.span))
    } else if is_open_tag(tag, "parent") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({
            ..joint,
            parent_link: attr_or(tag.raw, "link", ""),
          })
        None => ()
      }
    } else if is_open_tag(tag, "child") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({
            ..joint,
            child_link: attr_or(tag.raw, "link", ""),
          })
        None => ()
      }
    } else if is_open_tag(tag, "origin") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            origin: Some(
              origin_node(
                "origin:\{visual.link_name}:visual:\{visual.index}",
                tag,
              ),
            ),
          })
        None =>
          match current_joint {
            Some(joint) =>
              current_joint = Some({
                ..joint,
                origin: Some(origin_node("origin:joint:\{joint.name}", tag)),
              })
            None => ()
          }
      }
    } else if is_open_tag(tag, "axis") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({ ..joint, axis: attr_or(tag.raw, "xyz", "") })
        None => ()
      }
    } else if is_open_tag(tag, "limit") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({
            ..joint,
            limit: Some(limit_node("limit:joint:\{joint.name}", tag)),
          })
        None => ()
      }
    } else if is_open_tag(tag, "visual") {
      match current_link {
        Some(link) => {
          current_visual = Some({
            link_name: link.name,
            index: visual_index,
            geometry_kind: "",
            mesh_filename: "",
            mesh_scale: "",
            size: "",
            radius: None,
            length: None,
            origin: None,
            source_span: tag.span,
            open_tag_span: tag.span,
          })
          visual_index += 1
        }
        None =>
          parse_issues.push(
            issue(
              "visual-outside-link",
              Error,
              "visual",
              "visual tag outside link",
            ),
          )
      }
    } else if is_close_tag(tag, "visual") {
      current_visual = close_visual(visuals, current_visual, Some(tag.span))
    } else if is_open_tag(tag, "mesh") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "mesh",
            mesh_filename: attr_or(tag.raw, "filename", ""),
            mesh_scale: attr_or(tag.raw, "scale", ""),
          })
        None => ()
      }
    } else if is_open_tag(tag, "box") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "box",
            size: attr_or(tag.raw, "size", ""),
          })
        None => ()
      }
    } else if is_open_tag(tag, "sphere") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "sphere",
            radius: parse_double_attr(tag.raw, "radius"),
          })
        None => ()
      }
    } else if is_open_tag(tag, "cylinder") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "cylinder",
            radius: parse_double_attr(tag.raw, "radius"),
            length: parse_double_attr(tag.raw, "length"),
          })
        None => ()
      }
    }
  }
  current_link = close_link(links, current_link, None)
  current_joint = close_joint(joints, current_joint, None)
  current_visual = close_visual(visuals, current_visual, None)
  ignore(current_link)
  ignore(current_joint)
  ignore(current_visual)
  {
    source,
    robot_name,
    links,
    joints,
    visuals,
    issues: validate_document(robot_name, links, joints, visuals, parse_issues),
  }
}

///|
pub fn find_joint(doc : UrdfDocument, name : String) -> UrdfJointNode? {
  for joint in doc.joints {
    if joint.name == name {
      return Some(joint)
    }
  }
  None
}

///|
pub fn find_visual(
  doc : UrdfDocument,
  link_name : String,
  index : Int,
) -> UrdfVisualNode? {
  for visual in doc.visuals {
    if visual.link_name == link_name && visual.index == index {
      return Some(visual)
    }
  }
  None
}
