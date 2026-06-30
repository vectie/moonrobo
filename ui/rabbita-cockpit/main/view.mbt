///|
using @html {button, div, h1, h2, header, input, label, main_, p, section, span}

///|
using @rabbita {type Html}

///|
fn badge(label : String, tone : String) -> Html {
  span(class="badge \{tone}", label)
}

///|
fn metric(label : String, value : String) -> Html {
  div(class="metric", [
    span(class="metric-label", label),
    span(class="metric-value", value),
  ])
}

///|
fn key_value(label : String, value : String) -> Html {
  div(class="key-value", [
    span(class="key-label", label),
    span(class="key-text", value),
  ])
}

///|
fn compact_route(value : String) -> String {
  if value == "" {
    "-"
  } else {
    value
  }
}

///|
fn command_field(
  label_text : String,
  value : String,
  step : Int,
  on_change : (String) -> @rabbita.Cmd,
) -> Html {
  label(class="command-field", [
    span(class="key-label", label_text),
    input(input_type=Number, value~, step~, on_input=on_change),
  ])
}

///|
fn text_field(
  label_text : String,
  value : String,
  on_change : (String) -> @rabbita.Cmd,
) -> Html {
  label(class="command-field", [
    span(class="key-label", label_text),
    input(input_type=Text, value~, on_input=on_change),
  ])
}

///|
fn panel(
  klass : String,
  eyebrow : String,
  title : String,
  chip : Html,
  body : Array[Html],
) -> Html {
  section(class="panel \{klass}", [
    div(class="panel-heading", [
      div([p(class="eyebrow", eyebrow), h2(title)]),
      chip,
    ]),
    div(class="panel-body", body),
  ])
}

///|
fn pose_class(joint : @cockpit.CockpitViewportJoint) -> String {
  if !joint.mapped {
    "missing"
  } else if joint.limit_state == "below-limit" ||
    joint.limit_state == "above-limit" {
    "error"
  } else {
    match joint.error {
      Some(_) => "error"
      None =>
        if joint.position > 0.05 {
          "positive"
        } else if joint.position < -0.05 {
          "negative"
        } else {
          "neutral"
        }
    }
  }
}

///|
fn viewport_issue_rows(viewport : @cockpit.CockpitModelViewport) -> Array[Html] {
  let rows : Array[Html] = []
  for issue in viewport.issues {
    rows.push(p(class="viewport-issue", issue))
  }
  rows
}

///|
fn viewport_joint_rows(viewport : @cockpit.CockpitModelViewport) -> Array[Html] {
  let rows : Array[Html] = []
  for joint in viewport.joints {
    rows.push(
      div(
        class="viewport-joint \{joint.role} \{joint.side} \{pose_class(joint)}",
        [
          span(class="viewport-joint-name", joint.name),
          span(
            class="viewport-joint-pose",
            "\{joint.model_joint_type} \{joint.parent_link}->\{joint.child_link} \{joint.limit_state}",
          ),
          span(class="viewport-joint-pose", "\{joint.position}"),
        ],
      ),
    )
  }
  rows
}

///|
fn viewport_link_rows(viewport : @cockpit.CockpitModelViewport) -> Array[Html] {
  let rows : Array[Html] = []
  for link in viewport.links {
    rows.push(
      div(class="viewport-link \{link.status}", [
        span(class="viewport-link-name", "\{link.depth} / \{link.name}"),
        span(
          class="viewport-link-parent",
          if link.parent_joint == "" {
            "root"
          } else {
            "\{link.parent_link} -> \{link.parent_joint}"
          },
        ),
        span(class="viewport-link-pose", "x \{link.x} y \{link.y} z \{link.z}"),
        span(class="viewport-link-transform", link.transform),
      ]),
    )
  }
  rows
}

///|
fn visual_size_text(visual : @cockpit.CockpitViewportVisual) -> String {
  if visual.size != "" {
    visual.size
  } else {
    match (visual.radius, visual.length) {
      (Some(radius), Some(length)) => "r \{radius} l \{length}"
      (Some(radius), None) => "r \{radius}"
      _ => visual.mesh_scale
    }
  }
}

///|
fn viewport_visual_rows(
  viewport : @cockpit.CockpitModelViewport,
) -> Array[Html] {
  let rows : Array[Html] = []
  for visual in viewport.visuals {
    rows.push(
      div(class="viewport-link \{visual.asset_status}", [
        span(
          class="viewport-link-name",
          "\{visual.index} / \{visual.link_name}",
        ),
        span(
          class="viewport-link-parent",
          "\{visual.geometry_kind} \{visual.asset_status}",
        ),
        span(
          class="viewport-link-pose",
          if visual.mesh_filename == "" {
            visual_size_text(visual)
          } else {
            visual.mesh_filename
          },
        ),
        span(class="viewport-link-transform", visual.resolved_mesh_path),
      ]),
    )
  }
  rows
}

///|
fn viewport_visual_instance_rows(
  viewport : @cockpit.CockpitModelViewport,
) -> Array[Html] {
  let rows : Array[Html] = []
  for item in viewport.visual_instances {
    rows.push(
      div(class="viewport-link \{item.link_status}", [
        span(class="viewport-link-name", "\{item.index} / \{item.link_name}"),
        span(
          class="viewport-link-parent",
          "\{item.geometry_kind} \{item.link_status}",
        ),
        span(class="viewport-link-pose", "x \{item.x} y \{item.y} z \{item.z}"),
        span(class="viewport-link-transform", "world visual instance"),
      ]),
    )
  }
  rows
}

///|
fn render_viewport_body(viewport : @cockpit.CockpitModelViewport) -> Html {
  div(class="robot-viewport", [
    div(class="moonrobo-mesh-viewer", [
      div(class="mesh-viewer-status", "Loading mech"),
    ]),
    div(class="viewport-summary", [
      key_value("Source", viewport.source_path),
      key_value("Renderer", viewport.renderer),
      key_value("Root Link", viewport.root_link),
      div(class="metric-grid viewport-metrics", [
        metric(
          "Mapped",
          "\{viewport.mapped_joints}/\{viewport.declared_joints}",
        ),
        metric("URDF", "\{viewport.model_joints}/\{viewport.model_links}"),
        metric("Links", "\{viewport.simulated_links}/\{viewport.model_links}"),
        metric("Visuals", "\{viewport.visual_geometries}"),
        metric(
          "Meshes",
          "\{viewport.resolved_meshes}/\{viewport.mesh_geometries}",
        ),
        metric(
          "Model Map",
          "\{viewport.model_mapped_joints}/\{viewport.declared_joints}",
        ),
        metric("Telemetry", "\{viewport.telemetry_joints}"),
        metric("Issues", "\{viewport.issue_count}"),
      ]),
      div(class="viewport-issues", viewport_issue_rows(viewport)),
      div(class="viewport-links", viewport_visual_rows(viewport)),
      div(class="viewport-links", viewport_visual_instance_rows(viewport)),
      div(class="viewport-links", viewport_link_rows(viewport)),
    ]),
  ])
}

///|
fn render_robot(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let robot = snapshot.robot
  panel(
    "robot-panel",
    "RoboBook",
    robot.label,
    badge(ready_label(robot.ready), status_tone(ready_label(robot.ready))),
    [
      key_value("Robot ID", robot.robot_id),
      key_value("Platform", robot.platform),
      key_value("Model", robot.model_primary),
      key_value("Root", robot.root),
      div(class="metric-grid", [
        metric("Joints", "\{robot.joints}"),
        metric("Sensors", "\{robot.sensors}"),
        metric("Caps", "\{robot.capabilities}"),
      ]),
    ],
  )
}

///|
fn capability_rows(snapshot : @cockpit.CockpitSnapshot) -> Array[Html] {
  let rows : Array[Html] = []
  for item in snapshot.product_status.capabilities {
    rows.push(
      key_value(
        item.label,
        if item.ready {
          "ready"
        } else {
          "next: \{compact_route(item.next_route)}"
        },
      ),
    )
  }
  rows
}

///|
fn render_product_status(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let status = snapshot.product_status
  panel(
    "product-status-panel",
    "Moonrobo Loop",
    "Physical Agent Progress",
    badge(status.status, if status.ready { "success" } else { "accent" }),
    [
      div(class="metric-grid", [
        metric("Complete", "\{status.completed_count}/\{status.total_count}"),
        metric("Progress", "\{status.percent}%"),
      ]),
      key_value("Next", compact_route(status.next_route)),
      key_value("Message", status.message),
      div(class="capability-list", capability_rows(snapshot)),
    ],
  )
}

///|
fn urdf_import_button_label(model : AppModel) -> String {
  if model.importing_urdf_model {
    "Importing..."
  } else {
    "Import URDF"
  }
}

///|
fn render_urdf_import(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  let latest_rows = match model.latest_urdf_import {
    Some(result) =>
      [
        key_value("Imported Model", result.model_primary),
        key_value("Imported Robot", result.robot_name),
        key_value("Imported Meshes", "\{result.mesh_count}"),
      ]
    None => []
  }
  div(
    class="urdf-import",
    [
      div(class="urdf-import-row", [
        text_field("URDF Source", model.urdf_import_source, value => {
          dispatch(UpdateUrdfImportSource(value))
        }),
        button(
          class="command-button primary",
          type_="button",
          disabled=model.importing_urdf_model || model.loading,
          on_click=dispatch(ImportUrdfModel),
          urdf_import_button_label(model),
        ),
      ]),
      p(class="detail-copy intent-status", model.urdf_import_status),
      ..latest_rows,
    ],
  )
}

///|
fn urdf_editor_refresh_button_label(model : AppModel) -> String {
  if model.loading_urdf_editor_document {
    "Loading..."
  } else {
    "Refresh Document"
  }
}

///|
fn urdf_editor_preview_button_label(model : AppModel) -> String {
  if model.submitting_urdf_editor_edit {
    "Submitting..."
  } else {
    "Preview Edit"
  }
}

///|
fn urdf_editor_save_button_label(model : AppModel) -> String {
  if model.submitting_urdf_editor_edit {
    "Saving..."
  } else {
    "Save Edit"
  }
}

