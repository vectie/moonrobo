///|
struct UrdfPluginTarget {
  open_tag : XmlTag
  close_span : UrdfSourceSpan?
  source_span : UrdfSourceSpan
} derive(Debug, Eq)

///|
fn extension_open_tag(extension : UrdfExtensionNode) -> XmlTag {
  {
    raw: extension.raw,
    name: extension.tag_name,
    span: extension.open_tag_span,
    self_closing: extension.close_tag_span is None,
  }
}

///|
fn plugin_target_from_extension(
  source : String,
  extension : UrdfExtensionNode,
) -> UrdfPluginTarget? {
  if extension.kind == "plugin" {
    return Some({
      open_tag: extension_open_tag(extension),
      close_span: extension.close_tag_span,
      source_span: extension.source_span,
    })
  }
  if extension.kind != "gazebo" {
    return None
  }
  match find_text_element_target(source, extension.source_span, "plugin") {
    Some(target) => {
      let source_span = match target.close_span {
        Some(close_span) => span(target.open_tag.span.start, close_span.end)
        None => target.open_tag.span
      }
      Some({
        open_tag: target.open_tag,
        close_span: target.close_span,
        source_span,
      })
    }
    None => None
  }
}

///|
fn patched_plugin_open_text(
  source : String,
  plugin : UrdfPluginTarget,
  patch : UrdfGazeboPluginPatch,
) -> String {
  let mut text = source[plugin.open_tag.span.start:plugin.open_tag.span.end].to_owned()
  let mut tag = XmlTag::{
    raw: plugin.open_tag.raw,
    name: plugin.open_tag.name,
    span: span(0, text.length()),
    self_closing: plugin.open_tag.self_closing,
  }
  match patch.plugin_name {
    Some(value) =>
      if value.trim() != "" {
        text = apply_tag_attr_patch(text, tag, "name", value)
        tag = {
          ..tag,
          raw: text[1:text.length() - 1].trim().to_owned(),
          span: span(0, text.length()),
        }
      }
    None => ()
  }
  match patch.plugin_filename {
    Some(value) =>
      if value.trim() != "" {
        text = apply_tag_attr_patch(text, tag, "filename", value)
      }
    None => ()
  }
  text
}

///|
fn clean_plugin_parameter(
  extension : UrdfExtensionNode,
  parameter : UrdfPluginParameterPatch,
  issues : Array[UrdfEditorIssue],
) -> Result[UrdfPluginParameterPatch, UrdfEditError] {
  let clean = parameter.name.trim().to_owned()
  if clean == "" || !valid_extension_attr_name(clean) {
    Err(
      edit_error(
        "gazebo-plugin-parameter-name-invalid",
        extension.node_id,
        "gazebo plugin parameter name is invalid",
        issues,
      ),
    )
  } else {
    Ok({ name: clean, value: parameter.value })
  }
}

///|
fn plugin_parameter_tag(name : String, value : String) -> String {
  "<\{name}>\{escaped_text_value(value.trim().to_owned())}</\{name}>"
}

///|
fn self_closing_plugin_block(
  source : String,
  plugin : UrdfPluginTarget,
  open_text : String,
  parameters : Array[UrdfPluginParameterPatch],
) -> String {
  let indent = indentation_before(source, plugin.open_tag.span.start)
  let child_indent = "\{indent}  "
  let lines : Array[String] = [
    if open_text.trim().has_suffix("/>") {
      open_text[0:open_text.length() - 2].trim_end().to_owned() + ">"
    } else {
      open_text
    },
  ]
  for parameter in parameters {
    let clean_value = parameter.value.trim().to_owned()
    if clean_value != "" {
      lines.push(
        "\{child_indent}\{plugin_parameter_tag(parameter.name, clean_value)}",
      )
    }
  }
  lines.push("\{indent}</plugin>")
  lines.join("\n")
}

