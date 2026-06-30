///|
struct UrdfEditorPluginParameterForm {
  name : String
  value : String
} derive(Debug, Eq)

///|
fn clean_plugin_parameter_tag_name(raw : String) -> String {
  let tag = raw.trim()
  let name = match tag.split_once(" ") {
    Some((value, _)) => value.trim().to_owned()
    None => tag.to_owned()
  }
  if name.has_prefix("/") || name.has_prefix("!") || name.has_prefix("?") ||
    name.has_suffix("/") {
    ""
  } else {
    name
  }
}

///|
fn plugin_parameters_from_extension(
  source : String,
  extension : @urdf_editor.UrdfExtensionNode,
) -> Array[UrdfEditorPluginParameterForm] {
  let parameters : Array[UrdfEditorPluginParameterForm] = []
  let mut remaining = first_plugin_body(source, extension)
  while remaining != "" {
    match remaining.split_once("<") {
      Some((_, after_lt)) =>
        match after_lt.split_once(">") {
          Some((raw_tag, after_open)) => {
            let name = clean_plugin_parameter_tag_name(raw_tag.to_owned())
            if name == "" {
              remaining = after_open.to_owned()
            } else {
              match after_open.split_once("</\{name}>") {
                Some((value, rest)) => {
                  parameters.push({ name, value: value.trim().to_owned() })
                  remaining = rest.to_owned()
                }
                None => remaining = ""
              }
            }
          }
          None => remaining = ""
        }
      None => remaining = ""
    }
  }
  parameters
}

///|
fn update_plugin_parameter_name(
  parameters : Array[UrdfEditorPluginParameterForm],
  target_index : Int,
  value : String,
) -> Array[UrdfEditorPluginParameterForm] {
  let next : Array[UrdfEditorPluginParameterForm] = []
  for index in 0..<parameters.length() {
    let parameter = parameters[index]
    if index == target_index {
      next.push({ ..parameter, name: value })
    } else {
      next.push(parameter)
    }
  }
  next
}

///|
fn update_plugin_parameter_value(
  parameters : Array[UrdfEditorPluginParameterForm],
  target_index : Int,
  value : String,
) -> Array[UrdfEditorPluginParameterForm] {
  let next : Array[UrdfEditorPluginParameterForm] = []
  for index in 0..<parameters.length() {
    let parameter = parameters[index]
    if index == target_index {
      next.push({ ..parameter, value })
    } else {
      next.push(parameter)
    }
  }
  next
}

///|
fn remove_plugin_parameter(
  parameters : Array[UrdfEditorPluginParameterForm],
  target_index : Int,
) -> Array[UrdfEditorPluginParameterForm] {
  let next : Array[UrdfEditorPluginParameterForm] = []
  for index in 0..<parameters.length() {
    if index != target_index {
      next.push(parameters[index])
    }
  }
  next
}

///|
fn append_plugin_parameter(
  parameters : Array[UrdfEditorPluginParameterForm],
) -> Array[UrdfEditorPluginParameterForm] {
  let next : Array[UrdfEditorPluginParameterForm] = []
  for parameter in parameters {
    next.push(parameter)
  }
  next.push({ name: "", value: "" })
  next
}

///|
fn first_plugin_parameter_form_name(
  parameters : Array[UrdfEditorPluginParameterForm],
) -> String {
  if parameters.is_empty() {
    ""
  } else {
    parameters[0].name
  }
}

///|
fn first_plugin_parameter_form_value(
  parameters : Array[UrdfEditorPluginParameterForm],
) -> String {
  if parameters.is_empty() {
    ""
  } else {
    parameters[0].value
  }
}

///|
fn plugin_parameter_value_or_default(
  parameters : Array[UrdfEditorPluginParameterForm],
  name : String,
  default_value : String,
) -> String {
  for parameter in parameters {
    if parameter.name == name {
      return parameter.value
    }
  }
  default_value
}

///|
fn plugin_parameters_from_schema(
  schema : @urdf_editor.UrdfPluginSchema,
  existing : Array[UrdfEditorPluginParameterForm],
) -> Array[UrdfEditorPluginParameterForm] {
  let parameters : Array[UrdfEditorPluginParameterForm] = []
  for parameter_schema in schema.parameters {
    parameters.push({
      name: parameter_schema.name,
      value: plugin_parameter_value_or_default(
        existing,
        parameter_schema.name,
        parameter_schema.default_value,
      ),
    })
  }
  parameters
}

///|
fn plugin_parameter_schema_for_name(
  schema : @urdf_editor.UrdfPluginSchema,
  name : String,
) -> @urdf_editor.UrdfPluginParameterSchema? {
  for parameter_schema in schema.parameters {
    if parameter_schema.name == name {
      return Some(parameter_schema)
    }
  }
  None
}

///|
fn plugin_parameter_form_index(
  parameters : Array[UrdfEditorPluginParameterForm],
  name : String,
) -> Int? {
  for index in 0..<parameters.length() {
    if parameters[index].name == name {
      return Some(index)
    }
  }
  None
}

///|
fn plugin_parameter_has_schema_name(
  schema : @urdf_editor.UrdfPluginSchema,
  name : String,
) -> Bool {
  plugin_parameter_schema_for_name(schema, name) is Some(_)
}

///|
fn plugin_parameter_patches_from_form(
  parameters : Array[UrdfEditorPluginParameterForm],
) -> Array[@urdf_editor.UrdfPluginParameterPatch] {
  let patches : Array[@urdf_editor.UrdfPluginParameterPatch] = []
  for parameter in parameters {
    if parameter.name.trim() != "" {
      patches.push({ name: parameter.name, value: parameter.value })
    }
  }
  patches
}

///|
fn plugin_parameter_patches_from_model(
  model : AppModel,
) -> Array[@urdf_editor.UrdfPluginParameterPatch] {
  if model.urdf_editor_plugin_parameters.is_empty() {
    if model.urdf_editor_plugin_parameter_name.trim() == "" {
      []
    } else {
      [
        {
          name: model.urdf_editor_plugin_parameter_name,
          value: model.urdf_editor_plugin_parameter_value,
        },
      ]
    }
  } else {
    plugin_parameter_patches_from_form(model.urdf_editor_plugin_parameters)
  }
}

///|
fn active_plugin_schema(model : AppModel) -> @urdf_editor.UrdfPluginSchema? {
  @urdf_editor.suggested_gazebo_plugin_schema(
    model.urdf_editor_plugin_name,
    model.urdf_editor_plugin_filename,
  )
}

///|
fn plugin_schema_issues_for_model(
  model : AppModel,
) -> Array[@urdf_editor.UrdfPluginSchemaIssue] {
  match active_plugin_schema(model) {
    Some(schema) =>
      @urdf_editor.validate_gazebo_plugin_schema(
        schema,
        plugin_parameter_patches_from_model(model),
      )
    None => []
  }
}
