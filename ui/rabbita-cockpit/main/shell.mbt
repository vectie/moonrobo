///|
fn cockpit_tab_class(model : AppModel, view : String) -> String {
  if model.active_view == view {
    "cockpit-tab active"
  } else {
    "cockpit-tab"
  }
}

///|
fn cockpit_tab(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
  view : String,
  label : String,
  glyph : String,
) -> Html {
  button(
    class=cockpit_tab_class(model, view),
    type_="button",
    title=label,
    attrs=@html.Attrs::build()
      .aria_label(label)
      .data_set("workspace", view)
      .aria_pressed(if model.active_view == view { "true" } else { "false" }),
    on_click=dispatch(SelectCockpitView(view)),
    [robo_glyph(glyph), span(class="cockpit-tab-label", label)],
  )
}

///|
fn render_cockpit_navigation(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  @html.nav(
    class="cockpit-nav",
    attrs=@html.Attrs::build().aria_label("Workspaces"),
    [
      cockpit_tab(dispatch, model, "operate", "Operate", "operate"),
      cockpit_tab(dispatch, model, "robot", "Robot", "robot"),
      cockpit_tab(dispatch, model, "tasks", "Tasks", "tasks"),
      cockpit_tab(dispatch, model, "data", "Data", "data"),
      cockpit_tab(dispatch, model, "diagnostics", "System", "diagnostics"),
    ],
  )
}

///|
fn render_cockpit_header(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let snapshot = model.snapshot
  let runtime = model.runtime_supervisor_status
  let telemetry_available = runtime.ready &&
    model.error is None &&
    model.last_source != "sample fallback" &&
    snapshot.telemetry.captured_at_ms > 0L
  let telemetry_label = if telemetry_available {
    freshness_label(snapshot.bridge.telemetry_stale)
  } else {
    "Telemetry unavailable"
  }
  header(class="cockpit-header", [
    div(class="cockpit-header-inner", [
      div(class="cockpit-identity", [
        div(class="brand-mark", [robo_glyph("robot")]),
        h1("MoonRobo"),
        render_robot_selector(dispatch, model),
      ]),
      div(class="cockpit-health", [
        span(class="health-indicator", title=runtime.status, [
          robo_glyph("connection"),
          span(
            if model.error is None && model.last_source != "sample fallback" {
              "Service connected"
            } else {
              "Offline"
            },
          ),
        ]),
        span(
          class="health-indicator \{if !telemetry_available { "neutral" } else if snapshot.bridge.telemetry_stale { "warning" } else { "ok" }}",
          title=telemetry_label,
          attrs=@html.Attrs::build().aria_label(telemetry_label),
          [robo_glyph("diagnostics")],
        ),
        if model.robot_context == "g1-simulation" {
          span(
            class="badge neutral mode-status read-only",
            title="Recorded simulation",
            [span(class="mode-label", "Recorded simulation")],
          )
        } else if model.last_source == "sample fallback" {
          span(class="badge neutral mode-status preview", title="Preview", [
            span(class="mode-label", "Preview"),
          ])
        } else {
          span(
            class="badge neutral mode-status \{if snapshot.read_only { "read-only" } else { "live" }}",
            title=read_only_label(snapshot.read_only),
            [span(class="mode-label", read_only_label(snapshot.read_only))],
          )
        },
      ]),
      div(class="cockpit-global-actions", [
        button(
          class="header-action icon-action theme-toggle",
          type_="button",
          title="Switch to light mode",
          attrs=@html.Attrs::build()
            .aria_label("Switch to light mode")
            .data_set("theme-toggle", ""),
          [robo_glyph("theme")],
        ),
        @html.a(
          href="./results.html?robot=g1-simulation",
          class="header-action icon-action",
          title="Results overview",
          attrs=@html.Attrs::build().aria_label("Results overview"),
          [robo_glyph("flask"), span(class="visually-hidden", "Results")],
        ),
        button(
          class="header-action icon-action",
          type_="button",
          title="Refresh evidence",
          attrs=@html.Attrs::build().aria_label("Refresh evidence"),
          disabled=model.loading,
          on_click=dispatch(RefreshSnapshot),
          [robo_glyph("refresh"), span(class="visually-hidden", "Refresh")],
        ),
        if model.robot_context == "workspace" {
          button(
            class="header-action emergency",
            type_="button",
            disabled=model.stopping_emergency,
            on_click=dispatch(EmergencyStopRuntime),
            [
              robo_glyph("stop"),
              span(runtime_emergency_stop_button_label(model)),
            ],
          )
        } else {
          span("")
        },
      ]),
    ]),
    match model.emergency_stop_status {
      Some(status) =>
        p(
          class="detail-copy intent-status",
          attrs=@html.Attrs::build().role("status").aria_live("polite"),
          status,
        )
      None => span("")
    },
    render_cockpit_navigation(dispatch, model),
  ])
}