///|
fn plugin_parameter_replacement(
  source : String,
  plugin : UrdfPluginTarget,
  parameter_name : String,
  open_text : String,
  parameter_value : String,
) -> Result[SourceReplacement?, UrdfEditError] {
  let clean_value = parameter_value.trim().to_owned()
  match find_text_element_target(source, plugin.source_span, parameter_name) {
    Some(target) =>
      if clean_value == "" {
        let remove_span = match target.close_span {
          Some(close_span) => span(target.open_tag.span.start, close_span.end)
          None => target.open_tag.span
        }
        Ok(Some({ span: remove_span, text: "" }))
      } else {
        match target.value_span {
          Some(value_span) =>
            Ok(
              Some({ span: value_span, text: escaped_text_value(clean_value) }),
            )
          None =>
            Ok(
              Some({
                span: target.open_tag.span,
                text: plugin_parameter_tag(parameter_name, clean_value),
              }),
            )
        }
      }
    None =>
      if clean_value == "" {
        Ok(None)
      } else {
        match plugin.close_span {
          Some(close_span) =>
            Ok(
              Some({
                span: empty_span(close_span.start),
                text: child_insert_text(
                  source,
                  plugin.open_tag.span,
                  plugin_parameter_tag(parameter_name, clean_value),
                ),
              }),
            )
          None =>
            Ok(
              Some({
                span: plugin.source_span,
                text: self_closing_plugin_block(source, plugin, open_text, [
                  { name: parameter_name, value: clean_value },
                ]),
              }),
            )
        }
      }
  }
}

///|
pub fn update_gazebo_plugin(
  source : String,
  extension_node_id : String,
  patch : UrdfGazeboPluginPatch,
) -> Result[UrdfEditResult, UrdfEditError] {
  let doc = parse_document(source)
  let extension = match find_extension(doc, extension_node_id) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "extension-not-found",
          extension_node_id,
          "cannot update missing extension `\{extension_node_id}`",
          doc.issues,
        ),
      )
  }
  if extension.kind != "gazebo" && extension.kind != "plugin" {
    return Err(
      edit_error(
        "gazebo-plugin-extension-required",
        extension_node_id,
        "typed gazebo plugin edits require a gazebo or plugin extension node",
        doc.issues,
      ),
    )
  }
  let plugin = match plugin_target_from_extension(source, extension) {
    Some(value) => value
    None =>
      return Err(
        edit_error(
          "gazebo-plugin-missing",
          extension_node_id,
          "selected gazebo extension does not contain a plugin tag",
          doc.issues,
        ),
      )
  }
  if patch.plugin_name is None &&
    patch.plugin_filename is None &&
    patch.parameters.is_empty() {
    return Ok(
      successful_edit("update-gazebo-plugin", extension_node_id, source, false),
    )
  }
  let parameters : Array[UrdfPluginParameterPatch] = []
  for parameter in patch.parameters {
    match clean_plugin_parameter(extension, parameter, doc.issues) {
      Ok(clean) => parameters.push(clean)
      Err(error) => return Err(error)
    }
  }
  let open_text = patched_plugin_open_text(source, plugin, patch)
  if plugin.close_span is None && !parameters.is_empty() {
    let mut has_addition = false
    for parameter in parameters {
      if parameter.value.trim() != "" {
        has_addition = true
      }
    }
    if has_addition {
      let next_source = apply_replacements(source, [
        {
          span: plugin.source_span,
          text: self_closing_plugin_block(source, plugin, open_text, parameters),
        },
      ])
      return Ok(
        successful_edit(
          "update-gazebo-plugin",
          extension_node_id,
          next_source,
          next_source != source,
        ),
      )
    }
  }
  let replacements : Array[SourceReplacement] = []
  if open_text !=
    source[plugin.open_tag.span.start:plugin.open_tag.span.end].to_owned() {
    replacements.push({ span: plugin.open_tag.span, text: open_text })
  }
  for parameter in parameters {
    match
      plugin_parameter_replacement(
        source,
        plugin,
        parameter.name,
        open_text,
        parameter.value,
      ) {
      Ok(Some(replacement)) => replacements.push(replacement)
      Ok(None) => ()
      Err(error) => return Err(error)
    }
  }
  let next_source = apply_replacements(source, replacements)
  Ok(
    successful_edit(
      "update-gazebo-plugin",
      extension_node_id,
      next_source,
      next_source != source,
    ),
  )
}
