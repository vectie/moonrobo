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
