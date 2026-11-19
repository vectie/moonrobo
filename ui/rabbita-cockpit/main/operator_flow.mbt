///|
fn robo_glyph(name : String) -> Html {
  @html.span(
    class="robo-glyph glyph-\{name}",
    attrs=@html.Attrs::build().aria_hidden("true"),
    "",
  )
}

///|
fn operator_flow_blocked(model : AppModel) -> Bool {
  model.error is Some(_) ||
  model.snapshot.bridge.telemetry_stale ||
  model.snapshot.read_only
}

///|
fn operator_flow_stage(model : AppModel) -> Int32 {
  if operator_flow_blocked(model) {
    1
  } else if model.walk_executed {
    6
  } else if model.intent_status == "No command submitted" {
    2
  } else if model.dry_run_receipt_id == "" {
    3
  } else if model.approval_id == "" {
    4
  } else {
    5
  }
}

///|
fn operator_flow_step(
  number : Int32,
  label : String,
  glyph : String,
  current : Int32,
  blocked : Bool,
) -> Html {
  let state = if number < current {
    "complete"
  } else if number == current && blocked {
    "blocked"
  } else if number == current {
    "current"
  } else {
    "next"
  }
  @html.div(class="operator-flow-step is-\{state}", [
    robo_glyph(glyph),
    @html.div([
      @html.span(label),
      @html.small(
        class="visually-hidden",
        match state {
          "complete" => "Done"
          "blocked" => "Blocked"
          "current" => "Current"
          _ => "Next"
        },
      ),
    ]),
  ])
}

///|
fn operator_flow_action(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
  stage : Int32,
) -> Html {
  let loading = model.loading ||
    model.evaluating ||
    model.collecting_dry_run ||
    model.approving ||
    model.executing
  let (label, glyph, message, danger) = if model.error is Some(_) ||
    model.snapshot.bridge.telemetry_stale {
    ("Reconnect", "refresh", RefreshSnapshot, false)
  } else if model.snapshot.read_only {
    ("Check connection", "connection", SelectCockpitView("diagnostics"), false)
  } else {
    match stage {
      2 => ("Check command", "shield", EvaluateWalk, false)
      3 => ("Dry run", "flask", CollectDryRun, false)
      4 => ("Approve command", "approve", ApproveWalk, false)
      5 => ("Execute command", "execute", ExecuteWalk, true)
      _ => ("Check next command", "refresh", EvaluateWalk, false)
    }
  }
  @html.button(
    class=if danger {
      "operator-next-action is-danger"
    } else {
      "operator-next-action"
    },
    type_="button",
    title=label,
    disabled=loading,
    attrs=@html.Attrs::build().aria_label(label),
    on_click=dispatch(message),
    [robo_glyph(glyph), @html.span(label)],
  )
}

///|
fn operator_flow_copy(model : AppModel, stage : Int32) -> String {
  if model.error is Some(_) {
    "Connection unavailable. Reconnect to continue."
  } else if model.snapshot.bridge.telemetry_stale {
    "Telemetry is out of date. Refresh before continuing."
  } else if model.snapshot.read_only {
    "Read-only mode. Check the connection to enable control."
  } else {
    match stage {
      2 => "Set your motion, then check the command."
      3 => "Preview the command with a dry run."
      4 => "Review the dry run, then approve this command."
      5 => "Ready to execute. This will move the robot."
      _ => "Command recorded. Edit the motion to start again."
    }
  }
}

///|
fn render_operator_flow(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  let stage = operator_flow_stage(model)
  let blocked = operator_flow_blocked(model)
  let result = match model.error {
    Some(message) => message
    None => model.intent_status
  }
  @html.section(
    class=if blocked { "operator-flow is-blocked" } else { "operator-flow" },
    attrs=@html.Attrs::build().aria_label("Governed robot command workflow"),
    [
      @html.div(class="operator-flow-head", [
        @html.div([
          @html.h2(
            if blocked {
              "Connect to begin"
            } else if model.walk_executed {
              "Command complete"
            } else {
              "Ready for your next move"
            },
          ),
          @html.p(class="operator-flow-copy", operator_flow_copy(model, stage)),
        ]),
        @html.div(class="operator-flow-next", [
          operator_flow_action(dispatch, model, stage),
        ]),
      ]),
      @html.div(class="operator-flow-rail", [
        operator_flow_step(1, "Connect", "connection", stage, blocked),
        operator_flow_step(2, "Check", "shield", stage, blocked),
        operator_flow_step(3, "Dry-run", "flask", stage, blocked),
        operator_flow_step(4, "Approve", "approve", stage, blocked),
        operator_flow_step(5, "Execute", "execute", stage, blocked),
      ]),
      disclosure("Command status", [
        @html.div(
          class=if blocked {
            "operator-flow-result is-denied"
          } else {
            "operator-flow-result"
          },
          attrs=@html.Attrs::build().role("status").aria_live("polite"),
          [
            @html.strong(
              if blocked {
                "Physical effect denied"
              } else if model.walk_executed {
                "Execution recorded"
              } else {
                "Current result"
              },
            ),
            @html.span(result),
          ],
        ),
      ]),
    ],
  )
}
