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
fn platform_advance_button_label(model : AppModel) -> String {
  if model.advancing_platform {
    "Advancing..."
  } else {
    "Advance Task"
  }
}

///|
fn platform_first_loop_button_label(model : AppModel) -> String {
  if model.running_first_loop {
    "Running..."
  } else {
    "Run First Loop"
  }
}

///|
fn platform_first_loop_dispatch_button_label(model : AppModel) -> String {
  if model.running_first_loop {
    "Dispatching..."
  } else {
    "Dispatch First Loop"
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
        key_value("Log Path", if log.log_path == "" { "-" } else { log.log_path }),
        key_value("Log Active", log.active),
        key_value("Log Running", log.running),
        key_value("Log Lines", "\{log.line_count} / \{log.max_lines}"),
        key_value("Log Truncated", log.truncated),
        div(
          class="runtime-log-tail",
          if log.tail == "" { model.runtime_log_status } else { log.tail },
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
fn render_bridge(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
  let snapshot = model.snapshot
  let bridge = snapshot.bridge
  let sidecar = snapshot.sidecar
  let runtime = model.runtime_supervisor_status
  let health_rows = match model.latest_runtime_health {
    Some(health) => [
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
    Some(validation) => [
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
    Some(session) => [
      key_value("Validation Session", model.runtime_validation_session_status),
      key_value("Session Status", session.status),
      key_value("Session Ready", session.ready_for_live_sdk),
      key_value("Session Persisted", session.persisted),
      key_value("Session Samples", "\{session.ready_sample_count} ready / \{session.blocked_sample_count} blocked / \{session.sample_count} total"),
      key_value("Mapping Proof", session.mapping_status),
      key_value("Mapping Stable", session.mapping_stable),
      key_value("Mapping Samples", "\{session.mapping_matching_sample_count} matched / \{session.mapping_mismatch_sample_count} mismatch"),
      key_value("Mapping Message", session.mapping_message),
      key_value("Required Samples", session.required_sample_count),
      key_value("First Blocker", session.first_blocker_code),
      key_value("Session Path", session.latest_session_path),
      key_value("Session Record", session.session_path),
      key_value("Calibration", session.calibration_status),
      key_value("Calibration Actions", "\{session.calibration_blocking_action_count} blocking / \{session.calibration_action_count} total"),
      key_value("Calibration Path", session.latest_calibration_path),
      key_value("Calibration Record", session.calibration_path),
    ]
    None => [
      key_value(
        "Validation Session",
        model.runtime_validation_session_status,
      ),
    ]
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
      div(
        class="freshness \{status_tone(sidecar.state)}",
        sidecar.detail,
      ),
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
    Some(value) =>
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
      ]
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
fn render_task_loop_result(result : TaskLoopResult?) -> Array[Html] {
  match result {
    Some(value) =>
      {
        let recovery_rows = match value.recovery {
          Some(recovery) => [
            div(class="evidence-strip work-metrics", [
              key_value("Recovery", recovery.kind),
              key_value("Recovery Step", recovery.step_id),
              key_value("Recovery Status", recovery.status),
            ]),
            key_value("Recovery Path", recovery.path),
            p(class="detail-copy review-summary", recovery.summary),
          ]
          None => []
        }
        let proof_rows = if value.proof_status == "" {
          []
        } else {
          [
            div(class="evidence-strip work-metrics", [
              key_value("Live Proof", value.proof_status),
              key_value("Proof Verified", value.proof_verified),
              key_value("Auto Feedback", value.proof_auto_feedback_bound),
              key_value("Auto Verified", value.proof_auto_feedback_verified),
              key_value("Proof Next", compact_route(value.proof_next_route)),
            ]),
            key_value("Auto Feedback Message", value.proof_auto_feedback_message),
            key_value("Live Proof Path", value.proof_path),
          ]
        }
        let routine_rows = if value.routine_id == "" {
          []
        } else {
          [
            div(class="evidence-strip work-metrics", [
              key_value("Robot Routine", value.routine_status),
              key_value("Routine Verified", value.routine_verified),
              key_value("Memory Updated", value.routine_memory_updated),
              key_value("Routine Next", compact_route(value.routine_next_route)),
            ]),
            key_value("Routine ID", value.routine_id),
            key_value("Routine Path", value.routine_path),
          ]
        }
        [
        div(class="task-loop-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.task_id),
            span(
              class="badge \{status_tone(value.task_stage)}",
              value.task_stage,
            ),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Class", value.classification),
            key_value("Continued", value.continued),
            key_value("Dispatch", value.dispatch_requested),
            key_value("First Loop", value.stopped_reason),
            key_value("HTTP", value.first_loop_status),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Session", value.session.session_id),
            key_value("Thread", value.session.thread_id),
            key_value("Session Stage", value.session.stage),
            key_value("Dispatch Ready", value.session.dispatch_ready),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Session Robot", value.session.robot_id),
            key_value("Session Bridge", value.session.bridge_id),
            key_value("Session Task", value.session.task_id),
            key_value("Session Dispatch", value.session.dispatch_requested),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Session Resident", value.session.resident_id),
            key_value("Session Mapping", value.session.mapping_id),
            key_value("Execution Verified", value.session.execution_verified),
            key_value("Session Recovery", value.session.recovery_kind),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Turns", value.conversation_turn_count),
            key_value("Latest Turn", value.conversation_latest_task_id),
            key_value("Resident", value.resident_availability),
            key_value("Readiness", value.readiness_status),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Mapping", value.mapping.mapping_id),
            key_value("Robot", value.mapping.robot_id),
            key_value("Resident ID", value.mapping.resident_id),
            key_value("Bridge", value.mapping.bridge_id),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Runtime", value.mapping.runtime_status),
            key_value("Availability", value.mapping.availability),
            key_value("Mapped", value.mapping.mapped),
            key_value("Reachable", value.mapping.reachable),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Latest Task", value.mapping.latest_task_id),
            key_value("Execution", value.mapping.latest_execution_status),
            key_value("Feedback", value.mapping.latest_feedback_status),
            key_value("Verified Exec", value.mapping.verified_execution_count),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Proof", value.execution_proof.latest_status),
            key_value("Verified", value.execution_proof.latest_verified),
            key_value("Proof Count", "\{value.execution_proof.verified_count} / \{value.execution_proof.execution_count}"),
            key_value("Snapshot", value.execution_proof.latest_snapshot_id),
          ]),
          key_value("Outcome", value.mapping.latest_command_outcome_status),
          key_value("Proof Outcome", value.execution_proof.latest_command_outcome_status),
          key_value("Proof Path", value.execution_proof.latest_snapshot_path),
          ..routine_rows,
          ..proof_rows,
          key_value("Session Next", compact_route(value.session.continuation_route)),
          key_value("Session Recovery Path", value.session.recovery_path),
          p(class="detail-copy review-summary", value.session.latest_user_text),
          p(class="detail-copy review-summary", value.session.latest_robo_text),
          ..recovery_rows,
          key_value("Next Route", compact_route(value.task_next_route)),
          p(class="detail-copy review-summary", value.task_summary),
        ]),
        ]
      }
    None => []
  }
}

///|
fn render_robo_session(model : AppModel) -> Array[Html] {
  match model.latest_robo_session {
    Some(value) =>
      [
        div(class="task-loop-result robo-session-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.session.session_id),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Stage", value.session.stage),
            key_value("Task", if value.session.task_id == "" { "-" } else { value.session.task_id }),
            key_value("Turns", value.turn_count),
            key_value("Has Task", value.has_task_message),
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
            key_value("Verified", "\{value.execution_proof.verified_count} / \{value.execution_proof.execution_count}"),
          ]),
          key_value("Next", compact_route(value.session.continuation_route)),
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
        div(class="task-loop-result robo-turn-result", [
          div(class="task-message-row-heading", [
            span(class="task-message-id", value.turn_id),
            span(class="badge \{status_tone(value.status)}", value.status),
          ]),
          p(class="detail-copy intent-status", value.message),
          div(class="evidence-strip work-metrics", [
            key_value("Task", value.task_id),
            key_value("Accepted", value.accepted),
            key_value("Agent Ran", value.agent_ran),
            key_value("Can Act", value.can_act),
          ]),
          div(class="evidence-strip work-metrics", [
            key_value("Next Owner", value.next_owner),
            key_value("Next Kind", value.next_kind),
            key_value("Needs Agent", value.needs_agent),
            key_value("Next Route", compact_route(value.next_route)),
          ]),
          key_value("Turn Path", value.turn_path),
        ]),
      ]
    None => []
  }
}

///|
fn render_task_message_ledger_rows(
  dispatch : (Msg) -> @rabbita.Cmd,
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
                span(
                  class="badge \{status_tone(item.stage)}",
                  item.stage,
                ),
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
                  on_click=dispatch(ContinueTaskMessage(item.task_id, item.stage)),
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
                    OpenTaskMessageReviewRoute(task_message_detail_route(item.task_id)),
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
    None => [p(class="detail-copy empty-ledger", "No task-message ledger loaded")]
  }
}