///|
fn moondata_artifact_rows(data : MoonDataStatusResult) -> Array[Html] {
  let rows : Array[Html] = []
  for index in 0..<data.artifacts.length() {
    if index < 40 {
      let artifact = data.artifacts[index]
      rows.push(
        div(class="moondata-artifact", [
          div(class="moondata-artifact-heading", [
            span(class="moondata-kind", artifact.artifact_kind),
            badge(artifact.status, status_tone(artifact.status)),
          ]),
          span(class="moondata-id", artifact.artifact_id),
          p(class="moondata-summary", artifact.summary),
          disclosure("Details", [key_value("Manifest", artifact.manifest_path)]),
        ]),
      )
    }
  }
  if rows.is_empty() {
    [p(class="empty-ledger detail-copy", "No canonical artifacts registered")]
  } else {
    rows
  }
}

///|
fn render_moondata(dispatch : @rabbita.Emit[Msg], model : AppModel) -> Html {
  match model.latest_moondata {
    Some(data) =>
      panel(
        "moondata-panel",
        "",
        "Data library",
        badge(data.status, status_tone(data.status)),
        [
          div(class="moondata-toolbar", [
            button(
              class="header-action",
              type_="button",
              disabled=model.loading_moondata,
              on_click=dispatch(RefreshMoonData),
              if model.loading_moondata {
                "Refreshing..."
              } else {
                "Refresh Data"
              },
            ),
          ]),
          div(class="metric-grid moondata-metrics", [
            metric("Artifacts", data.artifact_count),
            metric("Datasets", data.dataset_count),
            metric("Episodes", data.episode_count),
            metric("Blockers", data.blocker_count),
          ]),
          div(class="moondata-artifacts", moondata_artifact_rows(data)),
          disclosure("Storage details", [
            p(class="detail-copy moondata-message", data.message),
            key_value("Validation", data.validation_status),
            key_value("Warnings", data.warning_count),
            key_value("Captures", data.capture_count),
            key_value("Frames", data.frame_count),
            key_value("Robot Models", data.robot_model_count),
            key_value("Replays", data.replay_count),
            key_value("Versions", data.version_count),
            key_value("Exports", data.export_count),
            key_value("Open Repairs", data.repair_open_count),
            key_value("Root", data.root),
            key_value("Catalog", data.catalog_path),
          ]),
        ],
      )
    None =>
      panel(
        "moondata-panel",
        "",
        "Data library",
        badge("unavailable", "warning"),
        [
          p(
            class="detail-copy",
            if model.loading_moondata {
              "Loading your data…"
            } else {
              "Data is unavailable. Check your connection and retry."
            },
          ),
          disclosure("Connection details", [
            p(class="detail-copy", model.moondata_status),
          ]),
          button(
            class="header-action",
            type_="button",
            disabled=model.loading_moondata,
            on_click=dispatch(RefreshMoonData),
            if model.loading_moondata {
              "Loading..."
            } else {
              "Retry"
            },
          ),
        ],
      )
  }
}