///|
fn urdf_editor_revert_button_label(model : AppModel) -> String {
  if model.reverting_urdf_editor_edit {
    "Reverting..."
  } else {
    "Revert Latest"
  }
}

///|
fn issue_severity_text(severity : @urdf_editor.UrdfEditorSeverity) -> String {
  match severity {
    @urdf_editor.Info => "info"
    @urdf_editor.Warning => "warning"
    @urdf_editor.Error => "error"
  }
}

///|
fn urdf_editor_issue_rows(
  issues : Array[@urdf_editor.UrdfEditorIssue],
) -> Array[Html] {
  let rows : Array[Html] = []
  let mut count = 0
  for issue in issues {
    if count < 6 {
      rows.push(
        div(class="urdf-editor-issue \{issue_severity_text(issue.severity)}", [
          span(class="urdf-editor-node-name", issue.code),
          span(class="urdf-editor-node-detail", issue.node_id),
          span(class="urdf-editor-node-detail", issue.message),
        ]),
      )
      count += 1
    }
  }
  rows
}

///|
fn urdf_editor_selected_node_id(model : AppModel) -> String {
  if model.urdf_editor_selected_node_id == "" {
    "robot"
  } else {
    model.urdf_editor_selected_node_id
  }
}

///|
fn urdf_editor_component_row_class(
  model : AppModel,
  row : @urdf_editor.UrdfEditorComponentRow,
) -> String {
  let selected = if row.node_id == urdf_editor_selected_node_id(model) {
    " selected"
  } else {
    ""
  }
  let issue = if row.issue_count > 0 { " warning" } else { "" }
  "urdf-editor-tree-row \{row.kind}\{selected}\{issue}"
}

///|
fn urdf_editor_component_rows(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
  rows : Array[@urdf_editor.UrdfEditorComponentRow],
) -> Array[Html] {
  let items : Array[Html] = []
  for row in rows {
    items.push(
      button(
        class=urdf_editor_component_row_class(model, row),
        type_="button",
        on_click=dispatch(SelectUrdfEditorNode(row.node_id)),
        "\{row.kind}: \{row.label}  \{row.detail}",
      ),
    )
  }
  items
}

///|
fn urdf_editor_field_rows(
  fields : Array[@urdf_editor.UrdfEditorField],
) -> Array[Html] {
  let rows : Array[Html] = []
  for item in fields {
    rows.push(
      div(
        class=if item.editable {
          "urdf-editor-field editable"
        } else {
          "urdf-editor-field"
        },
        [
          span(class="key-label", item.name),
          span(class="key-text", compact_route(item.value)),
          if item.command == "" {
            span(class="urdf-editor-command-chip", "")
          } else {
            span(class="urdf-editor-command-chip", item.command)
          },
        ],
      ),
    )
  }
  rows
}

///|
fn render_urdf_editor_inspector(
  model : AppModel,
  document : @urdf_editor.UrdfDocument,
) -> Html {
  match
    @urdf_editor.select_component(document, urdf_editor_selected_node_id(model)) {
    Some(detail) =>
      div(class="urdf-editor-inspector", [
        key_value("Selected", "\{detail.kind}: \{detail.label}"),
        p(class="detail-copy", detail.summary),
        div(
          class="urdf-editor-field-list",
          urdf_editor_field_rows(detail.fields),
        ),
        div(class="urdf-editor-node-list", [
          p(class="detail-copy", "Supported Commands"),
          if detail.commands.is_empty() {
            p(class="detail-copy", "No source edit command yet")
          } else {
            p(class="detail-copy", detail.commands.join(", "))
          },
        ]),
        div(
          class="urdf-editor-node-list",
          [
            p(class="detail-copy", "Selection Diagnostics"),
            ..if detail.issues.is_empty() {
              [p(class="detail-copy", "No selection diagnostics")]
            } else {
              urdf_editor_issue_rows(detail.issues)
            },
          ],
        ),
      ])
    None =>
      div(class="urdf-editor-inspector", [
        p(class="detail-copy", "Select a URDF component."),
      ])
  }
}