///|
fn render_task_message_ledger(
  dispatch : (Msg) -> @rabbita.Cmd,
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
fn task_message_button_label(model : AppModel) -> String {
  if model.submitting_task_message {
    "Sending..."
  } else {
    "Send Task"
  }
}

///|
fn can_continue_task_loop(model : AppModel) -> Bool {
  match model.latest_task_loop {
    Some(_) => true
    None => model.focused_task_message_task_id != ""
  }
}

///|
fn render_task_message(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
  panel(
    "message-panel",
    "Moontown",
    "Task Message",
    badge(if model.submitting_task_message { "sending" } else { "read-only" }, "accent"),
    [
      div(class="command-editor message-editor", [
        text_field(
          "Message",
          model.task_message,
          value => dispatch(UpdateTaskMessage(value)),
        ),
      ]),
      p(class="detail-copy intent-status", model.task_message_status),
      ..render_robo_turn(model),
      ..render_robo_session(model),
      ..render_task_message_conversation(model),
      ..render_task_loop_result(model.latest_task_loop),
      ..render_task_message_result(model.latest_task_message),
      ..render_task_message_ledger(dispatch, model),
      div(class="command-actions observation-actions", [
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.loading_task_messages || model.loading_task_conversation,
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
          disabled=model.submitting_task_message || model.loading || model.task_message.trim().to_owned() == "",
          on_click=dispatch(SubmitTaskMessage),
          task_message_button_label(model),
        ),
        button(
          class="command-button",
          type_="button",
          disabled=model.submitting_task_message || model.running_first_loop || model.loading || model.task_message.trim().to_owned() == "",
          on_click=dispatch(RunTaskLoop),
          if model.submitting_task_message && model.running_first_loop {
            "Asking..."
          } else {
            "Ask Robo"
          },
        ),
        button(
          class="command-button danger",
          type_="button",
          disabled=model.submitting_task_message || model.running_first_loop || model.loading || model.task_message.trim().to_owned() == "",
          on_click=dispatch(DispatchTaskLoop),
          if model.submitting_task_message && model.running_first_loop {
            "Dispatching..."
          } else {
            "Ask & Dispatch"
          },
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.submitting_task_message || model.running_first_loop || model.loading || !can_continue_task_loop(model),
          on_click=dispatch(ContinueTaskLoop),
          if model.submitting_task_message && model.running_first_loop {
            "Continuing..."
          } else {
            "Continue Session"
          },
        ),
        button(
          class="command-button danger",
          type_="button",
          disabled=model.submitting_task_message || model.running_first_loop || model.loading || !can_continue_task_loop(model),
          on_click=dispatch(DispatchTaskLoopContinuation),
          if model.submitting_task_message && model.running_first_loop {
            "Retrying..."
          } else {
            "Retry Dispatch"
          },
        ),
      ]),
    ],
  )
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
          key_value("Run ID", value.run_id),
        ]),
        key_value("Record", value.record_path),
        key_value("Evidence", value.evidence_route),
        key_value("Replay", value.replay_route),
        key_value("Replay Frames", value.replay_frame_count),
        key_value("Latest Review", value.latest_review_id),
        key_value("Review Path", value.review_path),
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
          key_value("Run ID", "-"),
        ]),
        key_value("Record", "-"),
        key_value("Evidence", "-"),
        key_value("Replay", "-"),
        key_value("Replay Frames", "-"),
        key_value("Latest Review", "-"),
        key_value("Review Path", "-"),
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
        button(
          class="command-button",
          type_="button",
          disabled=model.resolving_review || model.loading || !can_accept_latest_review(model),
          on_click=dispatch(AcceptLatestReview),
          accept_review_button_label(model),
        ),
      ]),
    ],
  )
}

