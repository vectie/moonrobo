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
) -> Html {
  button(
    class=cockpit_tab_class(model, view),
    type_="button",
    on_click=dispatch(SelectCockpitView(view)),
    label,
  )
}

///|
fn render_cockpit_navigation(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  div(class="cockpit-nav", [
    cockpit_tab(dispatch, model, "operate", "Operate"),
    cockpit_tab(dispatch, model, "robot", "Robot"),
    cockpit_tab(dispatch, model, "tasks", "Tasks"),
    cockpit_tab(dispatch, model, "data", "MoonData"),
    cockpit_tab(dispatch, model, "diagnostics", "Diagnostics"),
  ])
}

///|
fn render_cockpit_header(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let snapshot = model.snapshot
  let runtime = model.runtime_supervisor_status
  header(class="cockpit-header", [
    div(class="cockpit-header-inner", [
      div(class="cockpit-identity", [
        p(class="eyebrow", "Moon agent suite"),
        h1("Moonrobo"),
        span(class="robot-identity", snapshot.robot.label),
      ]),
      div(class="cockpit-health", [
        badge(runtime.status, status_tone(runtime.status)),
        badge(
          freshness_label(snapshot.bridge.telemetry_stale),
          status_tone(
            if snapshot.bridge.telemetry_stale {
              "stale"
            } else {
              "fresh"
            },
          ),
        ),
        badge(read_only_label(snapshot.read_only), "accent"),
        span(class="robot-id", snapshot.robot.robot_id),
      ]),
      div(class="cockpit-global-actions", [
        button(
          class="header-action",
          type_="button",
          disabled=model.loading,
          on_click=dispatch(RefreshSnapshot),
          "Refresh",
        ),
        button(
          class="header-action emergency",
          type_="button",
          disabled=model.stopping_emergency || model.loading,
          on_click=dispatch(EmergencyStopRuntime),
          runtime_emergency_stop_button_label(model),
        ),
      ]),
    ]),
    div(class="cockpit-header-meta", [
      render_source_status(model),
      span(class="header-route", "Bridge \{snapshot.bridge.bridge_id}"),
      span(class="header-route", snapshot.bridge.mode),
    ]),
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
          span(class="moondata-path", artifact.manifest_path),
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
        "MoonData",
        "Canonical Data Plane",
        badge(data.status, status_tone(data.status)),
        [
          div(class="moondata-toolbar", [
            p(class="detail-copy moondata-message", data.message),
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
            metric("Captures", data.capture_count),
            metric("Episodes", data.episode_count),
            metric("Frames", data.frame_count),
            metric("Robot Models", data.robot_model_count),
            metric("Quality", data.quality_count),
            metric("Versions", data.version_count),
            metric("Replays", data.replay_count),
            metric("Exports", data.export_count),
            metric("Blockers", data.blocker_count),
            metric("Open Repairs", data.repair_open_count),
          ]),
          div(class="moondata-state", [
            key_value("Initialized", data.initialized),
            key_value("Ready", data.ready),
            key_value("Validation", data.validation_status),
            key_value("Warnings", data.warning_count),
            key_value("Root", data.root),
            key_value("Catalog", data.catalog_path),
          ]),
          div(class="moondata-artifacts", moondata_artifact_rows(data)),
        ],
      )
    None =>
      panel(
        "moondata-panel",
        "MoonData",
        "Canonical Data Plane",
        badge("unavailable", "warning"),
        [
          p(class="detail-copy", model.moondata_status),
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
  match model.active_view {
    "robot" =>
      [
        render_twin(model),
        render_robot(snapshot),
        render_model_workspace(dispatch, model),
      ]
    "tasks" =>
      [
        render_task_message(dispatch, model),
        render_platform_queue(dispatch, model),
        render_observation(dispatch, model),
        render_moonclaw_context(dispatch, model),
        render_receipt(snapshot),
      ]
    "data" => [render_moondata(dispatch, model)]
    "diagnostics" =>
      [
        render_bridge(dispatch, model),
        render_platform_readiness(dispatch, model),
        render_status(model),
        render_telemetry(snapshot),
        render_receipt(snapshot),
        render_product_status(snapshot),
      ]
    _ =>
      [
        render_twin(model),
        render_safety(dispatch, model),
        render_robot(snapshot),
        render_product_status(snapshot),
        render_telemetry(snapshot),
        render_receipt(snapshot),
      ]
  }
}

///|
fn render_cockpit_shell(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  div(class="app-shell", [
    render_cockpit_header(dispatch, model),
    main_(
      class="cockpit-main view-\{model.active_view}",
      render_active_cockpit_view(dispatch, model),
    ),
  ])
}