///|
fn render_urdf_editor_document(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Array[Html] {
  match model.latest_urdf_editor_document {
    Some(result) => {
      let document = result.document
      [
        div(class="metric-grid urdf-editor-metrics", [
          metric("Links", "\{document.links.length()}"),
          metric("Joints", "\{document.joints.length()}"),
          metric("Visuals", "\{document.visuals.length()}"),
          metric("Collisions", "\{document.collisions.length()}"),
          metric("Inertials", "\{document.inertials.length()}"),
          metric("Materials", "\{document.materials.length()}"),
        ]),
        key_value("Active Model", result.model_primary),
        key_value("Robot Name", compact_route(document.robot_name)),
        key_value("Session Selection", result.session.selected_node_id),
        key_value(
          "Session History",
          "undo \{result.session.past_count} redo \{result.session.future_count}",
        ),
        div(class="urdf-editor-selection-grid", [
          div(
            class="urdf-editor-tree",
            [
              p(class="detail-copy", "Model Tree"),
              ..urdf_editor_component_rows(dispatch, model, result.components),
            ],
          ),
          render_urdf_editor_inspector(model, document),
        ]),
        div(
          class="urdf-editor-node-list",
          [
            p(class="detail-copy", "Diagnostics"),
            ..if document.issues.is_empty() {
              [p(class="detail-copy", "No document diagnostics")]
            } else {
              urdf_editor_issue_rows(document.issues)
            },
          ],
        ),
      ]
    }
    None => [p(class="detail-copy", "Load the active RoboBook URDF document.")]
  }
}

///|
fn render_urdf_editor_result(model : AppModel) -> Array[Html] {
  match model.latest_urdf_editor_edit {
    Some(result) => {
      let receipt = match result.receipt {
        Some(value) =>
          [
            key_value("Receipt", value.receipt_path),
            key_value("Before Digest", value.before_digest),
            key_value("After Digest", value.after_digest),
            key_value("Diff", value.diff_summary),
            key_value("Before Source", value.before_source_path),
            key_value("After Source", value.after_source_path),
          ]
        None => []
      }
      let revert = match model.latest_urdf_editor_revert {
        Some(value) =>
          [
            key_value("Latest Revert", value.message),
            key_value("Restored Source", value.source_path),
            key_value("Revert Before", value.before_digest),
            key_value("Revert After", value.after_digest),
          ]
        None => []
      }
      [
        key_value("Latest Edit", result.edit.command),
        key_value("Target", result.edit.target),
        key_value("Changed", "\{result.edit.changed}"),
        key_value("Persisted", "\{result.persisted}"),
        key_value("Session Selection", result.session.selected_node_id),
        key_value(
          "Session Undo/Redo",
          "\{result.session.can_undo} / \{result.session.can_redo}",
        ),
        p(class="detail-copy intent-status", result.edit.message),
        div(
          class="urdf-editor-node-list",
          [
            p(class="detail-copy", "Edit Diagnostics"),
            ..if result.edit.issues.is_empty() {
              [p(class="detail-copy", "No edit diagnostics")]
            } else {
              urdf_editor_issue_rows(result.edit.issues)
            },
          ],
        ),
        ..receipt,
        ..revert,
      ]
    }
    None =>
      match model.latest_urdf_editor_revert {
        Some(value) =>
          [
            key_value("Latest Revert", value.message),
            key_value("Restored Source", value.source_path),
            key_value("Revert Before", value.before_digest),
            key_value("Revert After", value.after_digest),
          ]
        None => []
      }
  }
}

///|
fn render_urdf_editor(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  div(
    class="urdf-editor-lane",
    [
      div(class="urdf-editor-actions", [
        button(
          class="command-button",
          type_="button",
          disabled=model.loading_urdf_editor_document || model.loading,
          on_click=dispatch(RefreshUrdfEditorDocument),
          urdf_editor_refresh_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.submitting_urdf_editor_edit || model.loading,
          on_click=dispatch(PreviewUrdfEditorEdit),
          urdf_editor_preview_button_label(model),
        ),
        button(
          class="command-button primary",
          type_="button",
          disabled=model.submitting_urdf_editor_edit || model.loading,
          on_click=dispatch(SaveUrdfEditorEdit),
          urdf_editor_save_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.reverting_urdf_editor_edit || model.loading,
          on_click=dispatch(RevertUrdfEditorEdit),
          urdf_editor_revert_button_label(model),
        ),
      ]),
      p(class="detail-copy intent-status", model.urdf_editor_status),
      div(class="urdf-editor-form", [
        text_field("Command", model.urdf_editor_command, value => {
          dispatch(UpdateUrdfEditorCommand(value))
        }),
        text_field("Joint", model.urdf_editor_joint_name, value => {
          dispatch(UpdateUrdfEditorJointName(value))
        }),
        text_field("Link", model.urdf_editor_link_name, value => {
          dispatch(UpdateUrdfEditorLinkName(value))
        }),
        text_field("New Name", model.urdf_editor_new_name, value => {
          dispatch(UpdateUrdfEditorNewName(value))
        }),
        command_field("Visual Index", model.urdf_editor_visual_index, 1, value => {
          dispatch(UpdateUrdfEditorVisualIndex(value))
        }),
        command_field("Collision Index", model.urdf_editor_collision_index, 1, value => {
          dispatch(UpdateUrdfEditorCollisionIndex(value))
        }),
        text_field("XYZ", model.urdf_editor_xyz, value => {
          dispatch(UpdateUrdfEditorXyz(value))
        }),
        text_field("RPY", model.urdf_editor_rpy, value => {
          dispatch(UpdateUrdfEditorRpy(value))
        }),
        command_field("Lower", model.urdf_editor_limit_lower, 1, value => {
          dispatch(UpdateUrdfEditorLimitLower(value))
        }),
        command_field("Upper", model.urdf_editor_limit_upper, 1, value => {
          dispatch(UpdateUrdfEditorLimitUpper(value))
        }),
        command_field("Effort", model.urdf_editor_limit_effort, 1, value => {
          dispatch(UpdateUrdfEditorLimitEffort(value))
        }),
        command_field("Velocity", model.urdf_editor_limit_velocity, 1, value => {
          dispatch(UpdateUrdfEditorLimitVelocity(value))
        }),
        command_field("Mass", model.urdf_editor_inertial_mass, 1, value => {
          dispatch(UpdateUrdfEditorInertialMass(value))
        }),
        command_field("Ixx", model.urdf_editor_inertial_ixx, 1, value => {
          dispatch(UpdateUrdfEditorInertialIxx(value))
        }),
        command_field("Ixy", model.urdf_editor_inertial_ixy, 1, value => {
          dispatch(UpdateUrdfEditorInertialIxy(value))
        }),
        command_field("Ixz", model.urdf_editor_inertial_ixz, 1, value => {
          dispatch(UpdateUrdfEditorInertialIxz(value))
        }),
        command_field("Iyy", model.urdf_editor_inertial_iyy, 1, value => {
          dispatch(UpdateUrdfEditorInertialIyy(value))
        }),
        command_field("Iyz", model.urdf_editor_inertial_iyz, 1, value => {
          dispatch(UpdateUrdfEditorInertialIyz(value))
        }),
        command_field("Izz", model.urdf_editor_inertial_izz, 1, value => {
          dispatch(UpdateUrdfEditorInertialIzz(value))
        }),
        text_field("Material RGBA", model.urdf_editor_material_color_rgba, value => {
          dispatch(UpdateUrdfEditorMaterialColorRgba(value))
        }),
        text_field("Material Texture", model.urdf_editor_material_texture, value => {
          dispatch(UpdateUrdfEditorMaterialTexture(value))
        }),
        text_field("Geometry", model.urdf_editor_geometry_kind, value => {
          dispatch(UpdateUrdfEditorGeometryKind(value))
        }),
        text_field("Mesh", model.urdf_editor_mesh_filename, value => {
          dispatch(UpdateUrdfEditorMeshFilename(value))
        }),
        text_field("Mesh Scale", model.urdf_editor_mesh_scale, value => {
          dispatch(UpdateUrdfEditorMeshScale(value))
        }),
        text_field("Size", model.urdf_editor_geometry_size, value => {
          dispatch(UpdateUrdfEditorGeometrySize(value))
        }),
        command_field("Radius", model.urdf_editor_geometry_radius, 1, value => {
          dispatch(UpdateUrdfEditorGeometryRadius(value))
        }),
        command_field("Length", model.urdf_editor_geometry_length, 1, value => {
          dispatch(UpdateUrdfEditorGeometryLength(value))
        }),
      ]),
      ..render_urdf_editor_document(dispatch, model),
      ..render_urdf_editor_result(model),
    ],
  )
}

///|
fn render_twin(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  let snapshot = model.snapshot
  let viewport = snapshot.model_viewport
  panel(
    "twin-panel",
    "URDF Viewport",
    "Embodiment Simulation",
    badge(viewport.status, status_tone(viewport.status)),
    [
      render_urdf_import(dispatch, model),
      render_urdf_editor(dispatch, model),
      render_viewport_body(viewport),
      div(class="joint-strip viewport-joints", viewport_joint_rows(viewport)),
    ],
  )
}

///|
fn runtime_launch_button_label(model : AppModel) -> String {
  if model.preparing_runtime_launch {
    "Preparing..."
  } else {
    "Prepare Launch"
  }
}

///|
fn runtime_start_button_label(model : AppModel) -> String {
  if model.starting_runtime {
    "Starting..."
  } else {
    "Start Runtime"
  }
}

///|
fn runtime_stop_button_label(model : AppModel) -> String {
  if model.stopping_runtime {
    "Stopping..."
  } else {
    "Stop Runtime"
  }
}

///|
fn runtime_emergency_stop_button_label(model : AppModel) -> String {
  if model.stopping_emergency {
    "Stopping Now..."
  } else {
    "Emergency Stop"
  }
}

///|
fn platform_bootstrap_button_label(model : AppModel) -> String {
  if model.bootstrapping_platform {
    "Bootstrapping..."
  } else {
    "Bootstrap Platform"
  }
}

///|
fn platform_runtime_proof_button_label(model : AppModel) -> String {
  if model.proving_runtime {
    "Proving..."
  } else {
    "Prove Runtime"
  }
}

///|
fn platform_loop_proof_button_label(model : AppModel) -> String {
  if model.proving_loop {
    "Proving Loop..."
  } else {
    "Prove Loop"
  }
}

///|
fn platform_proof_session_button_label(model : AppModel) -> String {
  if model.running_proof_session {
    "Running Session..."
  } else {
    "Proof Session"
  }
}

///|
fn render_runtime_log(model : AppModel) -> Html {
  match model.latest_runtime_log {
    Some(log) =>
      div(class="runtime-log", [
        key_value(
          "Log Path",
          if log.log_path == "" {
            "-"
          } else {
            log.log_path
          },
        ),
        key_value("Log Active", log.active),
        key_value("Log Running", log.running),
        key_value("Log Lines", "\{log.line_count} / \{log.max_lines}"),
        key_value("Log Truncated", log.truncated),
        div(
          class="runtime-log-tail",
          if log.tail == "" {
            model.runtime_log_status
          } else {
            log.tail
          },
        ),
      ])
    None =>
      div(class="runtime-log", [
        key_value("Log Path", "-"),
        div(class="runtime-log-tail", model.runtime_log_status),
      ])
  }
}

///|
fn render_bridge(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  let snapshot = model.snapshot
  let bridge = snapshot.bridge
  let sidecar = snapshot.sidecar
  let runtime = model.runtime_supervisor_status
  let health_rows = match model.latest_runtime_health {
    Some(health) =>
      [
        key_value("Health Path", health.latest_runtime_health_path),
        key_value("Health Record", health.runtime_health_path),
        key_value("Telemetry", health.telemetry_status),
        key_value("Telemetry OK", health.telemetry_ok),
        key_value("Frame", health.telemetry_frame_id),
        key_value("Message", health.telemetry_message),
        key_value("Persisted", health.persisted),
      ]
    None => [key_value("Health Path", "-")]
  }
  let validation_rows = match model.latest_runtime_validation {
    Some(validation) =>
      [
        key_value("Validation", model.runtime_validation_status),
        key_value("Live SDK Ready", validation.ready_for_live_sdk),
        key_value("Validation Report", validation.latest_report_path),
        key_value("Validation Record", validation.report_path),
        key_value("Calibration Plan", validation.latest_calibration_path),
        key_value("Calibration Record", validation.calibration_path),
        key_value(
          "Validation Checks",
          "\{validation.pass_count} pass / \{validation.fail_count} fail / \{validation.check_count} total",
        ),
        key_value("Validation Persisted", validation.persisted),
      ]
    None => [key_value("Validation", model.runtime_validation_status)]
  }
  let validation_session_rows = match model.latest_runtime_validation_session {
    Some(session) =>
      [
        key_value("Validation Session", model.runtime_validation_session_status),
        key_value("Session Status", session.status),
        key_value("Session Ready", session.ready_for_live_sdk),
        key_value("Session Persisted", session.persisted),
        key_value(
          "Session Samples",
          "\{session.ready_sample_count} ready / \{session.blocked_sample_count} blocked / \{session.sample_count} total",
        ),
        key_value("Mapping Proof", session.mapping_status),
        key_value("Mapping Stable", session.mapping_stable),
        key_value(
          "Mapping Samples",
          "\{session.mapping_matching_sample_count} matched / \{session.mapping_mismatch_sample_count} mismatch",
        ),
        key_value("Mapping Message", session.mapping_message),
        key_value("Required Samples", session.required_sample_count),
        key_value("First Blocker", session.first_blocker_code),
        key_value("Session Path", session.latest_session_path),
        key_value("Session Record", session.session_path),
        key_value("Calibration", session.calibration_status),
        key_value(
          "Calibration Actions",
          "\{session.calibration_blocking_action_count} blocking / \{session.calibration_action_count} total",
        ),
        key_value("Calibration Path", session.latest_calibration_path),
        key_value("Calibration Record", session.calibration_path),
      ]
    None =>
      [key_value("Validation Session", model.runtime_validation_session_status)]
  }
  panel(
    "bridge-panel",
    "Bridge",
    "Runtime Link",
    badge(runtime.status, status_tone(runtime.status)),
    [
      key_value("Bridge ID", bridge.bridge_id),
      key_value("Mode", bridge.mode),
      key_value("Sidecar", sidecar.sidecar_id),
      key_value("Command", sidecar.command_path),
      key_value("Runtime", runtime.status),
      key_value("Bridge URL", runtime.bridge_base_url),
      key_value("Processes", "\{runtime.processes.length()}"),
      key_value("Issues", "\{runtime.issues.length()}"),
      key_value("Health", model.runtime_health_status),
      ..health_rows,
      ..validation_rows,
      ..validation_session_rows,
      key_value(
        "Telemetry Age",
        "\{optional_int_label(bridge.telemetry_age_ms)} ms",
      ),
      div(
        class="freshness \{status_tone(if bridge.telemetry_stale { "stale" } else { "fresh" })}",
        freshness_label(bridge.telemetry_stale),
      ),
      div(class="freshness \{status_tone(sidecar.state)}", sidecar.detail),
      p(class="detail-copy intent-status", model.runtime_launch_status),
      render_runtime_log(model),
      div(class="command-actions", [
        button(
          class="command-button",
          type_="button",
          disabled=model.preparing_runtime_launch || model.loading,
          on_click=dispatch(PrepareRuntimeLaunch),
          runtime_launch_button_label(model),
        ),
        button(
          class="command-button primary",
          type_="button",
          disabled=model.starting_runtime || model.loading,
          on_click=dispatch(StartRuntime),
          runtime_start_button_label(model),
        ),
        button(
          class="command-button danger",
          type_="button",
          disabled=model.stopping_runtime || model.loading,
          on_click=dispatch(StopRuntime),
          runtime_stop_button_label(model),
        ),
        button(
          class="command-button danger",
          type_="button",
          disabled=model.stopping_emergency || model.loading,
          on_click=dispatch(EmergencyStopRuntime),
          runtime_emergency_stop_button_label(model),
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.validating_runtime_session || model.loading,
          on_click=dispatch(ValidateRuntimeSession),
          if model.validating_runtime_session {
            "Validating..."
          } else {
            "Validate Session"
          },
        ),
      ]),
    ],
  )
}

///|
fn render_safety(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  let snapshot = model.snapshot
  let safety = snapshot.safety
  panel(
    "safety-panel",
    "Safety Gate",
    "Command Review",
    badge(safety.decision, status_tone(safety.decision)),
    [
      key_value("Capability", safety.capability),
      key_value("Next Action", safety.next_action),
      key_value("Reason", safety.reason),
      div(class="command-editor", [
        command_field("X", model.walk_x, 1, value => {
          dispatch(UpdateWalkX(value))
        }),
        command_field("Yaw", model.walk_yaw, 1, value => {
          dispatch(UpdateWalkYaw(value))
        }),
        command_field("Duration ms", model.walk_duration_ms, 100, value => {
          dispatch(UpdateWalkDuration(value))
        }),
      ]),
      p(class="detail-copy", safety.detail),
      p(class="detail-copy intent-status", model.intent_status),
      div(class="evidence-strip", [
        key_value(
          "Dry Run",
          if model.dry_run_receipt_id == "" {
            "-"
          } else {
            model.dry_run_receipt_id
          },
        ),
        key_value(
          "Approval",
          if model.approval_id == "" {
            "-"
          } else {
            model.approval_id
          },
        ),
      ]),
      div(class="command-actions", [
        button(
          class="command-button primary",
          type_="button",
          disabled=model.evaluating || model.loading,
          on_click=dispatch(EvaluateWalk),
          evaluate_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.collecting_dry_run || model.loading,
          on_click=dispatch(CollectDryRun),
          dry_run_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.approving ||
            model.loading ||
            model.dry_run_receipt_id == "",
          on_click=dispatch(ApproveWalk),
          approval_button_label(model),
        ),
        button(
          class="command-button danger",
          type_="button",
          disabled=model.executing || model.loading || model.approval_id == "",
          on_click=dispatch(ExecuteWalk),
          execute_button_label(model),
        ),
      ]),
    ],
  )
}

///|
fn render_observation_result(result : ObservationRunResult?) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip observation-result", [
          key_value("Session", value.session_id),
          key_value("Frames", value.frame_count),
          key_value("Status", value.status),
          key_value("Latest Frame", value.latest_frame_id),
        ]),
        key_value("Resident", value.resident_availability),
      ]
    None =>
      [
        div(class="evidence-strip observation-result", [
          key_value("Session", "-"),
          key_value("Frames", "-"),
          key_value("Status", "-"),
          key_value("Latest Frame", "-"),
        ]),
      ]
  }
}

