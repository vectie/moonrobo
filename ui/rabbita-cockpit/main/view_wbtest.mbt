///|
test "sample snapshot keeps imported cockpit contract" {
  let snapshot = sample_snapshot()
  inspect(snapshot.robot.robot_id, content="noetix-e1-lab-01")
  inspect(snapshot.safety.decision, content="dry-run-required")
  inspect(snapshot.read_only, content="true")
}

///|
test "update handles loaded and failed snapshots" {
  let model = init_model()
  let (_, loaded) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Ok(sample_snapshot())),
    model,
  )
  inspect(loaded.loading, content="false")
  inspect(loaded.error is None, content="true")
  let (_, failed) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Err("boom")),
    loaded,
  )
  inspect(failed.loading, content="false")
  inspect(failed.error is Some("boom"), content="true")
}

///|
test "update tracks intent evaluation lifecycle" {
  let model = init_model()
  let (_, edited_x) = update(_ => @rabbita.none, UpdateWalkX("0.25"), model)
  inspect(edited_x.walk_x, content="0.25")
  let (_, edited_yaw) = update(_ => @rabbita.none, UpdateWalkYaw("-0.10"), edited_x)
  inspect(edited_yaw.walk_yaw, content="-0.10")
  let (_, edited_duration) = update(
    _ => @rabbita.none,
    UpdateWalkDuration("1500"),
    edited_yaw,
  )
  inspect(edited_duration.walk_duration_ms, content="1500")
  let (_, evaluating) = update(_ => @rabbita.none, EvaluateWalk, model)
  inspect(evaluating.evaluating, content="true")
  inspect(evaluating.intent_status, content="Evaluating walk intent")
  let (_, accepted) = update(
    _ => @rabbita.none,
    IntentEvaluated(Ok("CollectDryRun: WaitingForDryRun receipt receipt-cockpit-walk")),
    evaluating,
  )
  inspect(accepted.evaluating, content="false")
  inspect(accepted.loading, content="true")
  inspect(accepted.intent_status.contains("CollectDryRun"), content="true")
  let (_, rejected) = update(
    _ => @rabbita.none,
    IntentEvaluated(Err("parse-intent-submission: bad input")),
    accepted,
  )
  inspect(rejected.evaluating, content="false")
  inspect(rejected.intent_status.contains("Intent rejected"), content="true")
}

///|
test "walk intent body uses editable command parameters" {
  let model = {
    ..init_model(),
    walk_x: "0.25",
    walk_yaw: "-0.10",
    walk_duration_ms: "1500",
  }
  let text = walk_intent_body(model).stringify()
  inspect(text.contains("\"x\":\"0.25\""), content="true")
  inspect(text.contains("\"yaw\":\"-0.10\""), content="true")
  inspect(text.contains("\"duration_ms\":\"1500\""), content="true")
}

///|
#warnings("-alert_unstable")
test "rendered cockpit includes safety and receipt signals" {
  let page = @rabbita.simple_cell(
    model=init_model(),
    update=(_ : Msg, model) => model,
    view=(dispatch, model) => render_app(dispatch, model),
  )
  let html = @rabbita.render_to_string(page)
  inspect(html.contains("Moonrobo Cockpit"), content="true")
  inspect(html.contains("Safety Gate"), content="true")
  inspect(html.contains("Evaluate Walk"), content="true")
  inspect(html.contains("Duration ms"), content="true")
  inspect(html.contains("0.10"), content="true")
  inspect(html.contains("No command submitted"), content="true")
  inspect(html.contains("receipt-cli-plan-walk"), content="true")
  inspect(html.contains("Refresh"), content="true")
}