///|
fn next_work_kind(queue : @work_queue.AgentWorkQueue) -> String {
  match queue.next_item {
    Some(item) => item.kind
    None => "clear"
  }
}

///|
fn render_next_work(queue : @work_queue.AgentWorkQueue) -> Array[Html] {
  match queue.next_item {
    Some(item) =>
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
    None =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Priority", "-"),
          key_value("Kind", "clear"),
          key_value("Target", "-"),
          key_value("Route", "-"),
        ]),
        p(class="detail-copy review-summary", "No queued robot-agent work"),
      ]
  }
}

///|
fn render_next_action(action : @work_queue.AgentNextAction?) -> Array[Html] {
  match action {
    Some(value) =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Method", value.http_method),
          key_value("Route", value.route),
          key_value("Body", value.body_schema),
          key_value("Mode", value.execution_mode),
        ]),
        key_value(
          "Draft Body",
          match value.body_template {
            Some(body) => body.stringify()
            None =>
              if value.kind == "bind-execution-feedback" {
                "latest runtime telemetry"
              } else {
                "-"
              }
          },
        ),
        key_value(
          "Physical",
          if value.physical_execution_allowed { "allowed" } else { "blocked" },
        ),
        p(class="detail-copy review-summary", value.safety_note),
      ]
    None =>
      [
        div(class="evidence-strip work-metrics", [
          key_value("Method", "-"),
          key_value("Route", "-"),
          key_value("Body", "-"),
          key_value("Mode", "-"),
        ]),
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
          key_value("Blocking", "\{value.blocking_action_count} / \{value.action_count}"),
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
          key_value("Next", if value.next_route == "" { "-" } else { value.next_route }),
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
fn can_dispatch_next_action(model : AppModel) -> Bool {
  match model.next_action {
    Some(action) =>
      action.http_method == "POST" && !action.physical_execution_allowed &&
      (action.body_template is Some(_) ||
        action.kind == "bind-execution-feedback")
    None => false
  }
}

///|
fn dispatch_next_label(model : AppModel) -> String {
  if model.dispatching_next_action {
    "Dispatching..."
  } else if model.next_action is Some({ kind: "bind-execution-feedback", .. }) {
    "Bind Feedback"
  } else {
    "Dispatch Safe Action"
  }
}

///|
fn render_work_queue(dispatch : (Msg) -> @rabbita.Cmd, model : AppModel) -> Html {
  let queue = model.work_queue
  panel(
    "work-queue-panel",
    "Agent Queue",
    "Next Work",
    badge(next_work_kind(queue), status_tone(next_work_kind(queue))),
    [
      p(class="detail-copy intent-status", model.work_queue_status),
      div(class="metric-grid work-summary", [
        metric("Items", "\{queue.item_count}"),
        metric("High", "\{queue.high_priority_count}"),
        metric("Generated", "\{queue.generated_at_ms}"),
      ]),
      ..render_next_work(queue),
      ..render_next_action(model.next_action),
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
          disabled=model.resolving_runtime_calibration || !can_resolve_runtime_calibration(model),
          on_click=dispatch(ResolveRuntimeCalibration),
          runtime_calibration_resolution_label(model),
        ),
        button(
          class="command-button secondary",
          type_="button",
          disabled=model.loading_task_message_review || !can_open_task_message_review(model),
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
        button(
          class="command-button primary",
          type_="button",
          disabled=model.dispatching_next_action || !can_dispatch_next_action(model),
          on_click=dispatch(DispatchNextAction),
          dispatch_next_label(model),
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
      [
        p(
          class="detail-copy review-summary",
          "No readiness action plan loaded",
        ),
      ]
    Some(value) =>
      if value.actions.is_empty() {
        [
          p(
            class="detail-copy review-summary",
            "No readiness actions remain",
          ),
        ]
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
            if check.ready == "true" { "ready" } else { "gap" },
          ),
        ]),
        key_value("Code", check.code),
        key_value("Route", check.evidence_route),
        key_value("Evidence", if check.evidence_path == "" { "-" } else { check.evidence_path }),
        p(class="detail-copy review-summary", check.message),
      ]),
    )
  }
  rows
}