///|
fn task_message_reply(model : AppModel) -> String {
  match model.latest_task_message_status {
    Some(status) => status.message
    None =>
      match model.latest_task_message {
        Some(result) => result.message
        None => model.task_message_status
      }
  }
}

///|
fn render_task_conversation_turn(turn : TaskConversationTurn) -> Array[Html] {
  [
    div(class="task-turn user", [
      span(class="task-turn-label", "You"),
      p(class="task-turn-copy", turn.user_text),
    ]),
    div(class="task-turn robo", [
      span(class="task-turn-label", "Robo"),
      p(class="task-turn-copy", turn.robo_text),
      div(class="task-turn-meta", [
        key_value("Turn", turn.turn_id),
        key_value("Task", turn.task_id),
        key_value("Created", turn.created_at_ms),
        key_value("Class", turn.classification),
        key_value("Stage", turn.stage),
        key_value("Next", compact_route(turn.next_route)),
        key_value("Review", turn.requires_review),
        key_value("Physical", turn.physical_execution_allowed),
      ]),
    ]),
  ]
}

///|
fn render_persisted_task_conversation(
  conversation : TaskConversationResult,
) -> Array[Html] {
  let rows : Array[Html] = []
  for turn in conversation.turns {
    for item in render_task_conversation_turn(turn) {
      rows.push(item)
    }
  }
  [
    p(class="detail-copy intent-status", conversation.message),
    div(class="evidence-strip observation-result", [
      key_value("Turns", conversation.turn_count),
      key_value("Latest", conversation.latest_task_id),
    ]),
    div(class="task-conversation", rows),
  ]
}

///|
fn render_current_task_message_turn(model : AppModel) -> Array[Html] {
  let user_text = if model.task_message.trim().to_owned() == "" {
    "No message drafted"
  } else {
    model.task_message
  }
  let task_id = match model.latest_task_message {
    Some(result) => result.task_id
    None =>
      if model.focused_task_message_task_id == "" {
        "-"
      } else {
        model.focused_task_message_task_id
      }
  }
  let next_route = match model.latest_task_message_status {
    Some(status) => compact_route(status.next_route)
    None =>
      match model.latest_task_message {
        Some(result) => compact_route(result.next_route)
        None => "-"
      }
  }
  [
    div(class="task-conversation", [
      div(class="task-turn user", [
        span(class="task-turn-label", "You"),
        p(class="task-turn-copy", user_text),
      ]),
      div(class="task-turn robo", [
        span(class="task-turn-label", "Robo"),
        p(class="task-turn-copy", task_message_reply(model)),
        div(class="task-turn-meta", [
          key_value("Task", task_id),
          key_value("Next", next_route),
        ]),
      ]),
    ]),
  ]
}

///|
fn render_task_message_conversation(model : AppModel) -> Array[Html] {
  match model.latest_task_conversation {
    Some(conversation) if !conversation.turns.is_empty() =>
      render_persisted_task_conversation(conversation)
    _ =>
      [
        p(class="detail-copy intent-status", model.task_conversation_status),
        ..render_current_task_message_turn(model),
      ]
  }
}

///|
fn render_task_message_result(result : TaskMessageResult?) -> Array[Html] {
  match result {
    Some(value) => {
      let handoff_rows = match value.inline_handoff {
        Some(handoff) =>
          [
            div(class="evidence-strip work-metrics", [
              key_value("Handoff", handoff.status),
              key_value("Owner", handoff.next_owner),
              key_value("Kind", handoff.next_kind),
              key_value(
                "Loop",
                "\{handoff.loop_status} \{handoff.loop_percent}%",
              ),
            ]),
            key_value("Handoff Route", compact_route(handoff.next_route)),
          ]
        None => []
      }
      let proof_rows = match value.inline_loop_proof {
        Some(proof) =>
          [
            div(class="evidence-strip work-metrics", [
              key_value("Loop Proof", proof.status),
              key_value(
                "Checks",
                "\{proof.completed_count}/\{proof.total_count}",
              ),
              key_value("Progress", "\{proof.percent}%"),
              key_value("Proof Next", compact_route(proof.next_route)),
            ]),
          ]
        None => []
      }
      let live_rows = match value.inline_live_readiness {
        Some(live) =>
          [
            div(class="evidence-strip work-metrics", [
              key_value("Live", live.status),
              key_value("Routine", live.can_submit_gateway_command),
              key_value("Proof Session", live.can_run_proof_session),
              key_value("Feedback Closed", live.proof_session_feedback_closed),
            ]),
          ]
        None => []
      }
      [
        div(class="evidence-strip observation-result", [
          key_value("Task", value.task_id),
          key_value("Class", value.classification),
          key_value("Session", value.session_id),
          key_value("Next", value.next_route),
          key_value("Review", value.requires_review),
          key_value("Cards", value.card_count),
          key_value("Resident", value.resident_availability),
        ]),
        key_value("Memory", value.memory_path),
        ..handoff_rows,
        ..proof_rows,
        ..live_rows,
      ]
    }
    None =>
      [
        div(class="evidence-strip observation-result", [
          key_value("Task", "-"),
          key_value("Class", "-"),
          key_value("Session", "-"),
          key_value("Next", "-"),
          key_value("Review", "-"),
          key_value("Cards", "-"),
          key_value("Resident", "-"),
        ]),
      ]
  }
}

///|
fn render_robo_session(model : AppModel) -> Array[Html] {
  match model.latest_robo_session {
    Some(value) =>
      [
        div(class="robo-result robo-session-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.session.session_id),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Stage", value.session.stage),
            key_value(
              "Task",
              if value.session.task_id == "" {
                "-"
              } else {
                value.session.task_id
              },
            ),
            key_value("Loops", value.loop_count),
            key_value("Turns", value.turn_count),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Has Task", value.has_task_message),
            key_value("Accepts Tasks", value.handoff.accepts_task_messages),
            key_value("Owner", value.handoff.next_owner),
            key_value("Handoff", value.handoff.status),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Robot", value.mapping.robot_id),
            key_value("Bridge", value.mapping.bridge_id),
            key_value("Runtime", value.mapping.runtime_status),
            key_value("Mapped", value.mapping.mapped),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Reachable", value.mapping.reachable),
            key_value("Availability", value.mapping.availability),
            key_value("Execution", value.mapping.latest_execution_status),
            key_value(
              "Verified",
              "\{value.execution_proof.verified_count} / \{value.execution_proof.execution_count}",
            ),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Can Act", value.handoff.can_act),
            key_value("Queue", value.handoff.queue_count),
            key_value("Kind", value.handoff.next_kind),
            key_value("Next", compact_route(value.handoff.next_route)),
            key_value("Target", compact_route(value.handoff.target_route)),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Method", value.handoff.next_method),
            key_value("Needs Operator", value.handoff.needs_operator),
            key_value("Needs MoonClaw", value.handoff.needs_moonclaw),
            key_value("Physical", value.handoff.physical_execution_allowed),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Readiness", value.handoff.readiness_status),
            key_value("Loop", value.handoff.loop_status),
            key_value("Loop %", value.handoff.loop_percent),
            key_value("Title", value.handoff.next_title),
          ]),
          p(class="detail-copy review-summary", value.session.latest_user_text),
          p(class="detail-copy review-summary", value.session.latest_robo_text),
        ]),
      ]
    None => [p(class="detail-copy intent-status", model.robo_session_status)]
  }
}

