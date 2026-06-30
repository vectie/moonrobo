///|
struct MutableJointState {
  name : String
  joint_type : String
  parent_link : String
  child_link : String
  origin : UrdfOriginNode?
  axis : String
  axis_node : UrdfAxisNode?
  limit : UrdfLimitNode?
  dynamics : UrdfDynamicsNode?
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
struct MutableCollisionState {
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
struct MutableInertialState {
  link_name : String
  origin : UrdfOriginNode?
  mass : Double?
  ixx : Double?
  ixy : Double?
  ixz : Double?
  iyy : Double?
  iyz : Double?
  izz : Double?
  source_span : UrdfSourceSpan
  open_tag_span : UrdfSourceSpan
} derive(Debug, Eq)

///|
struct MutableMaterialState {
  scope : String
  name : String
  link_name : String
  visual_index : Int?
  color_rgba : String
  texture_filename : String
  color_source_span : UrdfSourceSpan?
  texture_source_span : UrdfSourceSpan?
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
fn axis_node(node_id : String, tag : XmlTag) -> UrdfAxisNode {
  { node_id, xyz: attr_or(tag.raw, "xyz", ""), source_span: tag.span }
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
fn dynamics_node(node_id : String, tag : XmlTag) -> UrdfDynamicsNode {
  {
    node_id,
    damping: parse_double_attr(tag.raw, "damping"),
    friction: parse_double_attr(tag.raw, "friction"),
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
        axis_node: joint.axis_node,
        limit: joint.limit,
        dynamics: joint.dynamics,
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
fn close_collision(
  collisions : Array[UrdfCollisionNode],
  current : MutableCollisionState?,
  close_span : UrdfSourceSpan?,
) -> MutableCollisionState? {
  match current {
    None => None
    Some(collision) => {
      let source_span = match close_span {
        Some(value) => span(collision.source_span.start, value.end)
        None => collision.source_span
      }
      collisions.push({
        node_id: "collision:\{collision.link_name}:\{collision.index}",
        link_name: collision.link_name,
        index: collision.index,
        geometry_kind: collision.geometry_kind,
        mesh_filename: collision.mesh_filename,
        mesh_scale: collision.mesh_scale,
        size: collision.size,
        radius: collision.radius,
        length: collision.length,
        origin: collision.origin,
        source_span,
        open_tag_span: collision.open_tag_span,
        close_tag_span: close_span,
      })
      None
    }
  }
}

///|
fn close_inertial(
  inertials : Array[UrdfInertialNode],
  current : MutableInertialState?,
  close_span : UrdfSourceSpan?,
) -> MutableInertialState? {
  match current {
    None => None
    Some(inertial) => {
      let source_span = match close_span {
        Some(value) => span(inertial.source_span.start, value.end)
        None => inertial.source_span
      }
      inertials.push({
        node_id: "inertial:\{inertial.link_name}",
        link_name: inertial.link_name,
        origin: inertial.origin,
        mass: inertial.mass,
        ixx: inertial.ixx,
        ixy: inertial.ixy,
        ixz: inertial.ixz,
        iyy: inertial.iyy,
        iyz: inertial.iyz,
        izz: inertial.izz,
        source_span,
        open_tag_span: inertial.open_tag_span,
        close_tag_span: close_span,
      })
      None
    }
  }
}

///|
fn material_node_id(material : MutableMaterialState) -> String {
  match material.visual_index {
    Some(index) => "material:\{material.link_name}:visual:\{index}"
    None => "material:robot:\{material.name}"
  }
}

///|
fn close_material(
  materials : Array[UrdfMaterialNode],
  current : MutableMaterialState?,
  close_span : UrdfSourceSpan?,
) -> MutableMaterialState? {
  match current {
    None => None
    Some(material) => {
      let source_span = match close_span {
        Some(value) => span(material.source_span.start, value.end)
        None => material.source_span
      }
      materials.push({
        node_id: material_node_id(material),
        scope: material.scope,
        name: material.name,
        link_name: material.link_name,
        visual_index: material.visual_index,
        color_rgba: material.color_rgba,
        texture_filename: material.texture_filename,
        color_source_span: material.color_source_span,
        texture_source_span: material.texture_source_span,
        source_span,
        open_tag_span: material.open_tag_span,
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
  collisions : Array[UrdfCollisionNode],
  inertials : Array[UrdfInertialNode],
  materials : Array[UrdfMaterialNode],
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
  let global_material_names = materials
    .filter(fn(material) { material.scope == "robot" })
    .map(fn(material) { material.name })
  for item in duplicate_issues("material", global_material_names) {
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
  for collision in collisions {
    if collision.geometry_kind == "" {
      issues.push(
        issue(
          "collision-geometry-missing",
          Error,
          collision.node_id,
          "collision `\{collision.node_id}` has no geometry",
        ),
      )
    }
  }
  for inertial in inertials {
    match inertial.mass {
      Some(value) =>
        if value <= 0.0 {
          issues.push(
            issue(
              "inertial-mass-nonpositive",
              Warning,
              inertial.node_id,
              "inertial mass for link `\{inertial.link_name}` is not positive",
            ),
          )
        }
      None =>
        issues.push(
          issue(
            "inertial-mass-missing",
            Warning,
            inertial.node_id,
            "inertial for link `\{inertial.link_name}` is missing mass",
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
  let collisions : Array[UrdfCollisionNode] = []
  let inertials : Array[UrdfInertialNode] = []
  let materials : Array[UrdfMaterialNode] = []
  let parse_issues : Array[UrdfEditorIssue] = []
  let mut robot_name = ""
  let mut current_link : UrdfLinkNode? = None
  let mut current_joint : MutableJointState? = None
  let mut current_visual : MutableVisualState? = None
  let mut current_collision : MutableCollisionState? = None
  let mut current_inertial : MutableInertialState? = None
  let mut current_material : MutableMaterialState? = None
  let mut visual_index = 0
  let mut collision_index = 0
  for tag in scan_tags(source) {
    if is_open_tag(tag, "robot") {
      robot_name = attr_or(tag.raw, "name", "")
    } else if is_open_tag(tag, "link") {
      let name = attr_or(tag.raw, "name", "")
      visual_index = 0
      collision_index = 0
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
        axis_node: None,
        limit: None,
        dynamics: None,
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
      match current_collision {
        Some(collision) =>
          current_collision = Some({
            ..collision,
            origin: Some(
              origin_node(
                "origin:\{collision.link_name}:collision:\{collision.index}",
                tag,
              ),
            ),
          })
        None =>
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
              match current_inertial {
                Some(inertial) =>
                  current_inertial = Some({
                    ..inertial,
                    origin: Some(
                      origin_node("origin:inertial:\{inertial.link_name}", tag),
                    ),
                  })
                None =>
                  match current_joint {
                    Some(joint) =>
                      current_joint = Some({
                        ..joint,
                        origin: Some(
                          origin_node("origin:joint:\{joint.name}", tag),
                        ),
                      })
                    None => ()
                  }
              }
          }
      }
    } else if is_open_tag(tag, "axis") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({
            ..joint,
            axis: attr_or(tag.raw, "xyz", ""),
            axis_node: Some(axis_node("axis:joint:\{joint.name}", tag)),
          })
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
    } else if is_open_tag(tag, "dynamics") {
      match current_joint {
        Some(joint) =>
          current_joint = Some({
            ..joint,
            dynamics: Some(dynamics_node("dynamics:joint:\{joint.name}", tag)),
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
    } else if is_open_tag(tag, "collision") {
      match current_link {
        Some(link) => {
          current_collision = Some({
            link_name: link.name,
            index: collision_index,
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
          collision_index += 1
        }
        None =>
          parse_issues.push(
            issue(
              "collision-outside-link",
              Error,
              "collision",
              "collision tag outside link",
            ),
          )
      }
    } else if is_close_tag(tag, "collision") {
      current_collision = close_collision(
        collisions,
        current_collision,
        Some(tag.span),
      )
    } else if is_open_tag(tag, "inertial") {
      match current_link {
        Some(link) =>
          current_inertial = Some({
            link_name: link.name,
            origin: None,
            mass: None,
            ixx: None,
            ixy: None,
            ixz: None,
            iyy: None,
            iyz: None,
            izz: None,
            source_span: tag.span,
            open_tag_span: tag.span,
          })
        None =>
          parse_issues.push(
            issue(
              "inertial-outside-link",
              Error,
              "inertial",
              "inertial tag outside link",
            ),
          )
      }
    } else if is_close_tag(tag, "inertial") {
      current_inertial = close_inertial(
        inertials,
        current_inertial,
        Some(tag.span),
      )
    } else if is_open_tag(tag, "mass") {
      match current_inertial {
        Some(inertial) =>
          current_inertial = Some({
            ..inertial,
            mass: parse_double_attr(tag.raw, "value"),
          })
        None => ()
      }
    } else if is_open_tag(tag, "inertia") {
      match current_inertial {
        Some(inertial) =>
          current_inertial = Some({
            ..inertial,
            ixx: parse_double_attr(tag.raw, "ixx"),
            ixy: parse_double_attr(tag.raw, "ixy"),
            ixz: parse_double_attr(tag.raw, "ixz"),
            iyy: parse_double_attr(tag.raw, "iyy"),
            iyz: parse_double_attr(tag.raw, "iyz"),
            izz: parse_double_attr(tag.raw, "izz"),
          })
        None => ()
      }
    } else if is_open_tag(tag, "material") {
      let material = match current_visual {
        Some(visual) =>
          Some({
            scope: "visual",
            name: attr_or(tag.raw, "name", ""),
            link_name: visual.link_name,
            visual_index: Some(visual.index),
            color_rgba: "",
            texture_filename: "",
            color_source_span: None,
            texture_source_span: None,
            source_span: tag.span,
            open_tag_span: tag.span,
          })
        None =>
          match current_link {
            None =>
              Some({
                scope: "robot",
                name: attr_or(tag.raw, "name", ""),
                link_name: "",
                visual_index: None,
                color_rgba: "",
                texture_filename: "",
                color_source_span: None,
                texture_source_span: None,
                source_span: tag.span,
                open_tag_span: tag.span,
              })
            Some(_) => None
          }
      }
      match material {
        Some(value) =>
          if tag.self_closing {
            ignore(close_material(materials, Some(value), None))
          } else {
            current_material = Some(value)
          }
        None => ()
      }
    } else if is_close_tag(tag, "material") {
      current_material = close_material(
        materials,
        current_material,
        Some(tag.span),
      )
    } else if is_open_tag(tag, "color") {
      match current_material {
        Some(material) =>
          current_material = Some({
            ..material,
            color_rgba: attr_or(tag.raw, "rgba", ""),
            color_source_span: Some(tag.span),
          })
        None => ()
      }
    } else if is_open_tag(tag, "texture") {
      match current_material {
        Some(material) =>
          current_material = Some({
            ..material,
            texture_filename: attr_or(tag.raw, "filename", ""),
            texture_source_span: Some(tag.span),
          })
        None => ()
      }
    } else if is_open_tag(tag, "mesh") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "mesh",
            mesh_filename: attr_or(tag.raw, "filename", ""),
            mesh_scale: attr_or(tag.raw, "scale", ""),
          })
        None =>
          match current_collision {
            Some(collision) =>
              current_collision = Some({
                ..collision,
                geometry_kind: "mesh",
                mesh_filename: attr_or(tag.raw, "filename", ""),
                mesh_scale: attr_or(tag.raw, "scale", ""),
              })
            None => ()
          }
      }
    } else if is_open_tag(tag, "box") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "box",
            size: attr_or(tag.raw, "size", ""),
          })
        None =>
          match current_collision {
            Some(collision) =>
              current_collision = Some({
                ..collision,
                geometry_kind: "box",
                size: attr_or(tag.raw, "size", ""),
              })
            None => ()
          }
      }
    } else if is_open_tag(tag, "sphere") {
      match current_visual {
        Some(visual) =>
          current_visual = Some({
            ..visual,
            geometry_kind: "sphere",
            radius: parse_double_attr(tag.raw, "radius"),
          })
        None =>
          match current_collision {
            Some(collision) =>
              current_collision = Some({
                ..collision,
                geometry_kind: "sphere",
                radius: parse_double_attr(tag.raw, "radius"),
              })
            None => ()
          }
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
        None =>
          match current_collision {
            Some(collision) =>
              current_collision = Some({
                ..collision,
                geometry_kind: "cylinder",
                radius: parse_double_attr(tag.raw, "radius"),
                length: parse_double_attr(tag.raw, "length"),
              })
            None => ()
          }
      }
    }
  }
  current_link = close_link(links, current_link, None)
  current_joint = close_joint(joints, current_joint, None)
  current_visual = close_visual(visuals, current_visual, None)
  current_collision = close_collision(collisions, current_collision, None)
  current_inertial = close_inertial(inertials, current_inertial, None)
  current_material = close_material(materials, current_material, None)
  ignore(current_link)
  ignore(current_joint)
  ignore(current_visual)
  ignore(current_collision)
  ignore(current_inertial)
  ignore(current_material)
  {
    source,
    robot_name,
    links,
    joints,
    visuals,
    collisions,
    inertials,
    materials,
    issues: validate_document(
      robot_name, links, joints, visuals, collisions, inertials, materials, parse_issues,
    ),
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

///|
pub fn find_collision(
  doc : UrdfDocument,
  link_name : String,
  index : Int,
) -> UrdfCollisionNode? {
  for collision in doc.collisions {
    if collision.link_name == link_name && collision.index == index {
      return Some(collision)
    }
  }
  None
}

///|
pub fn find_inertial(
  doc : UrdfDocument,
  link_name : String,
) -> UrdfInertialNode? {
  for inertial in doc.inertials {
    if inertial.link_name == link_name {
      return Some(inertial)
    }
  }
  None
}

///|
pub fn find_material(doc : UrdfDocument, node_id : String) -> UrdfMaterialNode? {
  for material in doc.materials {
    if material.node_id == node_id {
      return Some(material)
    }
  }
  None
}
