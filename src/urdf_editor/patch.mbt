///|
fn maybe_attr(name : String, value : Double?) -> String {
  match value {
    Some(number) => " \{name}=\"\{number.to_string()}\""
    None => ""
  }
}

///|
fn maybe_text_attr(name : String, value : String) -> String {
  if value.trim() == "" {
    ""
  } else {
    " \{name}=\"\{value}\""
  }
}

///|
fn origin_tag(patch : UrdfOriginPatch) -> String {
  "<origin xyz=\"\{patch.xyz}\" rpy=\"\{patch.rpy}\"/>"
}

///|
fn axis_tag(patch : UrdfAxisPatch) -> String {
  "<axis xyz=\"\{patch.xyz}\"/>"
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
fn dynamics_tag(patch : UrdfDynamicsPatch) -> String {
  "<dynamics" +
  maybe_attr("damping", patch.damping) +
  maybe_attr("friction", patch.friction) +
  "/>"
}

///|
fn mimic_tag(patch : UrdfMimicPatch) -> String {
  "<mimic joint=\"\{patch.target_joint}\"" +
  maybe_attr("multiplier", patch.multiplier) +
  maybe_attr("offset", patch.offset) +
  "/>"
}

///|
fn calibration_tag(patch : UrdfCalibrationPatch) -> String {
  "<calibration" +
  maybe_attr("rising", patch.rising) +
  maybe_attr("falling", patch.falling) +
  "/>"
}

///|
fn safety_controller_tag(patch : UrdfSafetyControllerPatch) -> String {
  "<safety_controller" +
  maybe_attr("soft_lower_limit", patch.soft_lower_limit) +
  maybe_attr("soft_upper_limit", patch.soft_upper_limit) +
  maybe_attr("k_position", patch.k_position) +
  maybe_attr("k_velocity", patch.k_velocity) +
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
fn geometry_primitive_tag(
  kind : String,
  mesh_filename : String,
  mesh_scale : String,
  size : String,
  radius : Double?,
  length : Double?,
) -> Result[String, String] {
  match kind {
    "mesh" =>
      if mesh_filename.trim() == "" {
        Err("mesh geometry requires mesh_filename")
      } else {
        Ok(
          "<mesh filename=\"\{mesh_filename}\"\{maybe_text_attr("scale", mesh_scale)}/>",
        )
      }
    "box" =>
      if size.trim() == "" {
        Err("box geometry requires size")
      } else {
        Ok("<box size=\"\{size}\"/>")
      }
    "sphere" =>
      match radius {
        Some(value) => Ok("<sphere radius=\"\{value.to_string()}\"/>")
        None => Err("sphere geometry requires radius")
      }
    "cylinder" =>
      match (radius, length) {
        (Some(r), Some(l)) =>
          Ok(
            "<cylinder radius=\"\{r.to_string()}\" length=\"\{l.to_string()}\"/>",
          )
        _ => Err("cylinder geometry requires radius and length")
      }
    _ => Err("unsupported geometry kind `\{kind}`")
  }
}

///|
fn geometry_block_for_span(
  source : String,
  open_span : UrdfSourceSpan,
  primitive_tag : String,
) -> String {
  let indent = indentation_before(source, open_span.start)
  let child_indent = "\{indent}  "
  ["<geometry>", "\{child_indent}\{primitive_tag}", "\{indent}</geometry>"].join(
    "\n",
  )
}

///|
fn geometry_block_for_parent(
  source : String,
  parent_open : UrdfSourceSpan,
  primitive_tag : String,
) -> String {
  let indent = indentation_before(source, parent_open.start)
  let block_indent = "\{indent}  "
  let child_indent = "\{indent}    "
  [
    "<geometry>",
    "\{child_indent}\{primitive_tag}",
    "\{block_indent}</geometry>",
  ].join("\n")
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
struct SourceReplacement {
  span : UrdfSourceSpan
  text : String
} derive(Debug, Eq)

///|
fn apply_replacements(
  source : String,
  replacements : Array[SourceReplacement],
) -> String {
  let mut edited = source
  for index in 0..<replacements.length() {
    let replacement = replacements[replacements.length() - 1 - index]
    edited = apply_span_patch(edited, replacement.span, replacement.text)
  }
  edited
}

///|
fn duplicate_name_error(
  kind : String,
  old_name : String,
  new_name : String,
  issues : Array[UrdfEditorIssue],
) -> UrdfEditError {
  edit_error(
    "duplicate-\{kind}",
    old_name,
    "cannot rename \{kind} `\{old_name}` to existing \{kind} `\{new_name}`",
    issues,
  )
}

///|
fn required_new_name(
  kind : String,
  old_name : String,
  new_name : String,
  issues : Array[UrdfEditorIssue],
) -> Result[String, UrdfEditError] {
  let clean = new_name.trim().to_owned()
  if clean == "" {
    Err(
      edit_error(
        "\{kind}-name-required",
        old_name,
        "cannot rename \{kind} `\{old_name}` to an empty name",
        issues,
      ),
    )
  } else {
    Ok(clean)
  }
}

///|
pub fn rename_joint(
  source : String,
  joint_name : String,
  new_name : String,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  match find_joint(doc, joint_name) {
    Some(_) => ()
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot rename missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  let clean = match
    required_new_name("joint", joint_name, new_name, doc.issues) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if clean == joint_name {
    return Ok(successful_edit("rename-joint", joint_name, source, false))
  }
  match find_joint(doc, clean) {
    Some(_) =>
      return Err(duplicate_name_error("joint", joint_name, clean, doc.issues))
    None => ()
  }
  let replacements : Array[SourceReplacement] = []
  for tag in scan_tags(source) {
    if is_open_tag(tag, "joint") && attr_or(tag.raw, "name", "") == joint_name {
      match attr_value_span(source, tag, "name") {
        Some(value_span) => replacements.push({ span: value_span, text: clean })
        None =>
          return Err(
            edit_error(
              "joint-name-attr-missing",
              joint_name,
              "cannot locate name attribute for joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
    }
  }
  let next_source = apply_replacements(source, replacements)
  Ok(
    successful_edit(
      "rename-joint",
      "\{joint_name}->\{clean}",
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn rename_link(
  source : String,
  link_name : String,
  new_name : String,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  match find_link(doc, link_name) {
    Some(_) => ()
    None =>
      return Err(
        edit_error(
          "link-not-found",
          link_name,
          "cannot rename missing link `\{link_name}`",
          doc.issues,
        ),
      )
  }
  let clean = match required_new_name("link", link_name, new_name, doc.issues) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if clean == link_name {
    return Ok(successful_edit("rename-link", link_name, source, false))
  }
  match find_link(doc, clean) {
    Some(_) =>
      return Err(duplicate_name_error("link", link_name, clean, doc.issues))
    None => ()
  }
  let replacements : Array[SourceReplacement] = []
  for tag in scan_tags(source) {
    if is_open_tag(tag, "link") && attr_or(tag.raw, "name", "") == link_name {
      match attr_value_span(source, tag, "name") {
        Some(value_span) => replacements.push({ span: value_span, text: clean })
        None =>
          return Err(
            edit_error(
              "link-name-attr-missing",
              link_name,
              "cannot locate name attribute for link `\{link_name}`",
              doc.issues,
            ),
          )
      }
    } else if (is_open_tag(tag, "parent") || is_open_tag(tag, "child")) &&
      attr_or(tag.raw, "link", "") == link_name {
      match attr_value_span(source, tag, "link") {
        Some(value_span) => replacements.push({ span: value_span, text: clean })
        None => ()
      }
    }
  }
  let next_source = apply_replacements(source, replacements)
  Ok(
    successful_edit(
      "rename-link",
      "\{link_name}->\{clean}",
      next_source,
      next_source != source,
    ),
  )
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
pub fn update_joint_axis(
  source : String,
  joint_name : String,
  patch : UrdfAxisPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update axis for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  if patch.xyz.trim() == "" {
    return Err(
      edit_error(
        "joint-axis-required",
        joint_name,
        "joint axis update requires xyz",
        doc.issues,
      ),
    )
  }
  let tag = axis_tag(patch)
  let next_source = match joint.axis_node {
    Some(axis) => apply_span_patch(source, axis.source_span, tag)
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
              "cannot insert axis into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-axis",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_joint_dynamics(
  source : String,
  joint_name : String,
  patch : UrdfDynamicsPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update dynamics for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  if patch.damping is None && patch.friction is None {
    return Err(
      edit_error(
        "joint-dynamics-required",
        joint_name,
        "joint dynamics update requires damping or friction",
        doc.issues,
      ),
    )
  }
  let tag = dynamics_tag(patch)
  let next_source = match joint.dynamics {
    Some(dynamics) => apply_span_patch(source, dynamics.source_span, tag)
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
              "cannot insert dynamics into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-dynamics",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_joint_mimic(
  source : String,
  joint_name : String,
  patch : UrdfMimicPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update mimic for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  let target = patch.target_joint.trim().to_owned()
  if target == "" {
    return Err(
      edit_error(
        "joint-mimic-target-required",
        joint_name,
        "joint mimic update requires target_joint",
        doc.issues,
      ),
    )
  }
  if target == joint_name {
    return Err(
      edit_error(
        "joint-mimic-self",
        joint_name,
        "joint cannot mimic itself",
        doc.issues,
      ),
    )
  }
  match find_joint(doc, target) {
    Some(_) => ()
    None =>
      return Err(
        edit_error(
          "joint-mimic-target-not-found",
          target,
          "joint mimic target `\{target}` is not declared",
          doc.issues,
        ),
      )
  }
  let tag = mimic_tag({ ..patch, target_joint: target })
  let next_source = match joint.mimic {
    Some(mimic) => apply_span_patch(source, mimic.source_span, tag)
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
              "cannot insert mimic into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-mimic",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_joint_calibration(
  source : String,
  joint_name : String,
  patch : UrdfCalibrationPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update calibration for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  if patch.rising is None && patch.falling is None {
    return Err(
      edit_error(
        "joint-calibration-required",
        joint_name,
        "joint calibration update requires rising or falling",
        doc.issues,
      ),
    )
  }
  let tag = calibration_tag(patch)
  let next_source = match joint.calibration {
    Some(calibration) => apply_span_patch(source, calibration.source_span, tag)
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
              "cannot insert calibration into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-calibration",
      joint_name,
      next_source,
      next_source != source,
    ),
  )
}

///|
pub fn update_joint_safety_controller(
  source : String,
  joint_name : String,
  patch : UrdfSafetyControllerPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let joint = match find_joint(doc, joint_name) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "joint-not-found",
          joint_name,
          "cannot update safety controller for missing joint `\{joint_name}`",
          doc.issues,
        ),
      )
  }
  if patch.soft_lower_limit is None &&
    patch.soft_upper_limit is None &&
    patch.k_position is None &&
    patch.k_velocity is None {
    return Err(
      edit_error(
        "joint-safety-controller-required",
        joint_name,
        "joint safety controller update requires at least one field",
        doc.issues,
      ),
    )
  }
  match (patch.soft_lower_limit, patch.soft_upper_limit) {
    (Some(lower), Some(upper)) =>
      if lower > upper {
        return Err(
          edit_error(
            "joint-safety-controller-order",
            joint_name,
            "joint safety controller soft lower limit is greater than soft upper limit",
            doc.issues,
          ),
        )
      }
    _ => ()
  }
  let tag = safety_controller_tag(patch)
  let next_source = match joint.safety_controller {
    Some(safety_controller) =>
      apply_span_patch(source, safety_controller.source_span, tag)
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
              "cannot insert safety controller into unterminated joint `\{joint_name}`",
              doc.issues,
            ),
          )
      }
  }
  Ok(
    successful_edit(
      "update-joint-safety-controller",
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
struct GeometrySourceTarget {
  open_span : UrdfSourceSpan
  close_span : UrdfSourceSpan?
  primitive_span : UrdfSourceSpan?
} derive(Debug, Eq)

///|
fn is_geometry_primitive_tag(tag : XmlTag) -> Bool {
  is_open_tag(tag, "mesh") ||
  is_open_tag(tag, "box") ||
  is_open_tag(tag, "sphere") ||
  is_open_tag(tag, "cylinder")
}

///|
fn find_geometry_source_target(
  source : String,
  container_span : UrdfSourceSpan,
) -> GeometrySourceTarget? {
  let mut open_span : UrdfSourceSpan? = None
  let mut primitive_span : UrdfSourceSpan? = None
  for tag in scan_tags(source) {
    if tag.span.start < container_span.start ||
      tag.span.end > container_span.end {
      continue
    }
    match open_span {
      None =>
        if is_open_tag(tag, "geometry") {
          if tag.self_closing {
            return Some({
              open_span: tag.span,
              close_span: None,
              primitive_span: None,
            })
          }
          open_span = Some(tag.span)
        }
      Some(open_value) =>
        if is_close_tag(tag, "geometry") {
          return Some({
            open_span: open_value,
            close_span: Some(tag.span),
            primitive_span,
          })
        } else if primitive_span is None && is_geometry_primitive_tag(tag) {
          primitive_span = Some(tag.span)
        }
    }
  }
  match open_span {
    Some(open_value) =>
      Some({ open_span: open_value, close_span: None, primitive_span })
    None => None
  }
}

///|
fn apply_geometry_patch(
  source : String,
  command : String,
  target : String,
  container_span : UrdfSourceSpan,
  container_open_span : UrdfSourceSpan,
  container_close_span : UrdfSourceSpan?,
  patch : UrdfGeometryPatch,
  existing_kind : String,
  existing_mesh_filename : String,
  existing_mesh_scale : String,
  existing_size : String,
  existing_radius : Double?,
  existing_length : Double?,
  issues : Array[UrdfEditorIssue],
) -> Result[UrdfEditResult, UrdfEditError] {
  let kind = if patch.kind.trim() == "" {
    existing_kind
  } else {
    patch.kind.trim().to_owned()
  }
  let mesh_filename = match patch.mesh_filename {
    Some(value) => value
    None => existing_mesh_filename
  }
  let mesh_scale = match patch.mesh_scale {
    Some(value) => value
    None => existing_mesh_scale
  }
  let size = match patch.size {
    Some(value) => value
    None => existing_size
  }
  let radius = match patch.radius {
    Some(_) => patch.radius
    None => existing_radius
  }
  let length = match patch.length {
    Some(_) => patch.length
    None => existing_length
  }
  let primitive = match
    geometry_primitive_tag(
      kind, mesh_filename, mesh_scale, size, radius, length,
    ) {
    Ok(value) => value
    Err(message) =>
      return Err(edit_error("geometry-invalid", target, message, issues))
  }
  let next_source = match find_geometry_source_target(source, container_span) {
    Some(found) =>
      match found.primitive_span {
        Some(span) => apply_span_patch(source, span, primitive)
        None =>
          match found.close_span {
            Some(close_span) =>
              apply_span_patch(
                source,
                empty_span(close_span.start),
                child_insert_text(source, found.open_span, primitive),
              )
            None =>
              apply_span_patch(
                source,
                found.open_span,
                geometry_block_for_span(source, found.open_span, primitive),
              )
          }
      }
    None =>
      match container_close_span {
        Some(close_span) =>
          apply_span_patch(
            source,
            empty_span(close_span.start),
            child_insert_text(
              source,
              container_open_span,
              geometry_block_for_parent(source, container_open_span, primitive),
            ),
          )
        None =>
          return Err(
            edit_error(
              "geometry-container-close-missing",
              target,
              "cannot insert geometry into self-closing or unterminated component `\{target}`",
              issues,
            ),
          )
      }
  }
  Ok(successful_edit(command, target, next_source, next_source != source))
}

///|
pub fn update_visual_geometry(
  source : String,
  link_name : String,
  visual_index : Int,
  patch : UrdfGeometryPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let visual = match find_visual(doc, link_name, visual_index) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "visual-not-found",
          "\{link_name}:\{visual_index}",
          "cannot update geometry for missing visual `\{link_name}:\{visual_index}`",
          doc.issues,
        ),
      )
  }
  apply_geometry_patch(
    source,
    "update-visual-geometry",
    "\{link_name}:\{visual_index}",
    visual.source_span,
    visual.open_tag_span,
    visual.close_tag_span,
    patch,
    visual.geometry_kind,
    visual.mesh_filename,
    visual.mesh_scale,
    visual.size,
    visual.radius,
    visual.length,
    doc.issues,
  )
}

///|
pub fn update_collision_geometry(
  source : String,
  link_name : String,
  collision_index : Int,
  patch : UrdfGeometryPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let collision = match find_collision(doc, link_name, collision_index) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "collision-not-found",
          "\{link_name}:\{collision_index}",
          "cannot update geometry for missing collision `\{link_name}:\{collision_index}`",
          doc.issues,
        ),
      )
  }
  apply_geometry_patch(
    source,
    "update-collision-geometry",
    "\{link_name}:\{collision_index}",
    collision.source_span,
    collision.open_tag_span,
    collision.close_tag_span,
    patch,
    collision.geometry_kind,
    collision.mesh_filename,
    collision.mesh_scale,
    collision.size,
    collision.radius,
    collision.length,
    doc.issues,
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