///|
fn render_robo_turn(model : AppModel) -> Array[Html] {
  match model.latest_robo_turn {
    Some(value) =>
      [
        div(class="robo-result robo-turn-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.turn_id),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Task", value.task_id),
            key_value("Accepted", value.accepted),
            key_value("MoonClaw", value.moonclaw_handoff),
            key_value("Can Act", value.can_act),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Next Owner", value.next_owner),
            key_value("Next Kind", value.next_kind),
            key_value("Needs MoonClaw", value.needs_moonclaw),
            key_value("Next Route", compact_route(value.next_route)),
          ]),
          key_value("Turn Path", value.turn_path),
        ]),
      ]
    None => []
  }
}

///|
fn render_robo_loop(model : AppModel) -> Array[Html] {
  match model.latest_robo_loop {
    Some(value) =>
      [
        div(class="robo-result robo-loop-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.loop_id),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Accepted", value.accepted),
            key_value("Next Owner", value.final_owner),
            key_value("Next Kind", value.final_kind),
            key_value("Next Route", compact_route(value.final_route)),
          ]),
          key_value("Loop Path", value.loop_path),
        ]),
      ]
    None => []
  }
}

///|
fn render_robo_loop_history_row(loop_run : RoboLoopResult) -> Html {
  div(class="task-message-row robo-loop-row", [
    div(class="task-message-row-heading", [
      span(class="task-message-id", loop_run.loop_id),
      span(class="badge \{status_tone(loop_run.status)}", loop_run.status),
    ]),
    div(class="task-message-meta", [
      key_value("Accepted", loop_run.accepted),
      key_value("Owner", loop_run.final_owner),
      key_value("Kind", loop_run.final_kind),
      key_value("Next", compact_route(loop_run.final_route)),
    ]),
    key_value("Artifact", loop_run.loop_path),
  ])
}

///|
fn render_robo_loop_history(model : AppModel) -> Array[Html] {
  match model.latest_robo_loop_history {
    Some(history) => {
      let rows : Array[Html] = []
      for loop_run in history.loops {
        rows.push(render_robo_loop_history_row(loop_run))
      }
      [
        div(class="task-message-ledger-header", [
          key_value("Robo Loops", history.loop_count),
          p(class="detail-copy intent-status", model.robo_loop_history_status),
        ]),
        div(
          class="task-message-ledger robo-loop-history",
          if rows.is_empty() {
            [p(class="detail-copy empty-ledger", "No persisted Robo loops")]
          } else {
            rows
          },
        ),
      ]
    }
    None =>
      [
        div(class="task-message-ledger-header", [
          key_value("Robo Loops", "-"),
          p(class="detail-copy intent-status", model.robo_loop_history_status),
        ]),
      ]
  }
}

///|
fn render_robo_turn_history_row(turn : RoboTurnResult) -> Html {
  div(class="task-message-row robo-turn-row", [
    div(class="task-message-row-heading", [
      span(class="task-message-id", turn.turn_id),
      span(class="badge \{status_tone(turn.status)}", turn.status),
    ]),
    div(class="task-message-meta", [
      key_value("Task", turn.task_id),
      key_value("Owner", turn.next_owner),
      key_value("Kind", turn.next_kind),
      key_value("MoonClaw", turn.moonclaw_handoff),
    ]),
    div(class="task-message-meta", [
      key_value("Can Act", turn.can_act),
      key_value("Needs MoonClaw", turn.needs_moonclaw),
      key_value("Next", compact_route(turn.next_route)),
    ]),
    key_value("Artifact", turn.turn_path),
  ])
}

///|
fn render_robo_turn_history(model : AppModel) -> Array[Html] {
  match model.latest_robo_turn_history {
    Some(history) => {
      let rows : Array[Html] = []
      for turn in history.turns {
        rows.push(render_robo_turn_history_row(turn))
      }
      [
        div(class="task-message-ledger-header", [
          key_value("Robo Turns", history.turn_count),
          p(class="detail-copy intent-status", model.robo_turn_history_status),
        ]),
        div(
          class="task-message-ledger robo-turn-history",
          if rows.is_empty() {
            [p(class="detail-copy empty-ledger", "No persisted Robo turns")]
          } else {
            rows
          },
        ),
      ]
    }
    None =>
      [
        div(class="task-message-ledger-header", [
          key_value("Robo Turns", "-"),
          p(class="detail-copy intent-status", model.robo_turn_history_status),
        ]),
      ]
  }
}

///|
fn render_task_message_ledger_rows(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
  result : TaskMessageLedgerResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      if value.messages.is_empty() {
        [p(class="detail-copy empty-ledger", "No persisted task messages")]
      } else {
        let rows : Array[Html] = []
        for item in value.messages {
          let row_class = if item.task_id == model.focused_task_message_task_id {
            "task-message-row focused"
          } else {
            "task-message-row"
          }
          rows.push(
            div(class=row_class, [
              div(class="task-message-row-heading", [
                span(class="task-message-id", item.task_id),
                span(class="badge \{status_tone(item.stage)}", item.stage),
              ]),
              p(class="task-message-goal", item.goal),
              div(class="task-message-meta", [
                key_value("Class", item.classification),
                key_value("Current", item.route),
                key_value("Next", item.next_route),
              ]),
              div(class="task-message-flags", [
                key_value("Eval", item.evaluated),
                key_value("Dry", item.dry_run_collected),
                key_value("Approval", item.approved),
                key_value("Executed", item.executed),
              ]),
              div(class="task-message-meta", [
                key_value("Review", item.requires_review),
                key_value("Physical", item.physical_execution_allowed),
              ]),
              key_value("Path", item.message_path),
              div(class="task-message-row-actions", [
                button(
                  class="command-button primary",
                  type_="button",
                  disabled=model.loading_task_message_review ||
                    !task_message_stage_is_continuable(item.stage),
                  on_click=dispatch(
                    ContinueTaskMessage(item.task_id, item.stage),
                  ),
                  task_message_continue_button_label(
                    model,
                    item.task_id,
                    item.stage,
                  ),
                ),
                button(
                  class="command-button secondary",
                  type_="button",
                  disabled=model.loading_task_message_review,
                  on_click=dispatch(
                    OpenTaskMessageReviewRoute(
                      task_message_detail_route(item.task_id),
                    ),
                  ),
                  if model.loading_task_message_review {
                    "Opening..."
                  } else {
                    "Open Message"
                  },
                ),
              ]),
            ]),
          )
        }
        rows
      }
    None =>
      [p(class="detail-copy empty-ledger", "No task-message ledger loaded")]
  }
}

///|
fn render_task_message_ledger(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Array[Html] {
  let ledger_label = match model.latest_task_message_ledger {
    Some(value) => "\{value.message_count} message(s)"
    None => "-"
  }
  [
    div(class="task-message-ledger-header", [
      key_value("Ledger", ledger_label),
      p(class="detail-copy intent-status", model.task_message_ledger_status),
    ]),
    div(
      class="task-message-ledger",
      render_task_message_ledger_rows(
        dispatch,
        model,
        model.latest_task_message_ledger,
      ),
    ),
  ]
}

///|
fn render_task_message(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  panel(
    "message-panel",
    "Moonrobo",
    "Ask Robo",
    badge(
      if model.submitting_task_message {
        "running"
      } else {
        "routine"
      },
      "accent",
    ),
    [
      div(class="command-editor message-editor", [
        text_field("Message", model.task_message, value => {
          dispatch(UpdateTaskMessage(value))
        }),
      ]),
      p(class="detail-copy intent-status", model.task_message_status),
      ..render_robo_loop(model),
      ..render_robo_turn(model),
      ..render_robo_session(model),
      ..render_robo_loop_history(model),
      ..render_robo_turn_history(model),
      ..render_task_message_conversation(model),
      ..render_task_message_result(model.latest_task_message),
      ..render_task_message_ledger(dispatch, model),
      div(class="command-actions observation-actions", [
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.loading_task_messages ||
            model.loading_task_conversation,
          on_click=dispatch(RefreshTaskMessages),
          if model.loading_task_messages || model.loading_task_conversation {
            "Refreshing..."
          } else {
            "Refresh Ledger"
          },
        ),
        button(
          class="command-button primary",
          type_="button",
          disabled=model.submitting_task_message ||
            model.running_moonclaw_routine ||
            model.loading ||
            model.task_message.trim().to_owned() == "",
          on_click=dispatch(SubmitTaskMessage),
          if model.submitting_task_message || model.running_moonclaw_routine {
            "Asking..."
          } else {
            "Ask Robo"
          },
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.submitting_task_message ||
            model.running_moonclaw_routine ||
            model.loading ||
            model.task_message.trim().to_owned() == "",
          on_click=dispatch(RunTaskLoop),
          if model.submitting_task_message || model.running_moonclaw_routine {
            "Looping..."
          } else {
            "Run Loop"
          },
        ),
      ]),
    ],
  )
}

///|
fn render_observation(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  panel(
    "run-panel",
    "Moontown",
    "Observation Run",
    badge(
      if model.running_observation {
        "running"
      } else {
        "bounded"
      },
      "accent",
    ),
    [
      div(class="command-editor observation-editor", [
        text_field("Task ID", model.observation_task_id, value => {
          dispatch(UpdateObservationTaskId(value))
        }),
        command_field("Frames", model.observation_frame_count, 1, value => {
          dispatch(UpdateObservationFrameCount(value))
        }),
      ]),
      p(class="detail-copy intent-status", model.observation_status),
      ..render_observation_result(model.latest_observation_run),
      div(class="command-actions observation-actions", [
        button(
          class="command-button primary",
          type_="button",
          disabled=model.running_observation || model.loading,
          on_click=dispatch(RunObservation),
          observation_button_label(model),
        ),
      ]),
    ],
  )
}

///|
fn render_moonclaw_context_result(
  result : MoonClawContextResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Surface", value.surface),
          key_value("Reviews", value.review_count),
          key_value("Human Review", value.needs_human_count),
          key_value("Next", value.next_label),
        ]),
        key_value("Latest Review", value.latest_review_id),
        key_value("Next Route", value.next_route),
        p(class="detail-copy review-summary", value.latest_review_summary),
      ]
    None =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Surface", "-"),
          key_value("Reviews", "-"),
          key_value("Human Review", "-"),
          key_value("Next", "-"),
        ]),
        key_value("Latest Review", "-"),
        key_value("Next Route", "-"),
      ]
  }
}

