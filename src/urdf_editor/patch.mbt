///|
fn maybe_attr(name : String, value : Double?) -> String {
  match value {
    Some(number) => " \{name}=\"\{number.to_string()}\""
    None => ""
  }
}

///|
fn origin_tag(patch : UrdfOriginPatch) -> String {
  "<origin xyz=\"\{patch.xyz}\" rpy=\"\{patch.rpy}\"/>"
}

///|
fn limit_tag(patch : UrdfLimitPatch) -> String {
  "<limit" +
  maybe_attr("lower", patch.lower) +
  maybe_attr("upper", patch.upper) +
  maybe_attr("effort", patch.effort) +
  maybe_attr("velocity", patch.velocity) +
  "/>"
}

///|
fn mass_tag(value : Double?) -> String? {
  match value {
    Some(number) => Some("<mass value=\"\{number.to_string()}\"/>")
    None => None
  }
}

///|
fn inertia_tag(patch : UrdfInertialPatch) -> String? {
  let tag = "<inertia" +
    maybe_attr("ixx", patch.ixx) +
    maybe_attr("ixy", patch.ixy) +
    maybe_attr("ixz", patch.ixz) +
    maybe_attr("iyy", patch.iyy) +
    maybe_attr("iyz", patch.iyz) +
    maybe_attr("izz", patch.izz) +
    "/>"
  if tag == "<inertia/>" {
    None
  } else {
    Some(tag)
  }
}

///|
fn material_color_tag(value : String) -> String? {
  if value.trim() == "" {
    None
  } else {
    Some("<color rgba=\"\{value}\"/>")
  }
}

///|
fn material_texture_tag(value : String) -> String? {
  if value.trim() == "" {
    None
  } else {
    Some("<texture filename=\"\{value}\"/>")
  }
}

///|
fn material_open_tag(material : UrdfMaterialNode) -> String {
  if material.name == "" {
    "<material>"
  } else {
    "<material name=\"\{material.name}\">"
  }
}

///|
fn material_block_tag(
  source : String,
  material : UrdfMaterialNode,
  color_rgba : String,
  texture_filename : String,
) -> String {
  let indent = indentation_before(source, material.open_tag_span.start)
  let child_indent = "\{indent}  "
  let lines : Array[String] = [material_open_tag(material)]
  match material_color_tag(color_rgba) {
    Some(tag) => lines.push("\{child_indent}\{tag}")
    None => ()
  }
  match material_texture_tag(texture_filename) {
    Some(tag) => lines.push("\{child_indent}\{tag}")
    None => ()
  }
  lines.push("\{indent}</material>")
  lines.join("\n")
}

///|
fn inertial_tag(
  source : String,
  parent_open : UrdfSourceSpan,
  patch : UrdfInertialPatch,
) -> String {
  let indent = indentation_before(source, parent_open.start)
  let block_indent = "\{indent}  "
  let child_indent = "\{indent}    "
  let lines : Array[String] = ["<inertial>"]
  match patch.origin {
    Some(origin) => lines.push("\{child_indent}\{origin_tag(origin)}")
    None => ()
  }
  match mass_tag(patch.mass) {
    Some(tag) => lines.push("\{child_indent}\{tag}")
    None => ()
  }
  match inertia_tag(patch) {
    Some(tag) => lines.push("\{child_indent}\{tag}")
    None => ()
  }
  lines.push("\{block_indent}</inertial>")
  lines.join("\n")
}

///|
fn child_insert_text(
  source : String,
  parent_open : UrdfSourceSpan,
  tag : String,
) -> String {
  let indent = indentation_before(source, parent_open.start)
  "\n\{indent}  \{tag}"
}

///|
fn child_lines_insert_text(
  source : String,
  parent_open : UrdfSourceSpan,
  tags : Array[String],
) -> String {
  let indent = indentation_before(source, parent_open.start)
  let lines = tags.map(fn(tag) { "\{indent}  \{tag}" })
  "\n" + lines.join("\n")
}

///|
fn successful_edit(
  command : String,
  target : String,
  next_source : String,
  changed : Bool,
) -> UrdfEditResult {
  let doc = parse_document(next_source)
  {
    changed,
    command,
    target,
    source: next_source,
    message: if changed {
      "\{command} applied to \{target}"
    } else {
      "\{command} left \{target} unchanged"
    },
    issues: doc.issues,
  }
}

