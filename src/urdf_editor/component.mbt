///|
pub(all) struct UrdfEditorComponentRow {
  node_id : String
  kind : String
  parent_id : String
  label : String
  detail : String
  command_count : Int
  issue_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorField {
  name : String
  value : String
  editable : Bool
  command : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorSelectionDetail {
  node_id : String
  kind : String
  label : String
  summary : String
  fields : Array[UrdfEditorField]
  commands : Array[String]
  issues : Array[UrdfEditorIssue]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn find_link(doc : UrdfDocument, name : String) -> UrdfLinkNode? {
  for link in doc.links {
    if link.name == name {
      return Some(link)
    }
  }
  None
}

///|
fn component_issues(
  doc : UrdfDocument,
  node_id : String,
) -> Array[UrdfEditorIssue] {
  doc.issues.filter(fn(item) { item.node_id == node_id })
}

///|
fn field(
  name : String,
  value : String,
  editable? : Bool = false,
  command? : String = "",
) -> UrdfEditorField {
  { name, value, editable, command }
}

///|
fn maybe_double_text(value : Double?) -> String {
  match value {
    Some(number) => "\{number}"
    None => ""
  }
}

///|
fn maybe_origin_text(origin : UrdfOriginNode?) -> String {
  match origin {
    Some(value) => "xyz \{value.xyz}; rpy \{value.rpy}"
    None => ""
  }
}

///|
fn maybe_limit_text(limit : UrdfLimitNode?) -> String {
  match limit {
    Some(value) =>
      "lower \{maybe_double_text(value.lower)} upper \{maybe_double_text(value.upper)} effort \{maybe_double_text(value.effort)} velocity \{maybe_double_text(value.velocity)}"
    None => ""
  }
}

///|
fn link_visual_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.visuals.filter(fn(visual) { visual.link_name == link_name }).length()
}

///|
fn link_collision_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.collisions
  .filter(fn(collision) { collision.link_name == link_name })
  .length()
}

///|
fn link_inertial_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.inertials
  .filter(fn(inertial) { inertial.link_name == link_name })
  .length()
}

///|
fn link_material_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.materials
  .filter(fn(material) { material.link_name == link_name })
  .length()
}

///|
fn global_material_count(doc : UrdfDocument) -> Int {
  doc.materials.filter(fn(material) { material.scope == "robot" }).length()
}

///|
fn parent_joint_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.joints.filter(fn(joint) { joint.child_link == link_name }).length()
}

///|
fn child_joint_count(doc : UrdfDocument, link_name : String) -> Int {
  doc.joints.filter(fn(joint) { joint.parent_link == link_name }).length()
}

///|
fn component_row(
  doc : UrdfDocument,
  node_id : String,
  kind : String,
  parent_id : String,
  label : String,
  detail : String,
  command_count : Int,
) -> UrdfEditorComponentRow {
  {
    node_id,
    kind,
    parent_id,
    label,
    detail,
    command_count,
    issue_count: component_issues(doc, node_id).length(),
  }
}

///|
pub fn component_tree(doc : UrdfDocument) -> Array[UrdfEditorComponentRow] {
  let rows : Array[UrdfEditorComponentRow] = [
    component_row(
      doc,
      "robot",
      "robot",
      "",
      if doc.robot_name == "" {
        "robot"
      } else {
        doc.robot_name
      },
      "\{doc.links.length()} links, \{doc.joints.length()} joints, \{doc.visuals.length()} visuals, \{doc.collisions.length()} collisions, \{doc.inertials.length()} inertials, \{doc.materials.length()} materials",
      0,
    ),
  ]
  for link in doc.links {
    rows.push(
      component_row(
        doc,
        link.node_id,
        "link",
        "robot",
        link.name,
        "\{parent_joint_count(doc, link.name)} parent joints, \{child_joint_count(doc, link.name)} child joints, \{link_visual_count(doc, link.name)} visuals, \{link_collision_count(doc, link.name)} collisions, \{link_inertial_count(doc, link.name)} inertials",
        0,
      ),
    )
  }
  for joint in doc.joints {
    rows.push(
      component_row(
        doc,
        joint.node_id,
        "joint",
        "link:\{joint.parent_link}",
        joint.name,
        "\{joint.joint_type} \{joint.parent_link}->\{joint.child_link}",
        2,
      ),
    )
  }
  for visual in doc.visuals {
    rows.push(
      component_row(
        doc,
        visual.node_id,
        "visual",
        "link:\{visual.link_name}",
        "\{visual.link_name} visual \{visual.index}",
        "\{visual.geometry_kind} \{visual.mesh_filename}",
        1,
      ),
    )
  }
  for collision in doc.collisions {
    rows.push(
      component_row(
        doc,
        collision.node_id,
        "collision",
        "link:\{collision.link_name}",
        "\{collision.link_name} collision \{collision.index}",
        "\{collision.geometry_kind} \{collision.mesh_filename}",
        1,
      ),
    )
  }
  for inertial in doc.inertials {
    rows.push(
      component_row(
        doc,
        inertial.node_id,
        "inertial",
        "link:\{inertial.link_name}",
        "\{inertial.link_name} inertial",
        "mass \{maybe_double_text(inertial.mass)}",
        1,
      ),
    )
  }
  for material in doc.materials {
    rows.push(
      component_row(
        doc,
        material.node_id,
        "material",
        match material.visual_index {
          Some(index) => "visual:\{material.link_name}:\{index}"
          None => "robot"
        },
        if material.name == "" {
          "\{material.scope} material"
        } else {
          material.name
        },
        if material.texture_filename != "" {
          "texture \{material.texture_filename}"
        } else {
          "color \{material.color_rgba}"
        },
        0,
      ),
    )
  }
  rows
}

