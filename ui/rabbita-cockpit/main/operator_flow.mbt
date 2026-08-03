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
fn operator_flow_stage(model : AppModel) -> Int {
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
  number : Int,
  label : String,
  glyph : String,
  current : Int,
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
  stage : Int,
) -> Html {
  let loading = model.loading ||
    model.evaluating ||
    model.collecting_dry_run ||
    model.approving ||
    model.executing
  let (label, glyph, message, danger) = if model.error is Some(_) ||
    model.snapshot.bridge.telemetry_stale {
    ("Refresh evidence", "refresh", RefreshSnapshot, false)
  } else if model.snapshot.read_only {
    ("Open diagnostics", "diagnostics", SelectCockpitView("diagnostics"), false)
  } else {
    match stage {
      2 => ("Evaluate command", "shield", EvaluateWalk, false)
      3 => ("Run dry-run", "flask", CollectDryRun, false)
      4 => ("Record approval", "approve", ApproveWalk, false)
      5 => ("Execute approved command", "execute", ExecuteWalk, true)
      _ => ("Evaluate next command", "refresh", EvaluateWalk, false)
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
fn operator_flow_copy(model : AppModel, stage : Int) -> String {
  if model.error is Some(_) {
    "A request failed closed. Refresh current evidence before deciding whether a new attempt is safe."
  } else if model.snapshot.bridge.telemetry_stale {
    "Telemetry is stale. Physical effects stay unavailable until evidence is current."
  } else if model.snapshot.read_only {
    "This cockpit is read-only. Inspect diagnostics; do not infer physical authority from the preview."
  } else {
    match stage {
      2 => "Evaluate the bounded command against current safety policy."
      3 =>
        "Collect dry-run evidence before asking a person to approve an effect."
      4 => "Bind named approval to the exact dry-run receipt."
      5 =>
        "Approval exists. Execution remains an explicit consequential action."
      _ =>
        "Execution is recorded. Editing the command clears prior dry-run and approval evidence."
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
          @html.p(class="eyebrow", "Your outcome"),
          @html.h2("Run one reviewed robot command"),
          @html.p(class="operator-flow-copy", operator_flow_copy(model, stage)),
        ]),
        @html.div(class="operator-flow-next", [
          @html.small(
            if blocked {
              "SAFE RECOVERY"
            } else {
              "NEXT SAFE ACTION"
            },
          ),
          operator_flow_action(dispatch, model, stage),
        ]),
      ]),
      @html.div(class="operator-flow-rail", [
        operator_flow_step(1, "Evidence", "observe", stage, blocked),
        operator_flow_step(2, "Evaluate", "shield", stage, blocked),
        operator_flow_step(3, "Dry-run", "flask", stage, blocked),
        operator_flow_step(4, "Approve", "approve", stage, blocked),
        operator_flow_step(5, "Execute", "execute", stage, blocked),
      ]),
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
          @html.small("MoonRobo safety gate owns the physical-effect boundary"),
        ],
      ),
    ],
  )
}
