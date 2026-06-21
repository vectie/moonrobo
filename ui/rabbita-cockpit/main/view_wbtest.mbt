///|
test "sample snapshot keeps imported cockpit contract" {
  let snapshot = sample_snapshot()
  inspect(snapshot.robot.robot_id, content="noetix-e1-lab-01")
  inspect(snapshot.safety.decision, content="dry-run-required")
  inspect(snapshot.read_only, content="true")
}

///|
#warnings("-alert_unstable")
test "rendered cockpit includes safety and receipt signals" {
  let html = @rabbita.render_to_string(
    @rabbita.static_cell(render_app(sample_snapshot())),
  )
  inspect(html.contains("Moonrobo Cockpit"), content="true")
  inspect(html.contains("Safety Gate"), content="true")
  inspect(html.contains("Execute Locked"), content="true")
  inspect(html.contains("receipt-cli-plan-walk"), content="true")
}