///|
fn render_loop_proof(model : AppModel) -> Html {
  match model.latest_platform_loop_proof {
    Some(proof) =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Closed Loop Proof"),
          badge(proof.status, status_tone(proof.status)),
        ]),
        p(class="detail-copy intent-status", model.platform_loop_proof_status),
        p(class="detail-copy review-summary", proof.message),
        div(class="metric-grid readiness-summary", [
          metric("Complete", "\{proof.completed_count} / \{proof.total_count}"),
          metric("Percent", "\{proof.percent}%"),
          metric("Ready", proof.ready),
          metric("Readiness", proof.readiness_status),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Robot", proof.robot_id),
          key_value("Next", compact_route(proof.next_route)),
          key_value("Readiness", "\{proof.readiness_pass_count} pass / \{proof.readiness_fail_count} fail"),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Routine", if proof.latest_routine_path == "" { "-" } else { proof.latest_routine_path }),
          key_value("Live Proof", if proof.latest_live_proof_path == "" { "-" } else { proof.latest_live_proof_path }),
          key_value("Execution", if proof.latest_task_execution_path == "" { "-" } else { proof.latest_task_execution_path }),
        ]),
        div(class="readiness-checks", render_loop_proof_checks(proof)),
      ])
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
        p(class="detail-copy intent-status", model.moonrobo_live_readiness_status),
        p(class="detail-copy review-summary", readiness.message),
        div(class="metric-grid readiness-summary", [
          metric("SDK", readiness.ready_for_live_sdk),
          metric("Proof", readiness.can_collect_proof),
          metric("Dispatch", readiness.can_request_dispatch),
          metric("Physical", readiness.physical_execution_allowed),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Robot", readiness.robot_id),
          key_value("Bridge", readiness.bridge_id),
          key_value("Runtime", readiness.runtime_status),
          key_value("Calibration", readiness.calibration_status),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Bridge URL", if readiness.runtime_bridge_base_url == "" { "-" } else { readiness.runtime_bridge_base_url }),
          key_value("Health", compact_route(readiness.runtime_health_path)),
          key_value("Validation", compact_route(readiness.runtime_validation_session_path)),
          key_value("Revalidate", readiness.calibration_pending_revalidation),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Next", "\{readiness.next_method} \{compact_route(readiness.next_route)}"),
          key_value("Next Title", readiness.next_title),
          key_value("Proof Sessions", readiness.proof_session_count),
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
          key_value("Calibration Path", compact_route(readiness.calibration_path)),
        ]),
      ])
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Live Readiness"),
          badge("pending", "neutral"),
        ]),
        p(class="detail-copy intent-status", model.moonrobo_live_readiness_status),
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
        p(class="detail-copy intent-status", model.platform_proof_session_status),
        p(class="detail-copy review-summary", session.message),
        div(class="metric-grid readiness-summary", [
          metric("Ready", session.ready),
          metric("Attempts", "\{session.attempted_count} / \{session.requested_iterations}"),
          metric("Persisted", session.persisted),
          metric("Stop", session.stop_reason),
        ]),
        div(class="evidence-strip work-metrics", [
          key_value("Session", session.session_id),
          key_value("Next", compact_route(session.next_route)),
          key_value("Record", compact_route(session.session_path)),
          key_value("Latest Proof", if session.latest_proof_path == "" { "-" } else { compact_route(session.latest_proof_path) }),
        ]),
      ])
    None =>
      div(class="loop-proof", [
        div(class="task-message-row-heading", [
          span(class="task-message-id", "Proof Session"),
          badge("pending", "neutral"),
        ]),
        p(class="detail-copy intent-status", model.platform_proof_session_status),
      ])
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
        p(class="detail-copy intent-status", model.platform_proof_sessions_status),
        div(
          class="readiness-checks",
          history.sessions.map(fn(session) {
            div(class="readiness-check", [
              div(class="task-message-row-heading", [
                span(class="task-message-id", session.session_id),
                badge(session.status, status_tone(session.status)),
              ]),
              key_value("Attempts", "\{session.attempted_count} / \{session.requested_iterations}"),
              key_value("Ready", session.ready),
              key_value("Stop", session.stop_reason),
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
        p(class="detail-copy intent-status", model.platform_proof_sessions_status),
      ])
  }
}

///|
fn render_platform_readiness(
  dispatch : (Msg) -> @rabbita.Cmd,
  model : AppModel,
) -> Html {
  let execution_rows = match model.latest_task_execution_proof {
    Some(proof) => [
      key_value("Execution Proof", proof.latest_status),
      key_value("Proof Message", proof.message),
      key_value("Latest Task", proof.latest_task_id),
      key_value("Latest Snapshot", if proof.latest_snapshot_id == "" { "-" } else { proof.latest_snapshot_id }),
      key_value("Verified", "\{proof.verified_count} / \{proof.execution_count}"),
      key_value("Bridge", proof.latest_bridge_status),
      key_value("Runtime", "\{proof.latest_runtime_status} / persisted \{proof.latest_runtime_health_persisted}"),
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
          render_loop_proof(model),
          render_proof_session(model),
          render_proof_session_history(model),
          div(class="evidence-strip work-metrics", execution_rows),
          div(class="command-actions", [
            button(
              class="command-button primary",
              type_="button",
              disabled=model.bootstrapping_platform || model.loading,
              on_click=dispatch(BootstrapPlatform),
              platform_bootstrap_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.advancing_platform || model.loading,
              on_click=dispatch(AdvancePlatform),
              platform_advance_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.running_first_loop || model.loading,
              on_click=dispatch(RunFirstLoop),
              platform_first_loop_button_label(model),
            ),
            button(
              class="command-button danger",
              type_="button",
              disabled=model.running_first_loop || model.loading,
              on_click=dispatch(DispatchFirstLoop),
              platform_first_loop_dispatch_button_label(model),
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
              disabled=model.running_proof_session || model.loading || model.task_message.trim().to_owned() == "",
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
          render_loop_proof(model),
          render_proof_session(model),
          render_proof_session_history(model),
          div(class="command-actions", [
            button(
              class="command-button primary",
              type_="button",
              disabled=model.bootstrapping_platform || model.loading,
              on_click=dispatch(BootstrapPlatform),
              platform_bootstrap_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.advancing_platform || model.loading,
              on_click=dispatch(AdvancePlatform),
              platform_advance_button_label(model),
            ),
            button(
              class="command-button",
              type_="button",
              disabled=model.running_first_loop || model.loading,
              on_click=dispatch(RunFirstLoop),
              platform_first_loop_button_label(model),
            ),
            button(
              class="command-button danger",
              type_="button",
              disabled=model.running_first_loop || model.loading,
              on_click=dispatch(DispatchFirstLoop),
              platform_first_loop_dispatch_button_label(model),
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
              disabled=model.running_proof_session || model.loading || model.task_message.trim().to_owned() == "",
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
        metric("Policy Evals", "\{status.policy_evaluation_count}"),
      ]),
      key_value("Availability", status.availability),
      key_value("Bridge", status.bridge_state),
      key_value("Latest Run", status.latest_run_id),
      key_value("Latest Policy", status.latest_policy_evaluation_id),
      key_value("Policy Gate", status.latest_policy_gate_status),
      key_value("Policy Path", status.latest_policy_path),
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
      render_bridge(dispatch, model),
      render_platform_readiness(dispatch, model),
      render_safety(dispatch, model),
      render_work_queue(dispatch, model),
      render_task_message(dispatch, model),
      render_observation(dispatch, model),
      render_telemetry(snapshot),
      render_receipt(snapshot),
      render_process_plan(dispatch, model),
      render_status(model),
    ]),
  ])
}
