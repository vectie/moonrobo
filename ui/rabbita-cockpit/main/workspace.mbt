///|
fn cockpit_sections(view : String) -> Array[(String, String, String)] {
  match view {
    "robot" =>
      [
        ("model", "Model", "robot"),
        ("edit", "Edit", "edit"),
        ("design", "Design", "design"),
        ("trials", "Trials", "flask"),
      ]
    "tasks" =>
      [
        ("chat", "Chat", "chat"),
        ("review", "Review", "shield"),
        ("history", "History", "history"),
        ("observe", "Observe", "observe"),
      ]
    "data" =>
      [
        ("experiments", "Experiments", "flask"),
        ("results", "Results", "diagnostics"),
        ("replay", "3D replay", "history"),
        ("library", "Library", "data"),
      ]
    "diagnostics" =>
      [
        ("connection", "Connection", "connection"),
        ("readiness", "Readiness", "shield"),
        ("system", "System", "diagnostics"),
      ]
    _ =>
      [
        ("control", "Control", "operate"),
        ("telemetry", "Telemetry", "diagnostics"),
        ("activity", "Activity", "history"),
      ]
  }
}

///|
fn cockpit_section(model : AppModel) -> String {
  match model.active_view {
    "robot" => model.robot_section
    "tasks" => model.tasks_section
    "data" => model.data_section
    "diagnostics" => model.diagnostics_section
    _ => model.operate_section
  }
}

///|
fn render_workspace_tabs(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  div(
    class="workspace-tabs",
    attrs=@html.Attrs::build().role("tablist").aria_label("Workspace sections"),
    cockpit_sections(model.active_view).map(section => {
      let (value, label, glyph) = section
      let selected = cockpit_section(model) == value
      button(
        id="section-\{value}",
        class=if selected { "workspace-tab active" } else { "workspace-tab" },
        type_="button",
        attrs=@html.Attrs::build()
          .role("tab")
          .aria_selected(if selected { "true" } else { "false" })
          .aria_controls("workspace-content")
          .tabindex(if selected { 0 } else { -1 }),
        on_click=dispatch(SelectCockpitSection(value)),
        [robo_glyph(glyph), span(label)],
      )
    }),
  )
}

///|
fn disclosure(title : String, body : Array[Html]) -> Html {
  @html.details(class="workspace-details", [
    @html.summary([robo_glyph("details"), span(title)]),
    div(class="workspace-details-body", body),
  ])
}

///|
fn workspace_tool(
  tool : String,
  title : String,
  glyph : String,
  action : String,
) -> Html {
  section(class="workspace-tool", [
    div(class="workspace-tool-icon", [robo_glyph(glyph)]),
    h2(title),
    button(
      class="operator-next-action",
      type_="button",
      attrs=if tool == "learning-experiments" {
        @html.Attrs::build()
        .data_set("open-learning-experiments", "")
        .aria_controls("learning-workspace-slot")
      } else {
        @html.Attrs::build()
        .data_set("open-workspace-tool", tool)
        .aria_haspopup("dialog")
        .aria_controls("\{tool}-dialog")
      },
      [robo_glyph(glyph), span(action)],
    ),
  ])
}

///|
fn render_task_history(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  panel(
    "task-history-panel",
    "",
    "Task history",
    badge("Saved", "neutral"),
    [
      ..render_task_message_ledger(dispatch, model),
      disclosure(
        "Run details",
        [..render_robo_loop_history(model), ..render_robo_turn_history(model)],
      ),
    ],
  )
}