///|
pub fn update_joint_limit(
  source : String,
  joint_name : String,
  patch : UrdfLimitPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update limit for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  match (patch.lower, patch.upper) {
    (Some(lower), Some(upper)) =>
      if lower > upper {
        return Err(
          edit_error(
            "joint-limit-order",
            joint_name,
            "joint limit lower is greater than upper",
            doc.issues,
          ),
        )
      }
    _ => ()
  }
  let tag = limit_tag(patch)
  let next_source = match joint.limit {
    Some(limit) => apply_span_patch(source, limit.source_span, tag)
    None =>
      match joint.close_tag_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(source, joint.open_tag_span, tag),
          )
        None =>
          return Err(
            edit_error(
              "joint-close-missing",
              joint_name,
              "cannot insert limit into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-limit",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_joint_origin(
  source : String,
  joint_name : String,
  patch : UrdfOriginPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update origin for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  let tag = origin_tag(patch)
  let next_source = match joint.origin {
    Some(origin) => apply_span_patch(source, origin.source_span, tag)
    None =>
      match joint.close_tag_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(source, joint.open_tag_span, tag),
          )
        None =>
          return Err(
            edit_error(
              "joint-close-missing",
              joint_name,
              "cannot insert origin into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-origin",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_visual_origin(
  source : String,
  link_name : String,
  visual_index : Int,
  patch : UrdfOriginPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let visual = match find_visual(doc, link_name, visual_index) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "visual-not-found",
          "\{link_name}:\{visual_index}",
          "cannot update origin for missing visual `\{link_name}:\{visual_index}`",
          doc.issues,
        ),
      )
  }
  let tag = origin_tag(patch)
  let next_source = match visual.origin {
    Some(origin) => apply_span_patch(source, origin.source_span, tag)
    None =>
      match visual.close_tag_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(source, visual.open_tag_span, tag),
          )
        None =>
          return Err(
            edit_error(
              "visual-close-missing",
              "\{link_name}:\{visual_index}",
              "cannot insert origin into unterminated visual `\{link_name}:\{visual_index}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-visual-origin",
      "\{link_name}:\{visual_index}",
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_collision_origin(
  source : String,
  link_name : String,
  collision_index : Int,
  patch : UrdfOriginPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let collision = match find_collision(doc, link_name, collision_index) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "collision-not-found",
          "\{link_name}:\{collision_index}",
          "cannot update origin for missing collision `\{link_name}:\{collision_index}`",
          doc.issues,
        ),
      )
  }
  let tag = origin_tag(patch)
  let next_source = match collision.origin {
    Some(origin) => apply_span_patch(source, origin.source_span, tag)
    None =>
      match collision.close_tag_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(source, collision.open_tag_span, tag),
          )
        None =>
          return Err(
            edit_error(
              "collision-close-missing",
              "\{link_name}:\{collision_index}",
              "cannot insert origin into unterminated collision `\{link_name}:\{collision_index}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-collision-origin",
      "\{link_name}:\{collision_index}",
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_inertial(
  source : String,
  link_name : String,
  patch : UrdfInertialPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let link = match find_link(doc, link_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "link-not-found",
          link_name,
          "cannot update inertial for missing link `\{link_name}`",
          doc.issues,
        ),
      )
  }
  let tag = inertial_tag(source, link.open_tag_span, patch)
  let next_source = match find_inertial(doc, link_name) {
    Some(inertial) => apply_span_patch(source, inertial.source_span, tag)
    None =>
      match link.close_tag_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(source, link.open_tag_span, tag),
          )
        None =>
          return Err(
            edit_error(
              "link-close-missing",
              link_name,
              "cannot insert inertial into self-closing or unterminated link `\{link_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-inertial",
      link_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_material(
  source : String,
  material_node_id : String,
  patch : UrdfMaterialPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let material = match find_material(doc, material_node_id) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "material-not-found",
          material_node_id,
          "cannot update missing material `\{material_node_id}`",
          doc.issues,
        ),
      )
  }
  let color_rgba = match patch.color_rgba {
    Some(value) => value
    None => material.color_rgba
  }
  let texture_filename = match patch.texture_filename {
    Some(value) => value
    None => material.texture_filename
  }
  let color = material_color_tag(color_rgba)
  let texture = material_texture_tag(texture_filename)
  if color is None && texture is None {
    return Ok(
      successful_edit("update-material", material_node_id, source, false),
    )
  }
  let next_source = match material.close_tag_span {
    None =>
      apply_span_patch(
        source,
        material.source_span,
        material_block_tag(source, material, color_rgba, texture_filename),
      )
    Some(close_span) => {
      let missing_tags : Array[String] = []
      match color {
        Some(tag) =>
          match material.color_source_span {
            Some(_) => ()
            None => missing_tags.push(tag)
          }
        None => ()
      }
      match texture {
        Some(tag) =>
          match material.texture_source_span {
            Some(_) => ()
            None => missing_tags.push(tag)
          }
        None => ()
      }
      let mut edited = if missing_tags.is_empty() {
        source
      } else {
        apply_span_patch(
          source,
          empty_span(close_span.start),
          child_lines_insert_text(source, material.open_tag_span, missing_tags),
        )
      }
      match
        (
          color,
          material.color_source_span,
          texture,
          material.texture_source_span,
        ) {
        (
          Some(color_tag),
          Some(color_span),
          Some(texture_tag),
          Some(texture_span),
        ) =>
          if color_span.start > texture_span.start {
            edited = apply_span_patch(edited, color_span, color_tag)
            edited = apply_span_patch(edited, texture_span, texture_tag)
          } else {
            edited = apply_span_patch(edited, texture_span, texture_tag)
            edited = apply_span_patch(edited, color_span, color_tag)
          }
        (Some(color_tag), Some(color_span), _, _) =>
          edited = apply_span_patch(edited, color_span, color_tag)
        (_, _, Some(texture_tag), Some(texture_span)) =>
          edited = apply_span_patch(edited, texture_span, texture_tag)
        _ => ()
      }
      edited
    }
  }
  Ok(
    successful_edit(
      "update-material",
      material_node_id,
      next_source,
      next_source != source,
    ),
  )
}