///|
fn render_moonclaw_routine_result(
  result : MoonClawRoutineRunResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Run", value.status),
          key_value("Invoked", value.invoked),
          key_value("Plan", value.plan_status),
          key_value("Steps", value.step_count),
        ]),
        key_value("Run ID", value.run_id),
        key_value("Record", value.record_path),
        key_value("Next Kind", value.next_kind),
        key_value("Next Route", value.next_route),
        if value.error_code == "" {
          p(class="detail-copy review-summary", value.message)
        } else {
          p(
            class="detail-copy review-summary",
            "\{value.error_code}: \{value.error_message}",
          )
        },
      ]
    None =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Run", "-"),
          key_value("Invoked", "-"),
          key_value("Plan", "-"),
          key_value("Steps", "-"),
        ]),
      ]
  }
}

///|
fn render_moonclaw_context(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let action = match model.latest_moonclaw_context {
    Some(value) => value.surface
    None => "pending"
  }
  panel(
    "process-panel",
    "MoonClaw",
    "Context",
    badge(action, status_tone(action)),
    [
      p(class="detail-copy intent-status", model.moonclaw_context_status),
      ..render_moonclaw_context_result(model.latest_moonclaw_context),
      p(class="detail-copy intent-status", model.moonclaw_routine_status),
      key_value("MoonClaw Gateway", model.moonclaw_routine_run_url),
      key_value("Moonrobo Context", model.moonrobo_gateway_url),
      ..render_moonclaw_routine_result(model.latest_moonclaw_routine_run),
      div(class="command-actions process-actions", [
        button(
          class="command-button primary",
          type_="button",
          disabled=model.refreshing_moonclaw_context || model.loading,
          on_click=dispatch(RefreshMoonClawContext),
          moonclaw_context_button_label(model),
        ),
        button(
          class="command-button primary",
          type_="button",
          disabled=model.running_moonclaw_routine || model.loading,
          on_click=dispatch(RunMoonClawRoutine),
          moonclaw_routine_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.resolving_review ||
            model.loading ||
            !can_accept_latest_review(model),
          on_click=dispatch(AcceptLatestReview),
          accept_review_button_label(model),
        ),
      ]),
    ],
  )
}

///|
fn next_work_kind(queue : @platform_queue.RobotPlatformQueue) -> String {
  if queue.items.is_empty() {
    "clear"
  } else {
    queue.items[0].kind
  }
}

///|
fn render_next_work(queue : @platform_queue.RobotPlatformQueue) -> Array[Html] {
  if queue.items.is_empty() {
    [
      div(class="evidence-strip work-metrics", [
        key_value("Priority", "-"),
        key_value("Kind", "clear"),
        key_value("Target", "-"),
        key_value("Route", "-"),
      ]),
      p(class="detail-copy review-summary", "No queued MoonClaw work"),
    ]
  } else {
    let item = queue.items[0]
    [
      div(class="evidence-strip work-metrics", [
        key_value("Priority", "\{item.priority}"),
        key_value("Kind", item.kind),
        key_value("Target", item.target_id),
        key_value("Route", item.target_path),
      ]),
      key_value("Title", item.title),
      key_value("Summary", item.summary),
      p(class="detail-copy review-summary", item.reason),
    ]
  }
}

///|
fn render_runtime_calibration_action(
  action : RuntimeCalibrationActionResult,
) -> Html {
  div(class="readiness-check", [
    div(class="task-message-row-heading", [
      span(class="task-message-id", action.blocker_code),
      span(class="badge \{status_tone(action.severity)}", action.severity),
    ]),
    div(class="evidence-strip work-metrics", [
      key_value("Action", action.action_id),
      key_value("Owner", action.owner),
      key_value("Evidence", action.evidence_path),
    ]),
    p(class="detail-copy review-summary", action.summary),
    p(class="detail-copy review-summary", action.next_step),
  ])
}

///|
fn render_runtime_calibration(
  result : RuntimeCalibrationResult?,
  status : String,
) -> Array[Html] {
  match result {
    Some(value) => {
      let rows : Array[Html] = []
      for action in value.actions {
        rows.push(render_runtime_calibration_action(action))
      }
      [
        p(class="detail-copy intent-status", status),
        div(class="evidence-strip work-metrics", [
          key_value("Plan", value.plan_id),
          key_value("Status", value.status),
          key_value(
            "Blocking",
            "\{value.blocking_action_count} / \{value.action_count}",
          ),
          key_value("Runtime", value.runtime_id),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Robot", value.robot_id),
          key_value("Bridge", value.bridge_id),
        ]),
        div(class="readiness-checks", rows),
      ]
    }
    None =>
      if status == "Runtime calibration not loaded" {
        []
      } else {
        [p(class="detail-copy intent-status", status)]
      }
  }
}

///|
fn render_runtime_calibration_resolution(
  result : RuntimeCalibrationResolutionResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="readiness-check", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.blocker_code),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Action", value.action_id),
            key_value("Resolution", value.resolution_path),
            key_value("Latest", value.latest_resolution_path),
          ]),
          key_value("Next validation", value.next_validation_route),
        ]),
      ]
    None => []
  }
}

///|
fn render_task_message_review_result(
  result : TaskMessageReviewResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Task", value.task_id),
          key_value("Class", value.classification),
          key_value("Route", value.route),
          key_value("Capability", value.suggested_capability),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Physical", value.physical_execution_allowed),
          key_value("Review", value.requires_review),
          key_value("Goal", value.goal),
          key_value("Reason", value.reason),
        ]),
        ..render_reviewed_intent_draft(value.intent_draft),
      ]
    None => []
  }
}

///|
fn render_task_message_status_result(
  result : TaskMessageStatusResult?,
) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Stage", value.stage),
          key_value("Runtime", value.runtime_status),
          key_value("Receipt", value.receipt_status),
          key_value("Bridge", value.bridge_status),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Evaluated", value.evaluated),
          key_value("Dry Run", value.dry_run_collected),
          key_value("Approved", value.approved),
          key_value("Executed", value.executed),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value(
            "Next",
            if value.next_route == "" {
              "-"
            } else {
              value.next_route
            },
          ),
          key_value("Runtime Required", value.runtime_required),
          key_value("Task", value.task_id),
          key_value("Summary", value.summary),
        ]),
      ]
    None => []
  }
}

///|
fn render_reviewed_intent_draft(draft : ReviewedIntentDraft?) -> Array[Html] {
  match draft {
    Some(value) =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Intent", value.intent_id),
          key_value("Capability", value.capability),
          key_value("Receipt", value.receipt_id),
          key_value("Parameters", value.parameters.stringify()),
        ]),
      ]
    None => []
  }
}

///|
fn can_resolve_runtime_calibration(model : AppModel) -> Bool {
  match model.latest_runtime_calibration {
    Some(plan) => !plan.actions.is_empty()
    None => false
  }
}

///|
fn runtime_calibration_resolution_label(model : AppModel) -> String {
  if model.resolving_runtime_calibration {
    "Resolving..."
  } else {
    "Resolve Calibration"
  }
}

///|
fn render_platform_queue(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let queue = model.platform_queue
  panel(
    "platform-queue-panel",
    "Platform Queue",
    "Next Work",
    badge(next_work_kind(queue), status_tone(next_work_kind(queue))),
    [
      p(class="detail-copy intent-status", model.platform_queue_status),
      div(class="metric-grid work-summary", [
        metric("Items", "\{queue.item_count}"),
        metric("High", "\{queue.high_priority_count}"),
        metric("Generated", "\{queue.generated_at_ms}"),
      ]),
      ..render_next_work(queue),
      ..render_runtime_calibration(
        model.latest_runtime_calibration,
        model.runtime_calibration_status,
      ),
      ..render_runtime_calibration_resolution(
        model.latest_runtime_calibration_resolution,
      ),
      p(class="detail-copy intent-status", model.task_message_review_status),
      ..render_task_message_review_result(model.latest_task_message_review),
      ..render_task_message_status_result(model.latest_task_message_status),
      div(class="command-actions", [
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.resolving_runtime_calibration ||
            !can_resolve_runtime_calibration(model),
          on_click=dispatch(ResolveRuntimeCalibration),
          runtime_calibration_resolution_label(model),
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.loading_task_message_review ||
            !can_open_task_message_review(model),
          on_click=dispatch(OpenTaskMessageReview),
          task_message_review_button_label(model),
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.evaluating || !can_evaluate_reviewed_intent(model),
          on_click=dispatch(EvaluateReviewedIntent),
          evaluate_reviewed_intent_button_label(model),
        ),
      ]),
    ],
  )
}

///|
fn render_readiness_checks(
  report : @readiness.PlatformReadinessReport,
) -> Array[Html] {
  let rows : Array[Html] = []
  for check in report.checks {
    if check.status != "pass" {
      rows.push(
        div(class="readiness-check", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", check.code),
            span(class="badge \{status_tone(check.status)}", check.status),
          ]),
          key_value("Path", check.path),
          p(class="detail-copy review-summary", check.message),
        ]),
      )
    }
  }
  if rows.is_empty() {
    [p(class="detail-copy review-summary", "All first-milestone checks pass")]
  } else {
    rows
  }
}

