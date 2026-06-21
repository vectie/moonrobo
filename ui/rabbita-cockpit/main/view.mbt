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
fn command_field(
  label_text : String,
  value : String,
  step : Int,
  on_change : (String) -> @rabbita.Cmd,
) -> Html {
  label(class="command-field", [
    span(class="key-label", label_text),
    input(
      input_type=Number,
      value~,
      step~,
      on_input=on_change,
      "",
    ),
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
    input(
      input_type=Text,
      value~,
      on_input=on_change,
      "",
    ),
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
fn joint_cells(count : Int) -> Array[Html] {
  let cells : Array[Html] = []
  for i in 0..<count {
    cells.push(div(class="joint-cell", "J\{i + 1}"))
  }
  cells
}

///|
fn render_robot(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let robot = snapshot.robot
  panel(
    "robot-panel",
    "RobotBook",
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
fn render_twin(snapshot : @cockpit.CockpitSnapshot) -> Html {
  panel(
    "twin-panel",
    "Digital Twin",
    "Embodiment State",
    badge(read_only_label(snapshot.read_only), "accent"),
    [
      div(class="robot-diagram", [
        div(class="robot-head", ""),
        div(class="robot-body", ""),
        div(class="robot-arm left", ""),
        div(class="robot-arm right", ""),
        div(class="robot-leg left", ""),
        div(class="robot-leg right", ""),
      ]),
      div(class="joint-strip", joint_cells(snapshot.robot.joints)),
    ],
  )
}

///|
fn render_bridge(snapshot : @cockpit.CockpitSnapshot) -> Html {
  let bridge = snapshot.bridge
  let sidecar = snapshot.sidecar
  panel(
    "bridge-panel",
    "Bridge",
    "Runtime Link",
    badge(sidecar.state, status_tone(sidecar.state)),
    [
      key_value("Bridge ID", bridge.bridge_id),
      key_value("Mode", bridge.mode),
      key_value("Sidecar", sidecar.sidecar_id),
      key_value("Command", sidecar.command_path),
      key_value(
        "Telemetry Age",
        "\{optional_int_label(bridge.telemetry_age_ms)} ms",
      ),
      div(
        class="freshness \{status_tone(if bridge.telemetry_stale { "stale" } else { "fresh" })}",
        freshness_label(bridge.telemetry_stale),
      ),
      div(
        class="freshness \{status_tone(sidecar.state)}",
        sidecar.detail,
      ),
    ],
  )
}

///|
fn render_safety(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
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
        command_field("X", model.walk_x, 1, value => dispatch(UpdateWalkX(value))),
        command_field(
          "Yaw",
          model.walk_yaw,
          1,
          value => dispatch(UpdateWalkYaw(value)),
        ),
        command_field(
          "Duration ms",
          model.walk_duration_ms,
          100,
          value => dispatch(UpdateWalkDuration(value)),
        ),
      ]),
      p(class="detail-copy", safety.detail),
      p(class="detail-copy intent-status", model.intent_status),
      div(class="evidence-strip", [
        key_value("Dry Run", if model.dry_run_receipt_id == "" { "-" } else { model.dry_run_receipt_id }),
        key_value("Approval", if model.approval_id == "" { "-" } else { model.approval_id }),
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
          disabled=model.approving || model.loading || model.dry_run_receipt_id == "",
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
fn render_observation(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
  panel(
    "run-panel",
    "Moontown",
    "Observation Run",
    badge(if model.running_observation { "running" } else { "bounded" }, "accent"),
    [
      div(class="command-editor observation-editor", [
        text_field(
          "Task ID",
          model.observation_task_id,
          value => dispatch(UpdateObservationTaskId(value)),
        ),
        command_field(
          "Frames",
          model.observation_frame_count,
          1,
          value => dispatch(UpdateObservationFrameCount(value)),
        ),
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
fn render_process_plan_result(result : MoonClawPlanResult?) -> Array[Html] {
  match result {
    Some(value) =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Action", value.action),
          key_value("Reviews", value.review_count),
          key_value("Human Review", value.needs_human_count),
          key_value("Latest Review", value.latest_review_id),
        ]),
        key_value("First Step", value.first_step_label),
        key_value("Route", value.first_step_route),
        p(class="detail-copy review-summary", value.latest_review_summary),
      ]
    None =>
      [
        div(class="evidence-strip process-metrics", [
          key_value("Action", "-"),
          key_value("Reviews", "-"),
          key_value("Human Review", "-"),
          key_value("Latest Review", "-"),
        ]),
        key_value("First Step", "-"),
        key_value("Route", "-"),
      ]
  }
}

///|
fn render_process_plan(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
  let action = match model.latest_process_plan {
    Some(value) => value.action
    None => "pending"
  }
  panel(
    "process-panel",
    "MoonClaw",
    "Next Process",
    badge(action, status_tone(action)),
    [
      p(class="detail-copy intent-status", model.process_status),
      ..render_process_plan_result(model.latest_process_plan),
      div(class="command-actions process-actions", [
        button(
          class="command-button primary",
          type_="button",
          disabled=model.running_next_process || model.loading,
          on_click=dispatch(RunNextProcess),
          next_process_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.refreshing_process_plan || model.loading,
          on_click=dispatch(RefreshProcessPlan),
          process_plan_button_label(model),
        ),
      ]),
    ],
  )
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
fn render_app(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
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
      render_twin(snapshot),
      render_bridge(snapshot),
      render_safety(dispatch, model),
      render_observation(dispatch, model),
      render_telemetry(snapshot),
      render_receipt(snapshot),
      render_process_plan(dispatch, model),
    ]),
  ])
}