///|
fn render_active_cockpit_view(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Array[Html] {
  let snapshot = model.snapshot
  let section = cockpit_section(model)
  if model.robot_context == "g1-simulation" && model.active_view != "data" {
    return if (model.active_view == "robot" && section == "model") ||
      (model.active_view == "operate" && section == "control") {
      [render_recorded_robot(dispatch)]
    } else {
      [
        render_robot_empty(
          dispatch,
          recorded=true,
          title=match model.active_view {
            "robot" => "Recorded model is read-only"
            "tasks" => "No tasks for this robot"
            "diagnostics" => "No connection for this robot"
            _ =>
              if section == "telemetry" {
                "No live telemetry"
              } else {
                "No activity for this robot"
              }
          },
        ),
      ]
    }
  }
  if model.active_view == "data" &&
    (
      (model.robot_context == "workspace" && section != "library") ||
      (model.robot_context == "g1-simulation" && section == "library")
    ) {
    return [
      render_robot_empty(
        dispatch,
        recorded=model.robot_context == "g1-simulation",
        title="No datasets for this robot",
      ),
    ]
  }
  match (model.active_view, cockpit_section(model)) {
    ("robot", "edit") => [render_model_workspace(dispatch, model)]
    ("robot", "design") =>
      [
        workspace_tool(
          "design-workbench", "Build your robot", "design", "Open designer",
        ),
      ]
    ("robot", "trials") =>
      [
        workspace_tool(
          "digital-trials", "Digital trials", "flask", "Open trials",
        ),
      ]
    ("robot", _) =>
      [
        render_twin(model),
        disclosure("Robot details", [render_robot(snapshot)]),
      ]
    ("tasks", "review") => [render_platform_queue(dispatch, model)]
    ("tasks", "history") =>
      [render_task_history(dispatch, model), render_receipt(snapshot)]
    ("tasks", "observe") => [render_observation(dispatch, model)]
    ("tasks", _) => [render_task_message(dispatch, model)]
    ("data", "experiments") | ("data", "results") | ("data", "replay") =>
      [
        div(
          id="learning-workspace-slot",
          attrs=@html.Attrs::build()
            .data_set("learning-robot", model.robot_context)
            .data_set("learning-section", model.data_section),
          ([] : Array[Html]),
        ),
      ]
    ("data", _) => [render_moondata(dispatch, model)]
    ("diagnostics", "readiness") => [render_platform_readiness(dispatch, model)]
    ("diagnostics", "system") =>
      [
        render_status(model),
        render_product_status(snapshot),
        render_moonclaw_context(dispatch, model),
        disclosure("Connection details", [
          render_source_status(model),
          key_value("Robot", snapshot.robot.robot_id),
          key_value("Bridge", snapshot.bridge.bridge_id),
          key_value("Mode", snapshot.bridge.mode),
        ]),
      ]
    ("diagnostics", _) => [render_bridge(dispatch, model)]
    (_, "telemetry") =>
      [
        render_telemetry(snapshot),
        workspace_tool(
          "telemetry-review", "Review a recording", "history", "Open replay",
        ),
      ]
    (_, "activity") => [render_receipt(snapshot)]
    _ =>
      [
        render_operator_flow(dispatch, model),
        render_twin(model),
        render_safety(dispatch, model),
      ]
  }
}

///|
fn render_cockpit_shell(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  div(
    class="app-shell",
    attrs=@html.Attrs::build().data_set("robot-context", model.robot_context),
    [
      render_cockpit_header(dispatch, model),
      main_(class="cockpit-main view-\{model.active_view}", [
        render_workspace_tabs(dispatch, model),
        div(
          id="workspace-content",
          class="workspace-content section-\{cockpit_section(model)}",
          attrs=@html.Attrs::build()
            .role("tabpanel")
            .aria_labelledby("section-\{cockpit_section(model)}")
            .tabindex(0),
          render_active_cockpit_view(dispatch, model),
        ),
      ]),
    ],
  )
}
