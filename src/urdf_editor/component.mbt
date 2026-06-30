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
fn maybe_dynamics_text(dynamics : UrdfDynamicsNode?) -> String {
  match dynamics {
    Some(value) =>
      "damping \{maybe_double_text(value.damping)} friction \{maybe_double_text(value.friction)}"
    None => ""
  }
}

///|
fn maybe_mimic_text(mimic : UrdfMimicNode?) -> String {
  match mimic {
    Some(value) =>
      "joint \{value.target_joint} multiplier \{maybe_double_text(value.multiplier)} offset \{maybe_double_text(value.offset)}"
    None => ""
  }
}

///|
fn maybe_calibration_text(calibration : UrdfCalibrationNode?) -> String {
  match calibration {
    Some(value) =>
      "rising \{maybe_double_text(value.rising)} falling \{maybe_double_text(value.falling)}"
    None => ""
  }
}

///|
fn maybe_safety_controller_text(
  safety_controller : UrdfSafetyControllerNode?,
) -> String {
  match safety_controller {
    Some(value) =>
      "soft lower \{maybe_double_text(value.soft_lower_limit)} soft upper \{maybe_double_text(value.soft_upper_limit)} k position \{maybe_double_text(value.k_position)} k velocity \{maybe_double_text(value.k_velocity)}"
    None => ""
  }
}

///|
fn span_source_text(source : String, source_span : UrdfSourceSpan) -> String {
  source[source_span.start:source_span.end].to_owned()
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
      "\{doc.links.length()} links, \{doc.joints.length()} joints, \{doc.visuals.length()} visuals, \{doc.collisions.length()} collisions, \{doc.inertials.length()} inertials, \{doc.materials.length()} materials, \{doc.extensions.length()} extensions",
      2,
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
        3,
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
        8,
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
        3,
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
        3,
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
        1,
      ),
    )
  }
  for extension in doc.extensions {
    rows.push(
      component_row(
        doc,
        extension.node_id,
        "extension",
        extension.parent_id,
        extension.label,
        "\{extension.kind} \{extension.tag_name}",
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
    summary: "\{doc.links.length()} links, \{doc.joints.length()} joints, \{doc.visuals.length()} visuals, \{doc.collisions.length()} collisions, \{doc.inertials.length()} inertials, \{doc.materials.length()} materials, \{doc.extensions.length()} extensions",
    fields: [
      field("name", doc.robot_name),
      field("links", "\{doc.links.length()}"),
      field("joints", "\{doc.joints.length()}"),
      field("visuals", "\{doc.visuals.length()}"),
      field("collisions", "\{doc.collisions.length()}"),
      field("inertials", "\{doc.inertials.length()}"),
      field("materials", "\{doc.materials.length()}"),
      field("extensions", "\{doc.extensions.length()}"),
      field("global materials", "\{global_material_count(doc)}"),
      field("diagnostics", "\{doc.issues.length()}"),
    ],
    commands: ["add-link", "add-joint"],
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
      field("name", link.name, editable=true, command="rename-link"),
      field("incoming joints", "\{parent_joint_count(doc, link.name)}"),
      field("outgoing joints", "\{child_joint_count(doc, link.name)}"),
      field("visuals", "\{link_visual_count(doc, link.name)}"),
      field("collisions", "\{link_collision_count(doc, link.name)}"),
      field("inertials", "\{link_inertial_count(doc, link.name)}"),
      field("materials", "\{link_material_count(doc, link.name)}"),
      field("source span", "\{link.source_span.start}..\{link.source_span.end}"),
    ],
    commands: ["rename-link", "add-visual", "add-collision"],
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
      field("name", joint.name, editable=true, command="rename-joint"),
      field("type", joint.joint_type),
      field("parent", joint.parent_link),
      field("child", joint.child_link),
      field(
        "origin",
        maybe_origin_text(joint.origin),
        editable=true,
        command="update-joint-origin",
      ),
      field("axis", joint.axis, editable=true, command="update-joint-axis"),
      field(
        "limit",
        maybe_limit_text(joint.limit),
        editable=true,
        command="update-joint-limit",
      ),
      field(
        "dynamics",
        maybe_dynamics_text(joint.dynamics),
        editable=true,
        command="update-joint-dynamics",
      ),
      field(
        "mimic",
        maybe_mimic_text(joint.mimic),
        editable=true,
        command="update-joint-mimic",
      ),
      field(
        "calibration",
        maybe_calibration_text(joint.calibration),
        editable=true,
        command="update-joint-calibration",
      ),
      field(
        "safety controller",
        maybe_safety_controller_text(joint.safety_controller),
        editable=true,
        command="update-joint-safety-controller",
      ),
    ],
    commands: [
      "rename-joint", "update-joint-origin", "update-joint-axis", "update-joint-limit",
      "update-joint-dynamics", "update-joint-mimic", "update-joint-calibration",
      "update-joint-safety-controller",
    ],
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
      field(
        "geometry",
        visual.geometry_kind,
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "mesh",
        visual.mesh_filename,
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "scale",
        visual.mesh_scale,
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "size",
        visual.size,
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "radius",
        maybe_double_text(visual.radius),
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "length",
        maybe_double_text(visual.length),
        editable=true,
        command="update-visual-geometry",
      ),
      field(
        "origin",
        maybe_origin_text(visual.origin),
        editable=true,
        command="update-visual-origin",
      ),
    ],
    commands: [
      "update-visual-origin", "update-visual-geometry", "remove-visual",
    ],
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
      field(
        "geometry",
        collision.geometry_kind,
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "mesh",
        collision.mesh_filename,
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "scale",
        collision.mesh_scale,
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "size",
        collision.size,
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "radius",
        maybe_double_text(collision.radius),
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "length",
        maybe_double_text(collision.length),
        editable=true,
        command="update-collision-geometry",
      ),
      field(
        "origin",
        maybe_origin_text(collision.origin),
        editable=true,
        command="update-collision-origin",
      ),
    ],
    commands: [
      "update-collision-origin", "update-collision-geometry", "remove-collision",
    ],
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
      field(
        "color rgba",
        material.color_rgba,
        editable=true,
        command="update-material",
      ),
      field(
        "texture",
        material.texture_filename,
        editable=true,
        command="update-material",
      ),
      field(
        "source span",
        "\{material.source_span.start}..\{material.source_span.end}",
      ),
    ],
    commands: ["update-material"],
    issues,
  }
}

///|
fn extension_selection(
  doc : UrdfDocument,
  extension : UrdfExtensionNode,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditorSelectionDetail {
  {
    node_id: extension.node_id,
    kind: "extension",
    label: extension.label,
    summary: "\{extension.kind} extension under \{extension.parent_id}",
    fields: [
      field("kind", extension.kind),
      field("tag", extension.tag_name),
      field("parent", extension.parent_id),
      field("raw", extension.raw),
      field(
        "source span",
        "\{extension.source_span.start}..\{extension.source_span.end}",
      ),
      field(
        "source",
        span_source_text(doc.source, extension.source_span),
        editable=true,
        command="update-extension-raw",
      ),
      field(
        "attribute",
        attr_or(extension.raw, "name", attr_or(extension.raw, "reference", "")),
        editable=extension.kind != "comment",
        command="update-extension-attribute",
      ),
    ],
    commands: if extension.kind == "comment" {
      ["update-extension-raw"]
    } else {
      ["update-extension-raw", "update-extension-attribute"]
    },
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
  for extension in doc.extensions {
    if extension.node_id == node_id {
      return Some(
        extension_selection(doc, extension, component_issues(doc, node_id)),
      )
    }
  }
  None
}