///|
fn render_readiness_plan(
  plan : @readiness.PlatformReadinessPlan?,
) -> Array[Html] {
  match plan {
    None =>
      [p(class="detail-copy review-summary", "No readiness action plan loaded")]
    Some(value) =>
      if value.actions.is_empty() {
        [p(class="detail-copy review-summary", "No readiness actions remain")]
      } else {
        let rows : Array[Html] = []
        match value.next_action {
          Some(action) =>
            rows.push(
              div(class="readiness-check", [
                div(class="task-message-row-heading", [
                  span(class="task-message-id", "Next: \{action.title}"),
                  span(class="badge accent", action.execution_mode),
                ]),
                key_value("Route", "\{action.http_method} \{action.route}"),
                key_value("Physical", "\{action.physical_execution_allowed}"),
                p(class="detail-copy review-summary", action.summary),
              ]),
            )
          None => ()
        }
        for action in value.actions {
          if (match value.next_action {
              Some(next) => next.action_id != action.action_id
              None => true
            }) {
            rows.push(
              div(class="readiness-check", [
                div(class="task-message-row-heading", [
                  span(class="task-message-id", action.title),
                  span(class="badge neutral", action.check_code),
                ]),
                key_value("Route", "\{action.http_method} \{action.route}"),
                p(class="detail-copy review-summary", action.safety_note),
              ]),
            )
          }
        }
        rows
      }
  }
}

///|
fn render_loop_proof_checks(proof : PlatformLoopProofResult) -> Array[Html] {
  let rows : Array[Html] = []
  for check in proof.checks {
    rows.push(
      div(class="readiness-check", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", check.label),
          span(
            class="badge \{if check.ready == "true" { "ok" } else { "warning" }}",
            if check.ready == "true" {
              "ready"
            } else {
              "gap"
            },
          ),
        ]),
        key_value("Code", check.code),
        key_value("Route", check.evidence_route),
        key_value(
          "Evidence",
          if check.evidence_path == "" {
            "-"
          } else {
            check.evidence_path
          },
        ),
        p(class="detail-copy review-summary", check.message),
      ]),
    )
  }
  rows
}

///|
fn render_loop_proof_feedback(proof : PlatformLoopProofResult) -> Array[Html] {
  if proof.auto_feedback_attempted == "" {
    []
  } else {
    [
      div(class="evidence-strip work-metrics", [
        key_value("Auto Feedback", proof.auto_feedback_attempted),
        key_value("Feedback Status", proof.auto_feedback_status),
        key_value("Feedback Message", proof.auto_feedback_message),
      ]),
    ]
  }
}

///|
fn render_loop_proof(model : AppModel) -> Html {
  match model.latest_platform_loop_proof {
    Some(proof) =>
      div(
        class="loop-proof",
        [
          div(class="task-message-row-heading", [
            span(class="task-message-id", "Closed Loop Proof"),
            badge(proof.status, status_tone(proof.status)),
          ]),
          p(class="detail-copy intent-status", model.platform_loop_proof_status),
          p(class="detail-copy review-summary", proof.message),
          div(class="metric-grid readiness-summary", [
            metric(
              "Complete",
              "\{proof.completed_count} / \{proof.total_count}",
            ),
            metric("Percent", "\{proof.percent}%"),
            metric("Ready", proof.ready),
            metric("Readiness", proof.readiness_status),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Robot", proof.robot_id),
            key_value("Next", compact_route(proof.next_route)),
            key_value(
              "Readiness",
              "\{proof.readiness_pass_count} pass / \{proof.readiness_fail_count} fail",
            ),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value(
              "Routine",
              if proof.latest_gateway_command_path == "" {
                "-"
              } else {
                proof.latest_gateway_command_path
              },
            ),
            key_value(
              "Robo Loop",
              if proof.latest_robo_loop_path == "" {
                "-"
              } else {
                proof.latest_robo_loop_path
              },
            ),
            key_value(
              "Execution",
              if proof.latest_task_execution_path == "" {
                "-"
              } else {
                proof.latest_task_execution_path
              },
            ),
          ]),
          ..render_loop_proof_feedback(proof),
          div(class="readiness-checks", render_loop_proof_checks(proof)),
        ],
      )
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Closed Loop Proof"),
          badge("pending", "neutral"),
        ]),
        p(class="detail-copy intent-status", model.platform_loop_proof_status),
      ])
  }
}

///|
fn render_live_readiness(model : AppModel) -> Html {
  match model.latest_moonrobo_live_readiness {
    Some(readiness) =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Live Readiness"),
          badge(readiness.status, status_tone(readiness.status)),
        ]),
        p(
          class="detail-copy intent-status",
          model.moonrobo_live_readiness_status,
        ),
        p(class="detail-copy review-summary", readiness.message),
        div(class="metric-grid readiness-summary", [
          metric("SDK", readiness.ready_for_live_sdk),
          metric("Proof session", readiness.can_run_proof_session),
          metric("Gateway command", readiness.can_submit_gateway_command),
          metric("Physical", readiness.physical_execution_allowed),
          metric("Proof Feedback", readiness.proof_session_feedback_closed),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Robot", readiness.robot_id),
          key_value("Bridge", readiness.bridge_id),
          key_value("Runtime", readiness.runtime_status),
          key_value("Calibration", readiness.calibration_status),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value(
            "Bridge URL",
            if readiness.runtime_bridge_base_url == "" {
              "-"
            } else {
              readiness.runtime_bridge_base_url
            },
          ),
          key_value("Health", compact_route(readiness.runtime_health_path)),
          key_value(
            "Validation",
            compact_route(readiness.runtime_validation_session_path),
          ),
          key_value("Revalidate", readiness.calibration_pending_revalidation),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value(
            "Next",
            "\{readiness.next_method} \{compact_route(readiness.next_route)}",
          ),
          key_value("Next Title", readiness.next_title),
          key_value("Proof Sessions", readiness.proof_session_count),
          key_value(
            "Auto Feedback",
            "\{readiness.proof_session_auto_feedback_success_count} / \{readiness.proof_session_auto_feedback_attempted_count}",
          ),
          key_value(
            "Feedback Status",
            readiness.proof_session_latest_feedback_status,
          ),
          key_value(
            "Latest Session",
            if readiness.latest_proof_session_path == "" {
              "-"
            } else {
              readiness.latest_proof_session_path
            },
          ),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value(
            "Calibration Path",
            compact_route(readiness.calibration_path),
          ),
          key_value(
            "Feedback Message",
            if readiness.proof_session_latest_feedback_message == "" {
              "-"
            } else {
              readiness.proof_session_latest_feedback_message
            },
          ),
        ]),
      ])
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Live Readiness"),
          badge("pending", "neutral"),
        ]),
        p(
          class="detail-copy intent-status",
          model.moonrobo_live_readiness_status,
        ),
      ])
  }
}

///|
fn render_proof_session(model : AppModel) -> Html {
  match model.latest_platform_proof_session {
    Some(session) =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Proof Session"),
          badge(session.status, status_tone(session.status)),
        ]),
        p(
          class="detail-copy intent-status",
          model.platform_proof_session_status,
        ),
        p(class="detail-copy review-summary", session.message),
        div(class="metric-grid readiness-summary", [
          metric("Ready", session.ready),
          metric(
            "Attempts",
            "\{session.attempted_count} / \{session.requested_iterations}",
          ),
          metric("Persisted", session.persisted),
          metric("Stop", session.stop_reason),
          metric(
            "Auto Feedback",
            "\{session.auto_feedback_success_count} / \{session.auto_feedback_attempted_count}",
          ),
          metric("Feedback Status", session.latest_auto_feedback_status),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Session", session.session_id),
          key_value("Next", compact_route(session.next_route)),
          key_value("Record", compact_route(session.session_path)),
          key_value(
            "Latest Proof",
            if session.latest_proof_path == "" {
              "-"
            } else {
              compact_route(session.latest_proof_path)
            },
          ),
          key_value(
            "Feedback Message",
            if session.latest_auto_feedback_message == "" {
              "-"
            } else {
              session.latest_auto_feedback_message
            },
          ),
        ]),
      ])
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Proof Session"),
          badge("pending", "neutral"),
        ]),
        p(
          class="detail-copy intent-status",
          model.platform_proof_session_status,
        ),
      ])
  }
}

///|
fn render_live_exercise(model : AppModel) -> Html {
  let closure = render_live_closure(model)
  let history = render_live_exercise_history(model)
  match model.latest_live_exercise {
    Some(exercise) =>
      div(
        class="loop-proof",
        [
          div(class="task-message-row-heading", [
            span(class="task-message-id", "Live Exercise"),
            badge(exercise.status, status_tone(exercise.status)),
          ]),
          p(class="detail-copy intent-status", model.live_exercise_status),
          p(class="detail-copy review-summary", exercise.message),
          div(class="metric-grid readiness-summary", [
            metric("Routine", exercise.command_status),
            metric("Proof", exercise.proof_status),
            metric("Readiness", exercise.readiness_status),
            metric("Persisted", exercise.persisted),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Exercise", exercise.exercise_id),
            key_value("Proof Session", exercise.proof_session_id),
            key_value("Next", compact_route(exercise.next_route)),
            key_value("Record", compact_route(exercise.exercise_path)),
            key_value("Memory", compact_route(exercise.memory_path)),
          ]),
          ..closure,
          ..history,
        ],
      )
    None =>
      div(
        class="loop-proof",
        [
          div(class="task-message-row-heading", [
            span(class="task-message-id", "Live Exercise"),
            badge("pending", "neutral"),
          ]),
          p(class="detail-copy intent-status", model.live_exercise_status),
          ..closure,
          ..history,
        ],
      )
  }
}

///|
fn render_live_closure_missing(closure : MoonroboLiveClosureResult) -> String {
  if closure.missing.is_empty() {
    "-"
  } else {
    closure.missing.join(", ")
  }
}

///|
fn render_live_closure(model : AppModel) -> Array[Html] {
  match model.latest_live_closure {
    Some(closure) =>
      [
        div(class="readiness-check", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", "Live Closure"),
            badge(closure.status, status_tone(closure.status)),
          ]),
          p(class="detail-copy intent-status", model.live_closure_status),
          p(class="detail-copy review-summary", closure.message),
          div(class="metric-grid readiness-summary", [
            metric("Closed", closure.closed),
            metric("Missing", closure.missing_count),
            metric("Has Run", closure.has_exercise),
            metric("Runs", closure.exercise_count),
          ]),
          key_value("Exercise", compact_route(closure.exercise_id)),
          key_value("Missing Gates", render_live_closure_missing(closure)),
          key_value("Next", compact_route(closure.next_route)),
          key_value("Record", compact_route(closure.exercise_path)),
        ]),
      ]
    None =>
      [
        div(class="readiness-check", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", "Live Closure"),
            badge("pending", "neutral"),
          ]),
          p(class="detail-copy intent-status", model.live_closure_status),
        ]),
      ]
  }
}