///|
fn robot_selection(doc : UrdfDocument) -> UrdfEditorSelectionDetail {
  {
    node_id: "robot",
    kind: "robot",
    label: if doc.robot_name == "" {
      "robot"
    } else {
      doc.robot_name
    },
    summary: "\{doc.links.length()} links, \{doc.joints.length()} joints, \{doc.visuals.length()} visuals, \{doc.collisions.length()} collisions, \{doc.inertials.length()} inertials, \{doc.materials.length()} materials",
    fields: [
      field("name", doc.robot_name),
      field("links", "\{doc.links.length()}"),
      field("joints", "\{doc.joints.length()}"),
      field("visuals", "\{doc.visuals.length()}"),
      field("collisions", "\{doc.collisions.length()}"),
      field("inertials", "\{doc.inertials.length()}"),
      field("materials", "\{doc.materials.length()}"),
      field("global materials", "\{global_material_count(doc)}"),
      field("diagnostics", "\{doc.issues.length()}"),
    ],
    commands: [],
    issues: component_issues(doc, "robot"),
  }
}

///|
fn link_selection(
  doc : UrdfDocument,
  link : UrdfLinkNode,
) -> UrdfEditorSelectionDetail {
  {
    node_id: link.node_id,
    kind: "link",
    label: link.name,
    summary: "\{parent_joint_count(doc, link.name)} incoming joints, \{child_joint_count(doc, link.name)} outgoing joints, \{link_visual_count(doc, link.name)} visuals, \{link_collision_count(doc, link.name)} collisions, \{link_inertial_count(doc, link.name)} inertials",
    fields: [
      field("name", link.name),
      field("incoming joints", "\{parent_joint_count(doc, link.name)}"),
      field("outgoing joints", "\{child_joint_count(doc, link.name)}"),
      field("visuals", "\{link_visual_count(doc, link.name)}"),
      field("collisions", "\{link_collision_count(doc, link.name)}"),
      field("inertials", "\{link_inertial_count(doc, link.name)}"),
      field("materials", "\{link_material_count(doc, link.name)}"),
      field("source span", "\{link.source_span.start}..\{link.source_span.end}"),
    ],
    commands: [],
    issues: component_issues(doc, link.node_id),
  }
}

///|
fn joint_selection(
  joint : UrdfJointNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: joint.node_id,
    kind: "joint",
    label: joint.name,
    summary: "\{joint.joint_type} joint from \{joint.parent_link} to \{joint.child_link}",
    fields: [
      field("name", joint.name),
      field("type", joint.joint_type),
      field("parent", joint.parent_link),
      field("child", joint.child_link),
      field(
        "origin",
        maybe_origin_text(joint.origin),
        editable=true,
        command="update-joint-origin",
      ),
      field("axis", joint.axis),
      field(
        "limit",
        maybe_limit_text(joint.limit),
        editable=true,
        command="update-joint-limit",
      ),
    ],
    commands: ["update-joint-origin", "update-joint-limit"],
    issues,
  }
}

///|
fn visual_selection(
  visual : UrdfVisualNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: visual.node_id,
    kind: "visual",
    label: "\{visual.link_name} visual \{visual.index}",
    summary: "\{visual.geometry_kind} visual on \{visual.link_name}",
    fields: [
      field("link", visual.link_name),
      field("index", "\{visual.index}"),
      field("geometry", visual.geometry_kind),
      field("mesh", visual.mesh_filename),
      field("scale", visual.mesh_scale),
      field("size", visual.size),
      field("radius", maybe_double_text(visual.radius)),
      field("length", maybe_double_text(visual.length)),
      field(
        "origin",
        maybe_origin_text(visual.origin),
        editable=true,
        command="update-visual-origin",
      ),
    ],
    commands: ["update-visual-origin"],
    issues,
  }
}

///|
fn collision_selection(
  collision : UrdfCollisionNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: collision.node_id,
    kind: "collision",
    label: "\{collision.link_name} collision \{collision.index}",
    summary: "\{collision.geometry_kind} collision on \{collision.link_name}",
    fields: [
      field("link", collision.link_name),
      field("index", "\{collision.index}"),
      field("geometry", collision.geometry_kind),
      field("mesh", collision.mesh_filename),
      field("scale", collision.mesh_scale),
      field("size", collision.size),
      field("radius", maybe_double_text(collision.radius)),
      field("length", maybe_double_text(collision.length)),
      field(
        "origin",
        maybe_origin_text(collision.origin),
        editable=true,
        command="update-collision-origin",
      ),
    ],
    commands: ["update-collision-origin"],
    issues,
  }
}

///|
fn inertial_selection(
  inertial : UrdfInertialNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: inertial.node_id,
    kind: "inertial",
    label: "\{inertial.link_name} inertial",
    summary: "mass \{maybe_double_text(inertial.mass)} on \{inertial.link_name}",
    fields: [
      field("link", inertial.link_name),
      field(
        "origin",
        maybe_origin_text(inertial.origin),
        editable=true,
        command="update-inertial",
      ),
      field(
        "mass",
        maybe_double_text(inertial.mass),
        editable=true,
        command="update-inertial",
      ),
      field(
        "ixx",
        maybe_double_text(inertial.ixx),
        editable=true,
        command="update-inertial",
      ),
      field(
        "ixy",
        maybe_double_text(inertial.ixy),
        editable=true,
        command="update-inertial",
      ),
      field(
        "ixz",
        maybe_double_text(inertial.ixz),
        editable=true,
        command="update-inertial",
      ),
      field(
        "iyy",
        maybe_double_text(inertial.iyy),
        editable=true,
        command="update-inertial",
      ),
      field(
        "iyz",
        maybe_double_text(inertial.iyz),
        editable=true,
        command="update-inertial",
      ),
      field(
        "izz",
        maybe_double_text(inertial.izz),
        editable=true,
        command="update-inertial",
      ),
      field(
        "source span",
        "\{inertial.source_span.start}..\{inertial.source_span.end}",
      ),
    ],
    commands: ["update-inertial"],
    issues,
  }
}

///|
fn material_selection(
  material : UrdfMaterialNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: material.node_id,
    kind: "material",
    label: if material.name == "" {
      "\{material.scope} material"
    } else {
      material.name
    },
    summary: if material.texture_filename != "" {
      "\{material.scope} material texture \{material.texture_filename}"
    } else {
      "\{material.scope} material color \{material.color_rgba}"
    },
    fields: [
      field("scope", material.scope),
      field("name", material.name),
      field("link", material.link_name),
      field(
        "visual index",
        match material.visual_index {
          Some(index) => "\{index}"
          None => ""
        },
      ),
      field("color rgba", material.color_rgba),
      field("texture", material.texture_filename),
      field(
        "source span",
        "\{material.source_span.start}..\{material.source_span.end}",
      ),
    ],
    commands: [],
    issues,
  }
}

///|
pub fn select_component(
  doc : UrdfDocument,
  node_id : String,
) -> UrdfEditorSelectionDetail? {
  if node_id == "robot" || node_id == "" {
    return Some(robot_selection(doc))
  }
  for link in doc.links {
    if link.node_id == node_id {
      return Some(link_selection(doc, link))
    }
  }
  for joint in doc.joints {
    if joint.node_id == node_id {
      return Some(joint_selection(joint, component_issues(doc, node_id)))
    }
  }
  for visual in doc.visuals {
    if visual.node_id == node_id {
      return Some(visual_selection(visual, component_issues(doc, node_id)))
    }
  }
  for collision in doc.collisions {
    if collision.node_id == node_id {
      return Some(
        collision_selection(collision, component_issues(doc, node_id)),
      )
    }
  }
  for inertial in doc.inertials {
    if inertial.node_id == node_id {
      return Some(inertial_selection(inertial, component_issues(doc, node_id)))
    }
  }
  for material in doc.materials {
    if material.node_id == node_id {
      return Some(material_selection(material, component_issues(doc, node_id)))
    }
  }
  None
}