///|
fn render_live_exercise_history_row(
  exercise : MoonroboLiveExerciseResult,
) -> Html {
  div(class="readiness-check", [
    div(class="task-message-row-heading", [
      span(class="task-message-id", exercise.exercise_id),
      badge(exercise.status, status_tone(exercise.status)),
    ]),
    div(class="metric-grid readiness-summary", [
      metric("Routine", exercise.command_status),
      metric("Proof", exercise.proof_status),
      metric("Readiness", exercise.readiness_status),
      metric("Persisted", exercise.persisted),
    ]),
    key_value("Next", compact_route(exercise.next_route)),
    key_value("Record", compact_route(exercise.exercise_path)),
  ])
}

///|
fn render_live_exercise_history(model : AppModel) -> Array[Html] {
  match model.latest_live_exercise_history {
    Some(history) =>
      [
        div(
          class="readiness-checks",
          [
            div(class="task-message-row-heading", [
              span(class="task-message-id", "Live History"),
              badge("\{history.exercise_count} runs", "neutral"),
            ]),
            p(
              class="detail-copy intent-status",
              model.live_exercise_history_status,
            ),
            ..history.exercises.map(render_live_exercise_history_row),
          ],
        ),
      ]
    None =>
      [p(class="detail-copy intent-status", model.live_exercise_history_status)]
  }
}

///|
fn render_proof_session_history(model : AppModel) -> Html {
  match model.latest_platform_proof_sessions {
    Some(history) =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Proof History"),
          badge("\{history.session_count} sessions", "neutral"),
        ]),
        p(
          class="detail-copy intent-status",
          model.platform_proof_sessions_status,
        ),
        div(
          class="readiness-checks",
          history.sessions.map(fn(session) {
            div(class="readiness-check", [
              div(class="task-message-row-heading", [
                span(class="task-message-id", session.session_id),
                badge(session.status, status_tone(session.status)),
              ]),
              key_value(
                "Attempts",
                "\{session.attempted_count} / \{session.requested_iterations}",
              ),
              key_value("Ready", session.ready),
              key_value("Stop", session.stop_reason),
              key_value(
                "Auto Feedback",
                "\{session.auto_feedback_success_count} / \{session.auto_feedback_attempted_count}",
              ),
              key_value("Feedback Status", session.latest_auto_feedback_status),
              key_value("Next", compact_route(session.next_route)),
              key_value("Record", compact_route(session.session_path)),
            ])
          }),
        ),
      ])
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Proof History"),
          badge("pending", "neutral"),
        ]),
        p(
          class="detail-copy intent-status",
          model.platform_proof_sessions_status,
        ),
      ])
  }
}

///|
fn render_platform_readiness(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let execution_rows = match model.latest_task_execution_proof {
    Some(proof) =>
      [
        key_value("Execution Proof", proof.latest_status),
        key_value("Proof Message", proof.message),
        key_value("Latest Task", proof.latest_task_id),
        key_value(
          "Latest Snapshot",
          if proof.latest_snapshot_id == "" {
            "-"
          } else {
            proof.latest_snapshot_id
          },
        ),
        key_value(
          "Verified",
          "\{proof.verified_count} / \{proof.execution_count}",
        ),
        key_value("Bridge", proof.latest_bridge_status),
        key_value(
          "Runtime",
          "\{proof.latest_runtime_status} / persisted \{proof.latest_runtime_health_persisted}",
        ),
      ]
    None => [key_value("Execution Proof", "not loaded")]
  }
  match model.latest_platform_readiness {
    Some(report) =>
      panel(
        "readiness-panel",
        "Moonrobo",
        "Platform Readiness",
        badge(report.status, status_tone(report.status)),
        [
          p(class="detail-copy intent-status", model.platform_readiness_status),
          div(class="metric-grid readiness-summary", [
            metric("Pass", "\{report.pass_count}"),
            metric("Fail", "\{report.fail_count}"),
            metric("Turns", "\{report.conversation_turn_count}"),
            metric("Memory", "\{report.memory_card_count}"),
            metric("Tools", "\{report.registered_capability_count}"),
            metric("Exec", "\{report.task_execution_count}"),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Robot", report.robot_id),
            key_value("Runtime", report.latest_runtime_status),
            key_value("Root", report.root),
            key_value("Report", report.report_id),
          ]),
          render_live_readiness(model),
          render_live_exercise(model),
          render_loop_proof(model),
          render_proof_session(model),
          render_proof_session_history(model),
          div(class="evidence-strip work-metrics", execution_rows),
          div(class="command-actions", [
            button(
              class="command-button",
              type_="button",
              disabled=model.bootstrapping_platform || model.loading,
              on_click=dispatch(BootstrapPlatform),
              platform_bootstrap_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.proving_runtime || model.loading,
              on_click=dispatch(ProveRuntime),
              platform_runtime_proof_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.proving_loop || model.loading,
              on_click=dispatch(ProveLoop),
              platform_loop_proof_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.running_proof_session ||
                model.loading ||
                model.task_message.trim().to_owned() == "",
              on_click=dispatch(RunProofSession),
              platform_proof_session_button_label(model),
            ),
          ]),
          div(
            class="readiness-checks",
            render_readiness_plan(model.latest_platform_readiness_plan),
          ),
          div(class="readiness-checks", render_readiness_checks(report)),
        ],
      )
    None =>
      panel(
        "readiness-panel",
        "Moonrobo",
        "Platform Readiness",
        badge("pending", "neutral"),
        [
          p(class="detail-copy intent-status", model.platform_readiness_status),
          div(class="metric-grid readiness-summary", [
            metric("Pass", "-"),
            metric("Fail", "-"),
            metric("Turns", "-"),
            metric("Memory", "-"),
            metric("Tools", "-"),
            metric("Exec", "-"),
          ]),
          render_live_readiness(model),
          render_live_exercise(model),
          render_loop_proof(model),
          render_proof_session(model),
          render_proof_session_history(model),
          div(class="command-actions", [
            button(
              class="command-button",
              type_="button",
              disabled=model.bootstrapping_platform || model.loading,
              on_click=dispatch(BootstrapPlatform),
              platform_bootstrap_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.proving_runtime || model.loading,
              on_click=dispatch(ProveRuntime),
              platform_runtime_proof_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.proving_loop || model.loading,
              on_click=dispatch(ProveLoop),
              platform_loop_proof_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.running_proof_session ||
                model.loading ||
                model.task_message.trim().to_owned() == "",
              on_click=dispatch(RunProofSession),
              platform_proof_session_button_label(model),
            ),
          ]),
        ],
      )
  }
}

///|
fn render_telemetry(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let telemetry = snapshot.telemetry
  panel(
    "telemetry-panel",
    "Telemetry",
    "Latest Frame",
    badge(
      telemetry.mode,
      status_tone(if telemetry.errors > 0 { "error" } else { "ok" }),
    ),
    [
      div(class="metric-grid wide", [
        metric("Frame", telemetry.frame_id),
        metric("Captured", "\{telemetry.captured_at_ms}"),
        metric("Errors", "\{telemetry.errors}"),
        metric("IMU", if telemetry.imu_available { "yes" } else { "no" }),
        metric("Operator", "\{telemetry.operator_input_fields}"),
        metric("Joints", "\{telemetry.joints}"),
      ]),
    ],
  )
}

///|
fn render_receipt(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let receipt = snapshot.latest_receipt
  panel(
    "receipt-panel",
    "Evidence",
    "Latest Receipt",
    badge("\{snapshot.receipt_count} receipts", "neutral"),
    [
      key_value("Receipt ID", receipt_id_label(receipt)),
      key_value("Status", receipt_status_label(receipt)),
      key_value("Capability", receipt_capability_label(receipt)),
      key_value("Started", receipt_started_label(receipt)),
      key_value("Bridge Error", receipt_bridge_error_label(receipt)),
    ],
  )
}

///|
fn render_status(model : AppModel) -> Html {
  let status = model.moonstat_status
  panel(
    "status-panel",
    "Moonstat",
    "Suite Status",
    badge(status.status, status_tone(status.status)),
    [
      div(class="metric-grid wide", [
        metric("Receipts", "\{status.receipt_count}"),
        metric("Observations", "\{status.observation_count}"),
        metric("Reviews", "\{status.process_review_count}"),
      ]),
      key_value("Availability", status.availability),
      key_value("Bridge", status.bridge_state),
      key_value("Replay", status.latest_replay_path),
    ],
  )
}

///|
fn render_source_status(model : AppModel) -> Html {
  let error = match model.error {
    Some(message) => [span(class="source-error", message)]
    None => []
  }
  div(
    class="source-status",
    [
      span(class="source-label", "Source: \{model.last_source}"),
      span(class="source-label", loading_label(model)),
      ..error,
    ],
  )
}

///|
fn render_app(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  let snapshot = model.snapshot
  div(class="app-shell", [
    header(class="topbar", [
      div([p(class="eyebrow", "Moon agent suite"), h1("Moonrobo Cockpit")]),
      div(class="topbar-actions", [
        render_source_status(model),
        badge(read_only_label(snapshot.read_only), "accent"),
        badge(snapshot.bridge.mode, "neutral"),
        button(
          class="refresh-button",
          type_="button",
          disabled=model.loading,
          on_click=dispatch(RefreshSnapshot),
          "Refresh",
        ),
      ]),
    ]),
    main_(class="cockpit-grid", [
      render_robot(snapshot),
      render_product_status(snapshot),
      render_twin(dispatch, model),
      render_bridge(dispatch, model),
      render_platform_readiness(dispatch, model),
      render_safety(dispatch, model),
      render_platform_queue(dispatch, model),
      render_task_message(dispatch, model),
      render_observation(dispatch, model),
      render_telemetry(snapshot),
      render_receipt(snapshot),
      render_moonclaw_context(dispatch, model),
      render_status(model),
    ]),
  ])
}
